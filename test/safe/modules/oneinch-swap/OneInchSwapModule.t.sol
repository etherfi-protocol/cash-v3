// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";

import { IOrderMixin } from "@1inch/limit-order-protocol-contract/contracts/interfaces/IOrderMixin.sol";
import { Address } from "@1inch/solidity-utils/contracts/libraries/AddressLib.sol";
import { MakerTraits } from "@1inch/limit-order-protocol-contract/contracts/libraries/MakerTraitsLib.sol";

import { OneInchSwapModule, ModuleBase, ModuleCheckBalance } from "../../../../src/modules/oneinch-swap/OneInchSwapModule.sol";
import { SafeTestSetup } from "../../SafeTestSetup.t.sol";
import { ICashModule } from "../../../../src/interfaces/ICashModule.sol";
import { UpgradeableProxy } from "../../../../src/utils/UpgradeableProxy.sol";

/**
 * @title OneInchSwapModule tests
 * @notice Fork tests against OP mainnet — relies on the live 1inch Aggregation Router (LOP) and
 *         SimpleSettlement contracts. Builds real LOP orders, computes orderHash via the live
 *         router, and exercises the pre→post fill window with simulated maker/taker transfers.
 */
contract OneInchSwapModuleTest is SafeTestSetup {
    OneInchSwapModule public oneInchModule;

    address public constant AGGREGATION_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;
    address public constant SIMPLE_SETTLEMENT_OP = 0x2Ad5004c60e16E54d5007C80CE329Adde5B51Ef5;
    address public operatingSafe = makeAddr("operatingSafe");
    address public cancelKeeper = makeAddr("cancelKeeper");
    address public requestKeeper = makeAddr("requestKeeper");

    uint256 public constant SWAP_AMOUNT = 100e6;        // 100 USDC
    uint256 public constant MIN_TO_AMOUNT = 1e16;       // 0.01 weETH
    uint40  public constant EXPIRATION   = type(uint40).max;

    function setUp() public override {
        super.setUp();

        // Deploy module behind ERC1967 proxy
        OneInchSwapModule impl = new OneInchSwapModule(AGGREGATION_ROUTER, SIMPLE_SETTLEMENT_OP, address(dataProvider), operatingSafe);
        oneInchModule = OneInchSwapModule(address(new ERC1967Proxy(address(impl), abi.encodeCall(OneInchSwapModule.initialize, (address(roleRegistry))))));

        address[] memory modules = new address[](1);
        modules[0] = address(oneInchModule);
        bool[] memory yes = new bool[](1);
        yes[0] = true;

        vm.startPrank(owner);
        dataProvider.configureModules(modules, yes);
        dataProvider.setOneInchSwapModule(address(oneInchModule));
        cashModule.configureModulesCanRequestWithdraw(modules, yes);
        roleRegistry.grantRole(oneInchModule.ONEINCH_SWAP_CANCEL_ROLE(), cancelKeeper);
        roleRegistry.grantRole(oneInchModule.ONEINCH_SWAP_REQUEST_ROLE(), requestKeeper);
        // Grant the test contract the request role so existing tests can call requestSwap without prank.
        roleRegistry.grantRole(oneInchModule.ONEINCH_SWAP_REQUEST_ROLE(), address(this));
        vm.stopPrank();

        bytes[] memory setupData = new bytes[](1);
        _configureModules(modules, yes, setupData);
    }

    // ══════════════════════════════════════════════
    //  CLASSIC SWAP (unchanged surface — sanity checks)
    // ══════════════════════════════════════════════

    function test_classic_swap_revertsWhenSameAsset() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        bytes memory data = "";
        (address[] memory signers, bytes[] memory sigs) = _signClassic(address(usdc), address(usdc), SWAP_AMOUNT, MIN_TO_AMOUNT, data);

        vm.expectRevert(OneInchSwapModule.SwappingToSameAsset.selector);
        oneInchModule.swap(address(safe), address(usdc), address(usdc), SWAP_AMOUNT, MIN_TO_AMOUNT, data, signers, sigs);
    }

    function test_classic_swap_revertsWhenZeroMinOutput() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        bytes memory data = "";
        (address[] memory signers, bytes[] memory sigs) = _signClassic(address(usdc), address(weETH), SWAP_AMOUNT, 0, data);

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        oneInchModule.swap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, 0, data, signers, sigs);
    }

    function test_classic_swap_revertsWithInvalidSignature() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        bytes memory data = "";
        (address[] memory signers, bytes[] memory sigs) = _signClassic(address(usdc), address(weETH), SWAP_AMOUNT + 1, MIN_TO_AMOUNT, data);

        vm.expectRevert(OneInchSwapModule.InvalidSignatures.selector);
        oneInchModule.swap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, data, signers, sigs);
    }

    function test_classic_swap_revertsWithNotEtherFiSafe() public {
        address fakeSafe = makeAddr("fakeSafe");
        bytes memory data = "";
        address[] memory signers = new address[](2);
        bytes[] memory sigs = new bytes[](2);

        vm.expectRevert(ModuleBase.OnlyEtherFiSafe.selector);
        oneInchModule.swap(fakeSafe, address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, data, signers, sigs);
    }

    // ══════════════════════════════════════════════
    //  FUSION — requestSwap
    // ══════════════════════════════════════════════

    function test_fusion_requestSwap_works() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, bytes memory ext) = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(intent, _hashOrder(order));

        oneInchModule.requestSwap(intent, order, ext, signers, sigs);

        OneInchSwapModule.PendingSwap memory p = oneInchModule.getPendingSwap(address(safe));
        assertEq(p.fromToken, address(usdc));
        assertEq(p.toToken, address(weETH));
        assertEq(p.fromAmount, SWAP_AMOUNT);
        assertEq(p.minToAmount, MIN_TO_AMOUNT);
        assertTrue(p.orderHash != bytes32(0));

        // swapInProgress is NOT set here anymore — only during the router fill window.
        assertFalse(oneInchModule.swapInProgress(address(safe)));

        assertEq(usdc.balanceOf(address(safe)), SWAP_AMOUNT);
        // Approval is granted in preInteraction (within fill tx), not at request time.
        assertEq(usdc.allowance(address(safe), AGGREGATION_ROUTER), 0);
    }

    function test_fusion_requestSwap_revertsWithNativeETH() public {
        address ETH_ADDR = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, bytes memory ext) = _buildOrder(ETH_ADDR, address(weETH), 1 ether, MIN_TO_AMOUNT, EXPIRATION);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(intent, bytes32(0));

        vm.expectRevert(OneInchSwapModule.NativeETHNotSupported.selector);
        oneInchModule.requestSwap(intent, order, ext, signers, sigs);
    }

    function test_fusion_requestSwap_revertsWhenSameAsset() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, bytes memory ext) = _buildOrder(address(usdc), address(usdc), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(intent, bytes32(0));

        vm.expectRevert(OneInchSwapModule.SwappingToSameAsset.selector);
        oneInchModule.requestSwap(intent, order, ext, signers, sigs);
    }

    function test_fusion_requestSwap_revertsWhenZeroAmount() public {
        (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, bytes memory ext) = _buildOrder(address(usdc), address(weETH), 0, MIN_TO_AMOUNT, EXPIRATION);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(intent, bytes32(0));

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        oneInchModule.requestSwap(intent, order, ext, signers, sigs);
    }

    function test_fusion_requestSwap_revertsWhenZeroMinToAmount() public {
        (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, bytes memory ext) = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, 0, EXPIRATION);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(intent, bytes32(0));

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        oneInchModule.requestSwap(intent, order, ext, signers, sigs);
    }

    function test_fusion_requestSwap_revertsWhenSwapAlreadyPending() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT * 2);
        _openSwap();

        (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, bytes memory ext) = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(intent, _hashOrder(order));

        vm.expectRevert(OneInchSwapModule.SwapAlreadyPending.selector);
        oneInchModule.requestSwap(intent, order, ext, signers, sigs);
    }

    function test_fusion_requestSwap_revertsWithInvalidSignatures() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, bytes memory ext) = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION);
        // Sign with the WRONG orderHash to flip the verifier
        (address[] memory signers, bytes[] memory sigs) = _signRequest(intent, keccak256("wrong"));

        vm.expectRevert(OneInchSwapModule.InvalidSignatures.selector);
        oneInchModule.requestSwap(intent, order, ext, signers, sigs);
    }

    function test_fusion_requestSwap_revertsOnIntentOrderMismatch() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        // Build order with a maker the intent doesn't agree with
        (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, bytes memory ext) = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION);
        order.maker = Address.wrap(uint256(uint160(makeAddr("notSafe"))));
        // recompute extension+salt is not needed — validation order intent comes BEFORE salt/extension
        (address[] memory signers, bytes[] memory sigs) = _signRequest(intent, bytes32(0));

        vm.expectRevert(OneInchSwapModule.OrderMakerMismatch.selector);
        oneInchModule.requestSwap(intent, order, ext, signers, sigs);
    }

    function test_fusion_requestSwap_revertsWhenWithdrawalDelayZero() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        vm.prank(owner);
        cashModule.setDelays(0, 1 days, 1 days);

        (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, bytes memory ext) = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(intent, _hashOrder(order));

        vm.expectRevert(OneInchSwapModule.WithdrawalDelayMisconfigured.selector);
        oneInchModule.requestSwap(intent, order, ext, signers, sigs);
    }

    // ══════════════════════════════════════════════
    //  FUSION — pre / postInteraction (with balance-delta enforcement)
    // ══════════════════════════════════════════════

    function test_fusion_postInteraction_works() public {
        bytes32 orderHash = _openSwap();
        (, IOrderMixin.Order memory order, ) = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION);

        vm.startPrank(AGGREGATION_ROUTER);
        oneInchModule.preInteraction(order, "", orderHash, makeAddr("resolver"), SWAP_AMOUNT, MIN_TO_AMOUNT, 0, "");
        // Simulate the fill — router moves fromToken out and resolver delivers toToken
        usdc.transferFrom(address(safe), makeAddr("resolver"), SWAP_AMOUNT);
        deal(address(weETH), address(safe), MIN_TO_AMOUNT);
        oneInchModule.postInteraction(order, "", orderHash, makeAddr("resolver"), SWAP_AMOUNT, MIN_TO_AMOUNT, 0, "");
        vm.stopPrank();

        assertEq(oneInchModule.getPendingSwap(address(safe)).fromAmount, 0);
        assertFalse(oneInchModule.swapInProgress(address(safe)));
        assertEq(usdc.allowance(address(safe), AGGREGATION_ROUTER), 0);
    }

    function test_fusion_postInteraction_revertsOnMissingSnapshot() public {
        bytes32 orderHash = _openSwap();
        (, IOrderMixin.Order memory order, ) = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION);

        // Call post WITHOUT pre — transient snapshot slot is empty; reverts before delta check.
        vm.prank(AGGREGATION_ROUTER);
        vm.expectRevert(OneInchSwapModule.MissingSnapshot.selector);
        oneInchModule.postInteraction(order, "", orderHash, makeAddr("resolver"), SWAP_AMOUNT, MIN_TO_AMOUNT, 0, "");
    }

    function test_fusion_postInteraction_revertsWhenUnderDelivered() public {
        bytes32 orderHash = _openSwap();
        (, IOrderMixin.Order memory order, ) = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION);

        vm.startPrank(AGGREGATION_ROUTER);
        oneInchModule.preInteraction(order, "", orderHash, makeAddr("resolver"), SWAP_AMOUNT, MIN_TO_AMOUNT, 0, "");
        usdc.transferFrom(address(safe), makeAddr("resolver"), SWAP_AMOUNT);
        deal(address(weETH), address(safe), MIN_TO_AMOUNT - 1); // less than minToAmount
        vm.expectRevert(OneInchSwapModule.InsufficientReceivedAmount.selector);
        oneInchModule.postInteraction(order, "", orderHash, makeAddr("resolver"), SWAP_AMOUNT, MIN_TO_AMOUNT, 0, "");
        vm.stopPrank();
    }

    function test_fusion_postInteraction_revertsOnUnexpectedFromTokenDelta() public {
        bytes32 orderHash = _openSwap();
        (, IOrderMixin.Order memory order, ) = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION);

        vm.startPrank(AGGREGATION_ROUTER);
        oneInchModule.preInteraction(order, "", orderHash, makeAddr("resolver"), SWAP_AMOUNT, MIN_TO_AMOUNT, 0, "");
        // Move only part of fromAmount — delta will be < fromAmount
        usdc.transferFrom(address(safe), makeAddr("resolver"), SWAP_AMOUNT - 1);
        deal(address(weETH), address(safe), MIN_TO_AMOUNT);
        vm.expectRevert(OneInchSwapModule.UnexpectedFromTokenDelta.selector);
        oneInchModule.postInteraction(order, "", orderHash, makeAddr("resolver"), SWAP_AMOUNT, MIN_TO_AMOUNT, 0, "");
        vm.stopPrank();
    }

    function test_fusion_postInteraction_revertsWhenNotRouterOrSettlement() public {
        bytes32 orderHash = _openSwap();
        (, IOrderMixin.Order memory order, ) = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION);

        vm.prank(makeAddr("random"));
        vm.expectRevert(OneInchSwapModule.OnlyAggregationRouterOrSettlement.selector);
        oneInchModule.postInteraction(order, "", orderHash, makeAddr("resolver"), SWAP_AMOUNT, MIN_TO_AMOUNT, 0, "");
    }

    function test_fusion_preInteraction_revertsWhenNotRouter() public {
        bytes32 orderHash = _openSwap();
        (, IOrderMixin.Order memory order, ) = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION);

        vm.prank(makeAddr("random"));
        vm.expectRevert(OneInchSwapModule.OnlyAggregationRouter.selector);
        oneInchModule.preInteraction(order, "", orderHash, makeAddr("resolver"), SWAP_AMOUNT, MIN_TO_AMOUNT, 0, "");
    }

    function test_fusion_preInteraction_armsSwapInProgress() public {
        bytes32 orderHash = _openSwap();
        (, IOrderMixin.Order memory order, ) = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION);

        assertFalse(oneInchModule.swapInProgress(address(safe)));
        assertEq(usdc.allowance(address(safe), AGGREGATION_ROUTER), 0);

        vm.prank(AGGREGATION_ROUTER);
        oneInchModule.preInteraction(order, "", orderHash, makeAddr("resolver"), SWAP_AMOUNT, MIN_TO_AMOUNT, 0, "");

        assertTrue(oneInchModule.swapInProgress(address(safe)));
        // Approval is granted in preInteraction so the router's transferFrom can pull `fromAmount`.
        assertEq(usdc.allowance(address(safe), AGGREGATION_ROUTER), SWAP_AMOUNT);
    }

    function test_fusion_requestSwap_revertsWhenCallerLacksRole() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, bytes memory ext) = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(intent, _hashOrder(order));

        vm.prank(makeAddr("randomEOA"));
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        oneInchModule.requestSwap(intent, order, ext, signers, sigs);
    }

    // ══════════════════════════════════════════════
    //  FUSION — cancelSwap (both auth paths)
    // ══════════════════════════════════════════════

    function test_fusion_cancelSwap_ownerSignaturePath() public {
        _openSwap();
        (address[] memory signers, bytes[] memory sigs) = _signCancel();
        oneInchModule.cancelSwap(address(safe), signers, sigs);

        assertEq(oneInchModule.getPendingSwap(address(safe)).fromAmount, 0);
        assertEq(usdc.allowance(address(safe), AGGREGATION_ROUTER), 0);
    }

    function test_fusion_cancelSwap_roleKeeperPath() public {
        _openSwap();
        address[] memory signers = new address[](0);
        bytes[] memory sigs = new bytes[](0);
        vm.prank(cancelKeeper);
        oneInchModule.cancelSwap(address(safe), signers, sigs);

        assertEq(oneInchModule.getPendingSwap(address(safe)).fromAmount, 0);
    }

    function test_fusion_cancelSwap_roleKeeperPath_revertsForNonHolder() public {
        _openSwap();
        address[] memory signers = new address[](0);
        bytes[] memory sigs = new bytes[](0);
        vm.prank(makeAddr("randomEOA"));
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        oneInchModule.cancelSwap(address(safe), signers, sigs);
    }

    function test_fusion_cancelSwap_revertsWhenNoPendingSwap() public {
        (address[] memory signers, bytes[] memory sigs) = _signCancel();
        vm.expectRevert(OneInchSwapModule.NoPendingSwap.selector);
        oneInchModule.cancelSwap(address(safe), signers, sigs);
    }

    // ══════════════════════════════════════════════
    //  cancelBridgeByCashModule (called only by CashModule)
    // ══════════════════════════════════════════════

    function test_cancelBridgeByCashModule_works() public {
        _openSwap();
        vm.prank(address(cashModule));
        oneInchModule.cancelBridgeByCashModule(address(safe));

        assertEq(oneInchModule.getPendingSwap(address(safe)).fromAmount, 0);
        assertEq(usdc.allowance(address(safe), AGGREGATION_ROUTER), 0);
    }

    function test_cancelBridgeByCashModule_revertsWhenNotCashModule() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        oneInchModule.cancelBridgeByCashModule(address(safe));
    }

    function test_cancelBridgeByCashModule_noopOnEmpty() public {
        vm.prank(address(cashModule));
        oneInchModule.cancelBridgeByCashModule(address(safe));
        // No revert, no state change expected
        assertEq(oneInchModule.getPendingSwap(address(safe)).fromAmount, 0);
    }

    // ══════════════════════════════════════════════
    //  rescueFunds (permissionless → operatingSafe)
    // ══════════════════════════════════════════════

    function test_rescueFunds_works() public {
        deal(address(usdc), address(oneInchModule), SWAP_AMOUNT);
        uint256 opBefore = usdc.balanceOf(operatingSafe);

        // Any caller — destination is immutable to operatingSafe so theft impossible
        vm.prank(makeAddr("rando"));
        oneInchModule.rescueFunds(address(usdc), SWAP_AMOUNT);

        assertEq(usdc.balanceOf(operatingSafe) - opBefore, SWAP_AMOUNT);
        assertEq(usdc.balanceOf(address(oneInchModule)), 0);
    }

    function test_rescueFunds_revertsOnZeroAmount() public {
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        oneInchModule.rescueFunds(address(usdc), 0);
    }

    // ══════════════════════════════════════════════
    //  Nonce / replay
    // ══════════════════════════════════════════════

    function test_fusion_nonce_increments() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        uint256 nonceBefore = safe.nonce();
        _openSwap();
        assertEq(safe.nonce(), nonceBefore + 1);
    }

    function test_fusion_signatureReplay_reverts() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT * 2);
        (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, bytes memory ext) = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(intent, _hashOrder(order));
        oneInchModule.requestSwap(intent, order, ext, signers, sigs);

        (address[] memory cs, bytes[] memory csig) = _signCancel();
        oneInchModule.cancelSwap(address(safe), cs, csig);

        // Replay — nonce has advanced so signature no longer matches
        vm.expectRevert(OneInchSwapModule.InvalidSignatures.selector);
        oneInchModule.requestSwap(intent, order, ext, signers, sigs);
    }

    // ══════════════════════════════════════════════
    //  FUSION — MakerTraits / extension hardening (Certora I-05, L-05)
    // ══════════════════════════════════════════════

    /// @dev MakerTraits.UNWRAP_WETH must be off — otherwise the router would deliver ETH instead
    ///      of WETH to the maker, bypassing the toToken balance-delta check in postInteraction.
    function test_fusion_requestSwap_revertsWhenUnwrapWethFlagSet() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, bytes memory ext) = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION);

        // Flip bit 247 and re-sign — owners would normally never sign such an order, but on-chain
        // we must still reject it if the BE is compromised.
        uint256 mt = MakerTraits.unwrap(order.makerTraits) | (uint256(1) << 247);
        order.makerTraits = MakerTraits.wrap(mt);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(intent, _hashOrder(order));

        vm.expectRevert(OneInchSwapModule.UnwrapWethNotAllowed.selector);
        oneInchModule.requestSwap(intent, order, ext, signers, sigs);
    }

    /// @dev Fusion-routed shape (leading = settlement, length > 20, trailing = module) is accepted.
    ///      `padBytes=85` produces a 125-byte field — matches the canonical SimpleSettlement
    ///      layout and keeps the flags byte (offset 20) + whitelist size byte (offset 71) inside
    ///      the zero-padded body so they pass the byte-level shape checks.
    function test_fusion_requestSwap_acceptsSettlementRoutedExtension() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, bytes memory ext) =
            _buildOrderWithExtension(_buildFusionExtension(SIMPLE_SETTLEMENT_OP, address(oneInchModule), 85));
        (address[] memory signers, bytes[] memory sigs) = _signRequest(intent, _hashOrder(order));

        oneInchModule.requestSwap(intent, order, ext, signers, sigs);
        assertEq(oneInchModule.getPendingSwap(address(safe)).fromAmount, SWAP_AMOUNT);
    }

    /// @dev Settlement-routed shape with non-zero flags byte (offset 20) must revert — the BE
    ///      always constructs Fusion orders with `flags == 0` (no customReceiver), and pinning
    ///      this on-chain prevents a compromised BE from rerouting the maker payout.
    function test_fusion_requestSwap_revertsOnNonZeroFlagsByte() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        bytes memory pad = new bytes(85);
        pad[0] = 0x01; // flip flags bit 0 (customReceiver)
        bytes memory body = abi.encodePacked(bytes20(SIMPLE_SETTLEMENT_OP), pad, bytes20(address(oneInchModule)));
        bytes memory ext = _buildPostFieldOnly(body);
        (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, ) = _buildOrderWithExtension(ext);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(intent, _hashOrder(order));

        vm.expectRevert(OneInchSwapModule.CustomReceiverMustBeDisabled.selector);
        oneInchModule.requestSwap(intent, order, ext, signers, sigs);
    }

    /// @dev Settlement-routed shape with non-zero whitelist size byte (offset 71) must revert —
    ///      the BE always submits with an empty resolver whitelist; otherwise a compromised BE
    ///      could whitelist a malicious resolver.
    function test_fusion_requestSwap_revertsOnNonZeroWhitelistSize() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        bytes memory pad = new bytes(85);
        pad[51] = 0x01; // pad index 51 == field byte 71 (whitelist size when flags == 0)
        bytes memory body = abi.encodePacked(bytes20(SIMPLE_SETTLEMENT_OP), pad, bytes20(address(oneInchModule)));
        bytes memory ext = _buildPostFieldOnly(body);
        (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, ) = _buildOrderWithExtension(ext);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(intent, _hashOrder(order));

        vm.expectRevert(OneInchSwapModule.WhitelistMustBeDisabled.selector);
        oneInchModule.requestSwap(intent, order, ext, signers, sigs);
    }

    /// @dev Settlement-routed shape with field length ≠ 125 must revert — the canonical
    ///      SimpleSettlement+FeeTaker body with flags=0 and whitelistSize=0 is exactly 125
    ///      bytes. Pinning the length forces the trailing 20 bytes to coincide with the
    ///      chained-target slot FeeTaker actually invokes after parsing fee data.
    function test_fusion_requestSwap_revertsOnShortSettlementBody() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        // field length = 20 (settlement) + 30 (pad) + 20 (module) = 70 (≠ 125)
        bytes memory ext = _buildPostFieldOnly(abi.encodePacked(bytes20(SIMPLE_SETTLEMENT_OP), new bytes(30), bytes20(address(oneInchModule))));
        (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, ) = _buildOrderWithExtension(ext);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(intent, _hashOrder(order));

        vm.expectRevert(OneInchSwapModule.WrongPostInteractionExtensionShape.selector);
        oneInchModule.requestSwap(intent, order, ext, signers, sigs);
    }

    /// @dev Settlement-routed shape with field length > 125 must revert. With padBytes=86,
    ///      total length is 126 and the trailing 20 bytes still equal the module — but the
    ///      chained-target slot FeeTaker reads (deterministic given flags=0, whitelistSize=0)
    ///      sits 1 byte before. Strict equality `end7 - end6 == 125` blocks this padding
    ///      attack and forces the trailing-20 check to coincide with the real chained target.
    function test_fusion_requestSwap_revertsOnOverlongSettlementBody() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        // field length = 20 + 86 + 20 = 126 (≠ 125)
        bytes memory ext = _buildPostFieldOnly(abi.encodePacked(bytes20(SIMPLE_SETTLEMENT_OP), new bytes(86), bytes20(address(oneInchModule))));
        (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, ) = _buildOrderWithExtension(ext);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(intent, _hashOrder(order));

        vm.expectRevert(OneInchSwapModule.WrongPostInteractionExtensionShape.selector);
        oneInchModule.requestSwap(intent, order, ext, signers, sigs);
    }

    /// @dev Settlement-routed shape with no chained target (length == 20) must revert.
    function test_fusion_requestSwap_revertsWhenSettlementShapeMissingChainedTarget() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        // Length 20 but leading = settlement: not a valid plain-LOP shape (leading != module)
        // and not a valid Settlement shape (no trailing module).
        bytes memory ext = _buildPostFieldOnly(abi.encodePacked(bytes20(SIMPLE_SETTLEMENT_OP)));
        (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, ) = _buildOrderWithExtension(ext);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(intent, _hashOrder(order));

        vm.expectRevert(OneInchSwapModule.WrongPostInteractionTarget.selector);
        oneInchModule.requestSwap(intent, order, ext, signers, sigs);
    }

    /// @dev Plain-LOP shape (leading = module) with length > 20 must revert — module-as-leading
    ///      is the direct-call shape and admits no trailing payload.
    function test_fusion_requestSwap_revertsWhenModuleLeadingButPaddedField7() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        bytes memory ext = _buildPostFieldOnly(abi.encodePacked(bytes20(address(oneInchModule)), bytes20(address(oneInchModule))));
        (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, ) = _buildOrderWithExtension(ext);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(intent, _hashOrder(order));

        vm.expectRevert(OneInchSwapModule.WrongPostInteractionTarget.selector);
        oneInchModule.requestSwap(intent, order, ext, signers, sigs);
    }

    /// @dev Leading 20 bytes = some unrelated contract must revert (defends against the H-07-style
    ///      "prepend arbitrary calldata, hide a different target in earlier bytes" attack).
    function test_fusion_requestSwap_revertsWhenUnknownLeadingTarget() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        address evil = makeAddr("evilTarget");
        bytes memory ext = _buildPostFieldOnly(abi.encodePacked(bytes20(evil), bytes20(address(oneInchModule))));
        (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, ) = _buildOrderWithExtension(ext);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(intent, _hashOrder(order));

        vm.expectRevert(OneInchSwapModule.WrongPostInteractionTarget.selector);
        oneInchModule.requestSwap(intent, order, ext, signers, sigs);
    }

    /// @dev Settlement-routed shape with the trailing chained-target ≠ module must revert.
    function test_fusion_requestSwap_revertsWhenSettlementShapeWrongChainedTarget() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        bytes memory body = abi.encodePacked(
            bytes20(SIMPLE_SETTLEMENT_OP),
            bytes20(makeAddr("padding")),
            bytes20(makeAddr("wrongChainedTarget"))
        );
        bytes memory ext = _buildPostFieldOnly(body);
        (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, ) = _buildOrderWithExtension(ext);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(intent, _hashOrder(order));

        vm.expectRevert(OneInchSwapModule.WrongPostInteractionTarget.selector);
        oneInchModule.requestSwap(intent, order, ext, signers, sigs);
    }

    // ══════════════════════════════════════════════
    //  HELPERS
    // ══════════════════════════════════════════════

    /// @dev Opens a fresh Fusion swap with the default usdc→weETH params; returns the orderHash.
    function _openSwap() internal returns (bytes32 orderHash) {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, bytes memory ext) = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION);
        orderHash = _hashOrder(order);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(intent, orderHash);
        oneInchModule.requestSwap(intent, order, ext, signers, sigs);
    }

    /// @dev Builds a minimal LOP order + extension that passes the module's validation:
    ///       - extension only contains PreInteractionData (field 6) + PostInteractionData (field 7),
    ///         both 20 bytes = address(module)
    ///       - MakerTraits has HAS_EXTENSION | PRE_INT | POST_INT | NO_PARTIAL flags + expiration
    ///       - salt's lower 160 bits = lower 160 of keccak256(extension); upper 96 bits = pseudo-nonce
    function _buildOrder(address fromToken, address toToken, uint256 fromAmount, uint256 minToAmount, uint40 expiration)
        internal
        view
        returns (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, bytes memory ext)
    {
        intent = OneInchSwapModule.SwapIntent({
            safe: address(safe),
            fromToken: fromToken,
            toToken: toToken,
            fromAmount: fromAmount,
            minToAmount: minToAmount,
            expiration: expiration
        });

        ext = _buildExtension(address(oneInchModule));

        uint256 mt = (uint256(1) << 255) | (uint256(1) << 252) | (uint256(1) << 251) | (uint256(1) << 249) | (uint256(expiration) << 80);
        uint256 saltLower = uint256(keccak256(ext)) & type(uint160).max;
        // Upper 96 bits derived from the Safe nonce so consecutive openSwap calls don't collide
        uint256 saltUpper = uint256(safe.nonce()) << 160;

        order = IOrderMixin.Order({
            salt: saltUpper | saltLower,
            maker: Address.wrap(uint256(uint160(address(safe)))),
            receiver: Address.wrap(0),
            makerAsset: Address.wrap(uint256(uint160(fromToken))),
            takerAsset: Address.wrap(uint256(uint160(toToken))),
            makingAmount: fromAmount,
            takingAmount: minToAmount,
            makerTraits: MakerTraits.wrap(mt)
        });
    }

    /// @dev LOP extension bytes: 32-byte offsets bitmap + field 6 (20B) + field 7 (20B).
    function _buildExtension(address module) internal pure returns (bytes memory) {
        // offsets bitmap: end5=0, end6=20, end7=40 (also end0..end4=0 implicitly).
        uint256 offsets = (uint256(20) << 192) | (uint256(40) << 224);
        return abi.encodePacked(bytes32(offsets), bytes20(module), bytes20(module));
    }

    /// @dev Builds a Settlement-routed extension: field 6 = module (20B), field 7 starts with
    ///      `settlement`, contains `padBytes` of arbitrary middle bytes, ends with `module`.
    ///      Total field-7 length = 40 + padBytes.
    function _buildFusionExtension(address settlement, address module, uint32 padBytes) internal pure returns (bytes memory) {
        bytes memory pad = new bytes(padBytes);
        bytes memory field7 = abi.encodePacked(bytes20(settlement), pad, bytes20(module));
        uint32 end7 = uint32(20 + field7.length);
        uint256 offsets = (uint256(20) << 192) | (uint256(end7) << 224);
        return abi.encodePacked(bytes32(offsets), bytes20(module), field7);
    }

    /// @dev Builds an extension with a fixed field-6 (= module address) and a caller-supplied
    ///      field-7 body. Useful for negative tests targeting `_validateExtension`'s field-7
    ///      branches without touching the field-6 validation.
    function _buildPostFieldOnly(bytes memory field7) internal view returns (bytes memory) {
        uint32 end7 = uint32(20 + field7.length);
        uint256 offsets = (uint256(20) << 192) | (uint256(end7) << 224);
        return abi.encodePacked(bytes32(offsets), bytes20(address(oneInchModule)), field7);
    }

    /// @dev Builds an order + intent matching the default usdc → weETH params, but lets the
    ///      caller substitute a custom LOP extension. Recomputes salt to commit to the extension.
    function _buildOrderWithExtension(bytes memory ext)
        internal
        view
        returns (OneInchSwapModule.SwapIntent memory intent, IOrderMixin.Order memory order, bytes memory extOut)
    {
        intent = OneInchSwapModule.SwapIntent({
            safe: address(safe),
            fromToken: address(usdc),
            toToken: address(weETH),
            fromAmount: SWAP_AMOUNT,
            minToAmount: MIN_TO_AMOUNT,
            expiration: EXPIRATION
        });
        extOut = ext;

        uint256 mt = (uint256(1) << 255) | (uint256(1) << 252) | (uint256(1) << 251) | (uint256(1) << 249) | (uint256(EXPIRATION) << 80);
        uint256 saltLower = uint256(keccak256(ext)) & type(uint160).max;
        uint256 saltUpper = uint256(safe.nonce()) << 160;

        order = IOrderMixin.Order({
            salt: saltUpper | saltLower,
            maker: Address.wrap(uint256(uint160(address(safe)))),
            receiver: Address.wrap(0),
            makerAsset: Address.wrap(uint256(uint160(address(usdc)))),
            takerAsset: Address.wrap(uint256(uint160(address(weETH)))),
            makingAmount: SWAP_AMOUNT,
            takingAmount: MIN_TO_AMOUNT,
            makerTraits: MakerTraits.wrap(mt)
        });
    }

    function _hashOrder(IOrderMixin.Order memory order) internal view returns (bytes32) {
        return IOrderMixin(AGGREGATION_ROUTER).hashOrder(order);
    }

    function _signClassic(address fromAsset, address toAsset, uint256 fromAmount, uint256 minToAmount, bytes memory data)
        internal
        view
        returns (address[] memory, bytes[] memory)
    {
        bytes32 structHash = keccak256(abi.encode(
            oneInchModule.SWAP_TYPEHASH(),
            address(safe),
            address(oneInchModule),
            fromAsset,
            toAsset,
            fromAmount,
            minToAmount,
            keccak256(data),
            safe.nonce()
        ));
        return _signWithOwners(_digest(structHash));
    }

    function _signRequest(OneInchSwapModule.SwapIntent memory intent, bytes32 orderHash)
        internal
        view
        returns (address[] memory, bytes[] memory)
    {
        bytes32 structHash = keccak256(abi.encode(
            oneInchModule.REQUEST_SWAP_TYPEHASH(),
            intent.safe,
            address(oneInchModule),
            intent.fromToken,
            intent.toToken,
            intent.fromAmount,
            intent.minToAmount,
            intent.expiration,
            orderHash,
            safe.nonce()
        ));
        return _signWithOwners(_digest(structHash));
    }

    function _signCancel() internal view returns (address[] memory, bytes[] memory) {
        bytes32 structHash = keccak256(abi.encode(
            oneInchModule.CANCEL_SWAP_TYPEHASH(),
            address(safe),
            address(oneInchModule),
            safe.nonce()
        ));
        return _signWithOwners(_digest(structHash));
    }

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
    }

    function _signWithOwners(bytes32 digestHash) internal view returns (address[] memory, bytes[] memory) {
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = abi.encodePacked(r1, s1, v1);
        sigs[1] = abi.encodePacked(r2, s2, v2);

        return (signers, sigs);
    }
}
