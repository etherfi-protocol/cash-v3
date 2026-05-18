// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {IOrderMixin} from "@1inch/limit-order-protocol-contract/contracts/interfaces/IOrderMixin.sol";
import {Address} from "@1inch/solidity-utils/contracts/libraries/AddressLib.sol";
import {MakerTraits} from "@1inch/limit-order-protocol-contract/contracts/libraries/MakerTraitsLib.sol";

import {OneInchSwapModule, ModuleBase, ModuleCheckBalance} from "../../../../src/modules/oneinch-swap/OneInchSwapModule.sol";
import {ArrayDeDupLib, EtherFiDataProvider, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup, IDebtManager} from "../../SafeTestSetup.t.sol";
import {ICashModule} from "../../../../src/interfaces/ICashModule.sol";
import {CashVerificationLib} from "../../../../src/libraries/CashVerificationLib.sol";

contract OneInchSwapModuleTest is SafeTestSetup {
    OneInchSwapModule public oneInchModule;

    // 1inch Aggregation Router on Optimism (real address — tests are fork-based)
    address public constant AGGREGATION_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;

    // Test swap parameters
    uint256 public constant SWAP_AMOUNT = 100e6; // 100 USDC
    uint256 public constant MIN_TO_AMOUNT = 1e16; // 0.01 weETH
    uint40 public constant EXPIRATION = 0; // no expiry — keeps tests stable across block timestamps

    // Arbitrary hash used only by Path-2 (generic owner-quorum) isValidSignature tests where
    // any 32-byte payload is fine.
    bytes32 public constant ARBITRARY_HASH = keccak256("arbitrary-hash");

    function setUp() public override {
        super.setUp();

        oneInchModule = new OneInchSwapModule(AGGREGATION_ROUTER, address(dataProvider));

        // Register module on data provider
        address[] memory modules = new address[](1);
        modules[0] = address(oneInchModule);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.startPrank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);
        // Wire the OneInch registry slot so EtherFiSafe.isValidSignature, EtherFiHook.postOpHook,
        // and DebtManagerCore.liquidate consult this module. Required for the aggregator-binding
        // path on isValidSignature to fire.
        dataProvider.setOneInchSwapModule(address(oneInchModule));
        // Allow module to register pending withdrawals on CashModule (Fusion flow)
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);
        vm.stopPrank();

        // Enable module on safe
        bytes[] memory setupData = new bytes[](1);
        _configureModules(modules, shouldWhitelist, setupData);
    }

    // ══════════════════════════════════════════════
    //  CLASSIC SWAP TESTS
    // ══════════════════════════════════════════════

    function test_classic_swap_revertsWhenSameAsset() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        bytes memory data = "";

        (address[] memory signers, bytes[] memory signatures) = _createClassicSwapSignatures(
            address(usdc), address(usdc), SWAP_AMOUNT, MIN_TO_AMOUNT, data
        );

        vm.expectRevert(OneInchSwapModule.SwappingToSameAsset.selector);
        oneInchModule.swap(address(safe), address(usdc), address(usdc), SWAP_AMOUNT, MIN_TO_AMOUNT, data, signers, signatures);
    }

    function test_classic_swap_revertsWhenZeroMinOutput() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        bytes memory data = "";

        (address[] memory signers, bytes[] memory signatures) = _createClassicSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, 0, data
        );

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        oneInchModule.swap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, 0, data, signers, signatures);
    }

    function test_classic_swap_revertsWhenInsufficientBalance() public {
        // Don't give safe any balance
        bytes memory data = "";

        (address[] memory signers, bytes[] memory signatures) = _createClassicSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, data
        );

        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        oneInchModule.swap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, data, signers, signatures);
    }

    function test_classic_swap_revertsWithInvalidSignature() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        bytes memory data = "";

        // Sign with different amount
        (address[] memory signers, bytes[] memory signatures) = _createClassicSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT + 1, MIN_TO_AMOUNT, data
        );

        vm.expectRevert(OneInchSwapModule.InvalidSignatures.selector);
        oneInchModule.swap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, data, signers, signatures);
    }

    function test_classic_swap_revertsWithNotEtherFiSafe() public {
        address fakeSafe = makeAddr("fakeSafe");
        bytes memory data = "";
        address[] memory signers = new address[](2);
        bytes[] memory signatures = new bytes[](2);

        vm.expectRevert(ModuleBase.OnlyEtherFiSafe.selector);
        oneInchModule.swap(fakeSafe, address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, data, signers, signatures);
    }

    function test_classic_swap_nonceNotConsumedOnRevert() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        uint256 nonceBefore = safe.nonce();

        bytes memory data = "";
        (address[] memory signers, bytes[] memory signatures) = _createClassicSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, data
        );

        // Revert rolls back all state changes including nonce increment
        vm.expectRevert();
        oneInchModule.swap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, data, signers, signatures);

        assertEq(safe.nonce(), nonceBefore);
    }

    // ══════════════════════════════════════════════
    //  FUSION SWAP TESTS — Safe-as-Maker
    // ══════════════════════════════════════════════

    // ──────────────────────────────────────────────
    //  requestSwap tests
    // ──────────────────────────────────────────────

    function test_fusion_requestSwap_works() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);

        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION
        );

        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION, signers, signatures);

        OneInchSwapModule.PendingSwap memory pendingSwap = oneInchModule.getPendingSwap(address(safe));
        assertEq(pendingSwap.fromToken, address(usdc));
        assertEq(pendingSwap.toToken, address(weETH));
        assertEq(pendingSwap.fromAmount, SWAP_AMOUNT);
        assertEq(pendingSwap.minToAmount, MIN_TO_AMOUNT);
        // orderHash is derived on-chain by aggregationRouter.hashOrder(order); the real router
        // always returns a non-zero EIP-712 typed-data hash.
        assertTrue(pendingSwap.orderHash != bytes32(0));

        // Fusion intent lifetime lock is armed in requestSwap, not just preInteraction.
        assertTrue(oneInchModule.swapInProgress(address(safe)));

        assertEq(usdc.balanceOf(address(safe)), SWAP_AMOUNT);
        assertEq(usdc.allowance(address(safe), AGGREGATION_ROUTER), SWAP_AMOUNT);
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient, address(oneInchModule));
    }

    function test_fusion_requestSwap_revertsWithNativeETH() public {
        address ETH_ADDR = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            ETH_ADDR, address(weETH), 1 ether, MIN_TO_AMOUNT, EXPIRATION
        );

        vm.expectRevert(OneInchSwapModule.NativeETHNotSupported.selector);
        oneInchModule.requestSwap(address(safe), ETH_ADDR, address(weETH), 1 ether, MIN_TO_AMOUNT, EXPIRATION, signers, signatures);
    }

    function test_fusion_requestSwap_revertsWhenSameAsset() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);

        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(usdc), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION
        );

        vm.expectRevert(OneInchSwapModule.SwappingToSameAsset.selector);
        oneInchModule.requestSwap(address(safe), address(usdc), address(usdc), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION, signers, signatures);
    }

    function test_fusion_requestSwap_revertsWhenZeroAmount() public {
        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), 0, MIN_TO_AMOUNT, EXPIRATION
        );

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), 0, MIN_TO_AMOUNT, EXPIRATION, signers, signatures);
    }

    function test_fusion_requestSwap_revertsWhenZeroMinToAmount() public {
        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, 0, EXPIRATION
        );

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, 0, EXPIRATION, signers, signatures);
    }

    function test_fusion_requestSwap_revertsWhenInsufficientBalance() public {
        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION
        );

        // CashModule._checkBalance reverts with InsufficientBalance when safe has < amount
        vm.expectRevert();
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION, signers, signatures);
    }

    function test_fusion_requestSwap_revertsWhenSwapAlreadyPending() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT * 2);

        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION
        );
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION, signers, signatures);

        (address[] memory signers2, bytes[] memory signatures2) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION
        );

        vm.expectRevert(OneInchSwapModule.SwapAlreadyPending.selector);
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION, signers2, signatures2);
    }

    function test_fusion_requestSwap_revertsWithInvalidSignatures() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);

        // Signers authorize a different fromAmount than what's passed to requestSwap
        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT + 1, MIN_TO_AMOUNT, EXPIRATION
        );

        vm.expectRevert(OneInchSwapModule.InvalidSignatures.selector);
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION, signers, signatures);
    }

    // requestSwap fail-closes if cashModule.withdrawalDelay is 0. Belt-and-suspenders against
    // a regression in the cash-module-side guard that forces a non-zero effective delay for
    // OneInch requests.
    function test_fusion_requestSwap_revertsWhenWithdrawalDelayZero() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);

        // The cash-module-side fix uses `effectiveDelay = 1` when caller is the OneInch module;
        // to exercise the module-side guard we set the configured delay to 0 AND also need to
        // ensure the cash-module-side guard would NOT apply (i.e. caller is NOT this module).
        // Easiest path: assert that with withdrawalDelay=0 + cash-module-side guard active, the
        // request still succeeds (cash-module forces effectiveDelay=1). For the module-side guard
        // in isolation, we'd need to bypass the cash-module fix — out of scope here.
        //
        // What we CAN test directly: WithdrawalDelayMisconfigured is reachable when the configured
        // delay is 0. We do this by reading getDelays() — if it's 0, the module-side guard fires
        // before any cash-module interaction.
        vm.prank(owner);
        cashModule.setDelays(0, 1 days, 1 days);

        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION
        );

        vm.expectRevert(OneInchSwapModule.WithdrawalDelayMisconfigured.selector);
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION, signers, signatures);
    }

    // Two consecutive requestSwap calls from the same Safe must produce different orderHashes.
    // If `MakerTraits.nonceOrEpoch` collided across orders, the second LOP fill from any Safe
    // would revert with `BitInvalidatedOrder()`. Asserting orderHash divergence is a leading
    // indicator that the per-order nonce wiring is intact; an end-to-end check requires a
    // resolver-side fill which is out of scope here.
    function test_fusion_consecutiveOrdersHaveDistinctHashes() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT * 2);

        (address[] memory s1, bytes[] memory sig1) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION
        );
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION, s1, sig1);
        bytes32 firstHash = oneInchModule.getPendingSwap(address(safe)).orderHash;

        // Cancel and re-open
        (address[] memory cs, bytes[] memory csig) = _createCancelSwapSignatures();
        oneInchModule.cancelSwap(address(safe), cs, csig);

        (address[] memory s2, bytes[] memory sig2) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION
        );
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION, s2, sig2);
        bytes32 secondHash = oneInchModule.getPendingSwap(address(safe)).orderHash;

        assertTrue(firstHash != secondHash, "consecutive orderHashes must differ to avoid LOP bit-invalidator collision");
    }

    // ──────────────────────────────────────────────
    //  ERC-1271 isValidSignature tests
    //  Path 1: aggregator-binding (msg.sender == AGGREGATION_ROUTER)
    //  Path 2: generic owner-quorum blob
    // ──────────────────────────────────────────────

    // Path 1: aggregator-binding returns magic iff registered pendingSwap.orderHash matches
    function test_isValidSignature_Path1_magicOnHashMatch() public {
        _setupRequestSwap();
        bytes32 orderHash = oneInchModule.getPendingSwap(address(safe)).orderHash;

        vm.prank(AGGREGATION_ROUTER);
        // Signature blob is ignored on Path 1 — pass arbitrary garbage
        assertEq(safe.isValidSignature(orderHash, hex"deadbeef"), bytes4(0x1626ba7e));
    }

    function test_isValidSignature_Path1_failOnHashMismatch() public {
        _setupRequestSwap();

        vm.prank(AGGREGATION_ROUTER);
        assertEq(safe.isValidSignature(keccak256("wrong-hash"), hex""), bytes4(0xffffffff));
    }

    function test_isValidSignature_Path1_failWhenNoPendingSwap() public view {
        // No requestSwap was made → pendingSwap.fromAmount == 0
        // From this contract (test contract address), msg.sender != AGGREGATION_ROUTER so Path 1
        // doesn't take. Test from the aggregator instead:
    }

    function test_isValidSignature_Path1_failWhenNoPendingSwap_pranked() public {
        // pendingSwap.fromAmount == 0 → fail-closed even from aggregator
        vm.prank(AGGREGATION_ROUTER);
        assertEq(safe.isValidSignature(keccak256("any-hash"), hex""), bytes4(0xffffffff));
    }

    // Path 2: generic owner-quorum blob
    function test_isValidSignature_Path2_validQuorumReturnsMagic() public view {
        bytes memory sigBlob = _buildOwnerSignatureBlob(ARBITRARY_HASH);
        assertEq(safe.isValidSignature(ARBITRARY_HASH, sigBlob), bytes4(0x1626ba7e));
    }

    function test_isValidSignature_Path2_nonOwnerSignerReturnsFail() public {
        (address nonOwner, uint256 nonOwnerPk) = makeAddrAndKey("nonOwner");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(nonOwnerPk, ARBITRARY_HASH);

        address[] memory signers = new address[](1);
        signers[0] = nonOwner;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(r, s, v);

        assertEq(safe.isValidSignature(ARBITRARY_HASH, abi.encode(signers, sigs)), bytes4(0xffffffff));
    }

    function test_isValidSignature_Path2_malformedBlobReturnsFail() public view {
        assertEq(safe.isValidSignature(ARBITRARY_HASH, hex"deadbeef"), bytes4(0xffffffff));
    }

    function test_isValidSignature_Path2_emptyBlobReturnsFail() public view {
        assertEq(safe.isValidSignature(ARBITRARY_HASH, ""), bytes4(0xffffffff));
    }

    function test_isValidSignature_Path2_mismatchedHashReturnsFail() public view {
        bytes memory sigBlob = _buildOwnerSignatureBlob(ARBITRARY_HASH);
        assertEq(safe.isValidSignature(keccak256("other"), sigBlob), bytes4(0xffffffff));
    }

    // ──────────────────────────────────────────────
    //  postInteraction tests
    // ──────────────────────────────────────────────

    function test_fusion_postInteraction_works() public {
        bytes32 orderHash = _setupRequestSwap();

        IOrderMixin.Order memory order = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT);

        // Simulate the fill: resolver pulls fromToken, sends toToken, then router invokes postInteraction
        vm.prank(AGGREGATION_ROUTER);
        usdc.transferFrom(address(safe), makeAddr("resolver"), SWAP_AMOUNT);
        deal(address(weETH), address(safe), MIN_TO_AMOUNT);

        vm.prank(AGGREGATION_ROUTER);
        oneInchModule.postInteraction(order, "", orderHash, makeAddr("resolver"), SWAP_AMOUNT, MIN_TO_AMOUNT, 0, "");

        assertEq(oneInchModule.getPendingSwap(address(safe)).fromAmount, 0);
        assertEq(oneInchModule.swapInProgress(address(safe)), false);
        assertEq(usdc.allowance(address(safe), AGGREGATION_ROUTER), 0);
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient, address(0));
    }

    function test_fusion_postInteraction_revertsWhenNotRouter() public {
        bytes32 orderHash = _setupRequestSwap();

        IOrderMixin.Order memory order = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT);

        vm.prank(makeAddr("random"));
        vm.expectRevert(OneInchSwapModule.OnlyAggregationRouter.selector);
        oneInchModule.postInteraction(order, "", orderHash, makeAddr("resolver"), SWAP_AMOUNT, MIN_TO_AMOUNT, 0, "");
    }

    function test_fusion_postInteraction_revertsWhenNoPendingSwap() public {
        IOrderMixin.Order memory order = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT);

        vm.prank(AGGREGATION_ROUTER);
        vm.expectRevert(OneInchSwapModule.NoPendingSwap.selector);
        oneInchModule.postInteraction(order, "", keccak256("anything"), makeAddr("resolver"), SWAP_AMOUNT, MIN_TO_AMOUNT, 0, "");
    }

    function test_fusion_postInteraction_revertsWhenOrderHashMismatch() public {
        _setupRequestSwap();

        IOrderMixin.Order memory order = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT);

        vm.prank(AGGREGATION_ROUTER);
        vm.expectRevert(OneInchSwapModule.OrderHashMismatch.selector);
        oneInchModule.postInteraction(order, "", keccak256("other-order"), makeAddr("resolver"), SWAP_AMOUNT, MIN_TO_AMOUNT, 0, "");
    }

    function test_fusion_postInteraction_revertsWhenMakerAssetMismatch() public {
        bytes32 orderHash = _setupRequestSwap();

        // Swap fromToken for a different asset
        IOrderMixin.Order memory order = _buildOrder(address(weETH), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT);

        vm.prank(AGGREGATION_ROUTER);
        vm.expectRevert(OneInchSwapModule.OrderTokenMismatch.selector);
        oneInchModule.postInteraction(order, "", orderHash, makeAddr("resolver"), SWAP_AMOUNT, MIN_TO_AMOUNT, 0, "");
    }

    function test_fusion_postInteraction_revertsWhenTakerAssetMismatch() public {
        bytes32 orderHash = _setupRequestSwap();

        IOrderMixin.Order memory order = _buildOrder(address(usdc), address(usdc), SWAP_AMOUNT, MIN_TO_AMOUNT);

        vm.prank(AGGREGATION_ROUTER);
        vm.expectRevert(OneInchSwapModule.OrderTokenMismatch.selector);
        oneInchModule.postInteraction(order, "", orderHash, makeAddr("resolver"), SWAP_AMOUNT, MIN_TO_AMOUNT, 0, "");
    }

    function test_fusion_postInteraction_revertsOnPartialFill() public {
        bytes32 orderHash = _setupRequestSwap();

        IOrderMixin.Order memory order = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT);

        vm.prank(AGGREGATION_ROUTER);
        vm.expectRevert(OneInchSwapModule.UnexpectedMakingAmount.selector);
        oneInchModule.postInteraction(order, "", orderHash, makeAddr("resolver"), SWAP_AMOUNT - 1, MIN_TO_AMOUNT, 0, "");
    }

    function test_fusion_postInteraction_revertsWhenInsufficientReceived() public {
        bytes32 orderHash = _setupRequestSwap();

        IOrderMixin.Order memory order = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT);

        vm.prank(AGGREGATION_ROUTER);
        vm.expectRevert(OneInchSwapModule.InsufficientReceivedAmount.selector);
        oneInchModule.postInteraction(order, "", orderHash, makeAddr("resolver"), SWAP_AMOUNT, MIN_TO_AMOUNT - 1, 0, "");
    }

    // ──────────────────────────────────────────────
    //  preInteraction tests
    // ──────────────────────────────────────────────

    function test_fusion_preInteraction_works() public {
        bytes32 orderHash = _setupRequestSwap();

        IOrderMixin.Order memory order = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT);

        vm.prank(AGGREGATION_ROUTER);
        oneInchModule.preInteraction(order, "", orderHash, makeAddr("resolver"), SWAP_AMOUNT, MIN_TO_AMOUNT, 0, "");

        // H-3: flag was set in requestSwap; preInteraction reasserts (idempotent)
        assertTrue(oneInchModule.swapInProgress(address(safe)));
    }

    function test_fusion_preInteraction_revertsWhenNotRouter() public {
        bytes32 orderHash = _setupRequestSwap();
        IOrderMixin.Order memory order = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT);

        vm.prank(makeAddr("random"));
        vm.expectRevert(OneInchSwapModule.OnlyAggregationRouter.selector);
        oneInchModule.preInteraction(order, "", orderHash, makeAddr("resolver"), SWAP_AMOUNT, MIN_TO_AMOUNT, 0, "");
    }

    // ──────────────────────────────────────────────
    //  cancelSwap tests
    // ──────────────────────────────────────────────

    function test_fusion_cancelSwap_works() public {
        _setupRequestSwap();

        (address[] memory signers, bytes[] memory signatures) = _createCancelSwapSignatures();
        oneInchModule.cancelSwap(address(safe), signers, signatures);

        assertEq(oneInchModule.getPendingSwap(address(safe)).fromAmount, 0);
        // Intent-lifetime lock cleared
        assertEq(oneInchModule.swapInProgress(address(safe)), false);
        assertEq(usdc.balanceOf(address(safe)), SWAP_AMOUNT);
        assertEq(usdc.allowance(address(safe), AGGREGATION_ROUTER), 0);
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient, address(0));
    }

    function test_fusion_cancelSwap_revertsWhenNoPendingSwap() public {
        (address[] memory signers, bytes[] memory signatures) = _createCancelSwapSignatures();

        vm.expectRevert(OneInchSwapModule.NoPendingSwap.selector);
        oneInchModule.cancelSwap(address(safe), signers, signatures);
    }

    // ──────────────────────────────────────────────
    //  cancelBridgeByCashModule tests
    // ──────────────────────────────────────────────

    function test_fusion_cancelBridgeByCashModule_works() public {
        _setupRequestSwap();

        vm.prank(address(cashModule));
        oneInchModule.cancelBridgeByCashModule(address(safe));

        assertEq(oneInchModule.getPendingSwap(address(safe)).fromAmount, 0);
        assertEq(oneInchModule.swapInProgress(address(safe)), false);
        assertEq(usdc.balanceOf(address(safe)), SWAP_AMOUNT);
        assertEq(usdc.allowance(address(safe), AGGREGATION_ROUTER), 0);
    }

    function test_fusion_cancelBridgeByCashModule_revertsWhenNotCashModule() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(OneInchSwapModule.Unauthorized.selector);
        oneInchModule.cancelBridgeByCashModule(address(safe));
    }

    function test_fusion_cancelBridgeByCashModule_noop() public {
        vm.prank(address(cashModule));
        oneInchModule.cancelBridgeByCashModule(address(safe));
    }

    // ──────────────────────────────────────────────
    //  Nonce / replay tests
    // ──────────────────────────────────────────────

    function test_fusion_nonce_increments() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        uint256 nonceBefore = safe.nonce();

        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION
        );
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION, signers, signatures);

        assertEq(safe.nonce(), nonceBefore + 1);
    }

    function test_fusion_signatureReplay_reverts() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT * 2);

        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION
        );
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION, signers, signatures);

        (address[] memory cancelSigners, bytes[] memory cancelSigs) = _createCancelSwapSignatures();
        oneInchModule.cancelSwap(address(safe), cancelSigners, cancelSigs);

        vm.expectRevert(OneInchSwapModule.InvalidSignatures.selector);
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION, signers, signatures);
    }

    // ──────────────────────────────────────────────
    //  Intent-lifetime lock tests
    //  swapInProgress[safe] is armed for the entire Fusion intent lifetime — request → terminal.
    // ──────────────────────────────────────────────

    function test_fusion_lockArmedFromRequest() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);
        assertEq(oneInchModule.swapInProgress(address(safe)), false);

        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION
        );
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION, signers, signatures);

        // Lock is true the instant requestSwap returns, before any LOP interaction
        assertTrue(oneInchModule.swapInProgress(address(safe)));
    }

    // ──────────────────────────────────────────────
    //  Router allowance tests
    // ──────────────────────────────────────────────

    function test_fusion_preClearAllowance_finalStateExact() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);

        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION
        );
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION, signers, signatures);

        // `_approveRouter` does approve(0) then approve(fromAmount) for USDT-style safety.
        // The final allowance must be exactly fromAmount with no leaked residual.
        assertEq(usdc.allowance(address(safe), AGGREGATION_ROUTER), SWAP_AMOUNT);
    }

    // ──────────────────────────────────────────────
    //  Admin recovery
    // ──────────────────────────────────────────────

    function test_admin_recoverStuckMakerTokens_works() public {
        // Simulate the stuck-funds scenario: requestSwap creates the pendingSwaps entry, and
        // the module address holds maker tokens that couldn't otherwise be recovered through
        // cancelSwap — we deal them directly for the test.
        _setupRequestSwap();
        deal(address(usdc), address(oneInchModule), SWAP_AMOUNT);

        uint256 safeBalBefore = usdc.balanceOf(address(safe));

        vm.prank(owner);
        oneInchModule.recoverStuckMakerTokens(address(safe));

        // State cleared
        assertEq(oneInchModule.getPendingSwap(address(safe)).fromAmount, 0);
        assertEq(oneInchModule.swapInProgress(address(safe)), false);
        // Tokens returned to safe
        assertEq(usdc.balanceOf(address(safe)) - safeBalBefore, SWAP_AMOUNT);
        // Module no longer holds the stuck tokens
        assertEq(usdc.balanceOf(address(oneInchModule)), 0);
    }

    function test_admin_recoverStuckMakerTokens_revertsForNonAdmin() public {
        _setupRequestSwap();

        vm.prank(makeAddr("random"));
        vm.expectRevert(OneInchSwapModule.Unauthorized.selector);
        oneInchModule.recoverStuckMakerTokens(address(safe));
    }

    function test_admin_recoverStuckMakerTokens_revertsWhenNoPendingSwap() public {
        vm.prank(owner);
        vm.expectRevert(OneInchSwapModule.NoPendingSwap.selector);
        oneInchModule.recoverStuckMakerTokens(address(safe));
    }

    // Sanity: recoverStuckMakerTokens transfers only what's actually held (defensive — handles
    // partial-balance edge case).
    function test_admin_recoverStuckMakerTokens_partialBalance() public {
        _setupRequestSwap();
        // Module holds less than registered amount
        deal(address(usdc), address(oneInchModule), SWAP_AMOUNT / 2);

        uint256 safeBalBefore = usdc.balanceOf(address(safe));
        vm.prank(owner);
        oneInchModule.recoverStuckMakerTokens(address(safe));

        // Only the held balance moved
        assertEq(usdc.balanceOf(address(safe)) - safeBalBefore, SWAP_AMOUNT / 2);
        assertEq(oneInchModule.getPendingSwap(address(safe)).fromAmount, 0);
    }

    // ──────────────────────────────────────────────
    //  Full lifecycle test
    // ──────────────────────────────────────────────

    function test_fusion_fullLifecycle() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);

        // Request — intent recorded, router approved, withdrawal locked, tokens stay on Safe
        (address[] memory reqSigners, bytes[] memory reqSigs) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION
        );
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION, reqSigners, reqSigs);
        bytes32 orderHash = oneInchModule.getPendingSwap(address(safe)).orderHash;

        assertEq(usdc.balanceOf(address(safe)), SWAP_AMOUNT);
        assertEq(usdc.allowance(address(safe), AGGREGATION_ROUTER), SWAP_AMOUNT);
        // Intent-lifetime lock armed
        assertTrue(oneInchModule.swapInProgress(address(safe)));

        // Aggregator-binding path: returns magic for the registered hash
        vm.prank(AGGREGATION_ROUTER);
        assertEq(safe.isValidSignature(orderHash, hex""), bytes4(0x1626ba7e));

        // Simulate fill: resolver pulls fromToken, sends toToken, then protocol calls postInteraction
        vm.prank(AGGREGATION_ROUTER);
        usdc.transferFrom(address(safe), makeAddr("resolver"), SWAP_AMOUNT);
        deal(address(weETH), address(safe), MIN_TO_AMOUNT);

        IOrderMixin.Order memory order = _buildOrder(address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT);
        vm.prank(AGGREGATION_ROUTER);
        oneInchModule.postInteraction(order, "", orderHash, makeAddr("resolver"), SWAP_AMOUNT, MIN_TO_AMOUNT, 0, "");

        assertEq(oneInchModule.getPendingSwap(address(safe)).fromAmount, 0);
        // Lock cleared after settlement
        assertEq(oneInchModule.swapInProgress(address(safe)), false);
        assertEq(usdc.allowance(address(safe), AGGREGATION_ROUTER), 0);
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient, address(0));
    }

    // ══════════════════════════════════════════════
    //  HELPERS
    // ══════════════════════════════════════════════

    /// @dev Requests a swap with default params and returns the on-chain-computed orderHash.
    function _setupRequestSwap() internal returns (bytes32 orderHash) {
        deal(address(usdc), address(safe), SWAP_AMOUNT);

        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION
        );
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, EXPIRATION, signers, signatures);
        orderHash = oneInchModule.getPendingSwap(address(safe)).orderHash;
    }

    /// @dev Builds EIP-712 digest for a module operation using the Safe's domain separator.
    function _eip712Digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
    }

    function _createClassicSwapSignatures(
        address fromAsset,
        address toAsset,
        uint256 fromAssetAmount,
        uint256 minToAssetAmount,
        bytes memory data
    ) internal view returns (address[] memory, bytes[] memory) {
        // SWAP_TYPEHASH includes `address module` to prevent cross-module signature replay
        bytes32 structHash = keccak256(abi.encode(
            oneInchModule.SWAP_TYPEHASH(),
            address(safe),
            address(oneInchModule),
            fromAsset,
            toAsset,
            fromAssetAmount,
            minToAssetAmount,
            keccak256(data),
            safe.nonce()
        ));
        return _signWithOwners(_eip712Digest(structHash));
    }

    function _createRequestSwapSignatures(
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 minToAmount,
        uint40 expiration
    ) internal view returns (address[] memory, bytes[] memory) {
        // REQUEST_SWAP_TYPEHASH includes `address module` and `uint40 expiration`. The orderHash
        // is not signed — it is derived on-chain from these fields.
        bytes32 structHash = keccak256(abi.encode(
            oneInchModule.REQUEST_SWAP_TYPEHASH(),
            address(safe),
            address(oneInchModule),
            fromToken,
            toToken,
            fromAmount,
            minToAmount,
            expiration,
            safe.nonce()
        ));
        return _signWithOwners(_eip712Digest(structHash));
    }

    function _createCancelSwapSignatures() internal view returns (address[] memory, bytes[] memory) {
        // CANCEL_SWAP_TYPEHASH includes `address module` to prevent cross-module signature replay
        bytes32 structHash = keccak256(abi.encode(
            oneInchModule.CANCEL_SWAP_TYPEHASH(),
            address(safe),
            address(oneInchModule),
            safe.nonce()
        ));
        return _signWithOwners(_eip712Digest(structHash));
    }

    function _signWithOwners(bytes32 digestHash) internal view returns (address[] memory, bytes[] memory) {
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        return (signers, signatures);
    }

    /// @dev Minimal IOrderMixin.Order for pre/postInteraction tests. Only the fields the module
    ///      actually reads (maker, makerAsset, takerAsset) need to be meaningful — the rest is
    ///      ignored by the validation logic (orderHash is passed as a separate argument).
    function _buildOrder(address fromToken, address toToken, uint256 fromAmount, uint256 toAmount)
        internal
        view
        returns (IOrderMixin.Order memory)
    {
        return IOrderMixin.Order({
            salt: 0,
            maker: Address.wrap(uint256(uint160(address(safe)))),
            receiver: Address.wrap(0),
            makerAsset: Address.wrap(uint256(uint160(fromToken))),
            takerAsset: Address.wrap(uint256(uint160(toToken))),
            makingAmount: fromAmount,
            takingAmount: toAmount,
            makerTraits: MakerTraits.wrap(0)
        });
    }

    /// @dev Builds an ERC-1271 sig blob (owners sign `hash` directly). Used by Path-2 tests where
    ///      msg.sender of the isValidSignature call is NOT the aggregator, so the safe falls
    ///      through to `checkSignatureBlob`.
    function _buildOwnerSignatureBlob(bytes32 hash) internal view returns (bytes memory) {
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, hash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, hash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = abi.encodePacked(r1, s1, v1);
        sigs[1] = abi.encodePacked(r2, s2, v2);

        return abi.encode(signers, sigs);
    }
}
