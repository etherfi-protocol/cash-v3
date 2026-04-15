// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {OneInchSwapModule, ModuleBase, ModuleCheckBalance} from "../../../../src/modules/oneinch-swap/OneInchSwapModule.sol";
import {OneInchSwapDescription} from "../../../../src/interfaces/IOneInch.sol";
import {ArrayDeDupLib, EtherFiDataProvider, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup, IDebtManager} from "../../SafeTestSetup.t.sol";
import {ICashModule} from "../../../../src/interfaces/ICashModule.sol";
import {CashVerificationLib} from "../../../../src/libraries/CashVerificationLib.sol";

contract OneInchSwapModuleTest is SafeTestSetup {
    using MessageHashUtils for bytes32;

    OneInchSwapModule public oneInchModule;

    // 1inch Aggregation Router on Optimism
    address public constant AGGREGATION_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;

    // Test swap parameters
    uint256 public constant SWAP_AMOUNT = 100e6; // 100 USDC
    uint256 public constant MIN_TO_AMOUNT = 1e16; // 0.01 weETH
    bytes32 public constant TEST_ORDER_HASH = keccak256("test-order-hash");

    function setUp() public override {
        super.setUp();

        oneInchModule = new OneInchSwapModule(AGGREGATION_ROUTER, address(dataProvider));

        // Register module on data provider
        address[] memory modules = new address[](1);
        modules[0] = address(oneInchModule);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.prank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);

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

    function test_classic_swap_validatesSwapDescription() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);

        // Build calldata with 1inch swap() selector but wrong dstReceiver
        bytes memory swapData = _buildOneInchSwapCalldata(
            address(usdc),      // srcToken
            address(weETH),     // dstToken
            makeAddr("wrong"),  // dstReceiver (wrong - should be safe)
            SWAP_AMOUNT,
            MIN_TO_AMOUNT
        );

        (address[] memory signers, bytes[] memory signatures) = _createClassicSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, swapData
        );

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        oneInchModule.swap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, swapData, signers, signatures);
    }

    function test_classic_swap_validatesSlippage() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);

        // Build calldata where minReturnAmount in desc < minToAssetAmount
        bytes memory swapData = _buildOneInchSwapCalldata(
            address(usdc),
            address(weETH),
            address(safe),
            SWAP_AMOUNT,
            MIN_TO_AMOUNT - 1  // Less than what we're requiring
        );

        (address[] memory signers, bytes[] memory signatures) = _createClassicSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, swapData
        );

        vm.expectRevert(OneInchSwapModule.SlippageTooHigh.selector);
        oneInchModule.swap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, swapData, signers, signatures);
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
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT
        );

        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, signers, signatures);

        OneInchSwapModule.PendingSwap memory pendingSwap = oneInchModule.getPendingSwap(address(safe));
        assertEq(pendingSwap.fromToken, address(usdc));
        assertEq(pendingSwap.toToken, address(weETH));
        assertEq(pendingSwap.fromAmount, SWAP_AMOUNT);
        assertEq(pendingSwap.minToAmount, MIN_TO_AMOUNT);
        assertEq(pendingSwap.orderHash, bytes32(0));

        // Tokens stay on Safe
        assertEq(usdc.balanceOf(address(safe)), SWAP_AMOUNT);
    }

    function test_fusion_requestSwap_revertsWithNativeETH() public {
        address ETH_ADDR = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            ETH_ADDR, address(weETH), 1 ether, MIN_TO_AMOUNT
        );

        vm.expectRevert(OneInchSwapModule.NativeETHNotSupported.selector);
        oneInchModule.requestSwap(address(safe), ETH_ADDR, address(weETH), 1 ether, MIN_TO_AMOUNT, signers, signatures);
    }

    function test_fusion_requestSwap_revertsWhenSameAsset() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);

        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(usdc), SWAP_AMOUNT, MIN_TO_AMOUNT
        );

        vm.expectRevert(OneInchSwapModule.SwappingToSameAsset.selector);
        oneInchModule.requestSwap(address(safe), address(usdc), address(usdc), SWAP_AMOUNT, MIN_TO_AMOUNT, signers, signatures);
    }

    function test_fusion_requestSwap_revertsWhenZeroAmount() public {
        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), 0, MIN_TO_AMOUNT
        );

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), 0, MIN_TO_AMOUNT, signers, signatures);
    }

    function test_fusion_requestSwap_revertsWhenInsufficientBalance() public {
        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT
        );

        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, signers, signatures);
    }

    function test_fusion_requestSwap_revertsWhenSwapAlreadyPending() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT * 2);

        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT
        );
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, signers, signatures);

        (address[] memory signers2, bytes[] memory signatures2) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT
        );

        vm.expectRevert(OneInchSwapModule.SwapAlreadyPending.selector);
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, signers2, signatures2);
    }

    function test_fusion_requestSwap_revertsWithInvalidSignatures() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);

        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT + 1, MIN_TO_AMOUNT
        );

        vm.expectRevert(OneInchSwapModule.InvalidSignatures.selector);
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, signers, signatures);
    }

    // ──────────────────────────────────────────────
    //  executeSwap tests
    // ──────────────────────────────────────────────

    function test_fusion_executeSwap_works() public {
        _setupRequestSwap();

        (address[] memory signers, bytes[] memory signatures) = _createExecuteSwapSignatures(TEST_ORDER_HASH);
        oneInchModule.executeSwap(address(safe), TEST_ORDER_HASH, signers, signatures);

        OneInchSwapModule.PendingSwap memory pendingSwap = oneInchModule.getPendingSwap(address(safe));
        assertEq(pendingSwap.orderHash, TEST_ORDER_HASH);
        assertEq(pendingSwap.fromBalanceBefore, SWAP_AMOUNT);
        assertEq(pendingSwap.toBalanceBefore, 0);

        // Tokens still on Safe
        assertEq(usdc.balanceOf(address(safe)), SWAP_AMOUNT);

        // Safe authorized the order hash (ERC-1271)
        assertEq(safe.isValidSignature(TEST_ORDER_HASH, ""), bytes4(0x1626ba7e));

        // Router has approval from Safe
        assertEq(usdc.allowance(address(safe), AGGREGATION_ROUTER), SWAP_AMOUNT);
    }

    function test_fusion_executeSwap_revertsWhenNoPendingSwap() public {
        (address[] memory signers, bytes[] memory signatures) = _createExecuteSwapSignatures(TEST_ORDER_HASH);

        vm.expectRevert(OneInchSwapModule.NoPendingSwap.selector);
        oneInchModule.executeSwap(address(safe), TEST_ORDER_HASH, signers, signatures);
    }

    function test_fusion_executeSwap_revertsWhenZeroOrderHash() public {
        _setupRequestSwap();

        (address[] memory signers, bytes[] memory signatures) = _createExecuteSwapSignatures(bytes32(0));

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        oneInchModule.executeSwap(address(safe), bytes32(0), signers, signatures);
    }

    function test_fusion_executeSwap_revertsWhenAlreadyExecuted() public {
        _setupRequestAndExecuteSwap();

        bytes32 newHash = keccak256("new-hash");
        (address[] memory signers, bytes[] memory signatures) = _createExecuteSwapSignatures(newHash);

        vm.expectRevert(OneInchSwapModule.SwapAlreadyExecuted.selector);
        oneInchModule.executeSwap(address(safe), newHash, signers, signatures);
    }

    // ──────────────────────────────────────────────
    //  isValidSignature tests (on Safe, not module)
    // ──────────────────────────────────────────────

    function test_fusion_isValidSignature_authorized() public {
        _setupRequestAndExecuteSwap();
        assertEq(safe.isValidSignature(TEST_ORDER_HASH, ""), bytes4(0x1626ba7e));
    }

    function test_fusion_isValidSignature_unauthorized() public view {
        assertEq(safe.isValidSignature(keccak256("random"), ""), bytes4(0xffffffff));
    }

    // ──────────────────────────────────────────────
    //  settleSwap tests
    // ──────────────────────────────────────────────

    function test_fusion_settleSwap_works() public {
        _setupRequestAndExecuteSwap();

        // Simulate fill: resolver pulls fromToken from Safe, sends toToken to Safe
        vm.prank(AGGREGATION_ROUTER);
        usdc.transferFrom(address(safe), makeAddr("resolver"), SWAP_AMOUNT);
        deal(address(weETH), address(safe), MIN_TO_AMOUNT);

        (address[] memory signers, bytes[] memory signatures) = _createSettleSwapSignatures();
        oneInchModule.settleSwap(address(safe), signers, signatures);

        // State cleaned up
        OneInchSwapModule.PendingSwap memory pendingSwap = oneInchModule.getPendingSwap(address(safe));
        assertEq(pendingSwap.fromAmount, 0);

        // Order hash revoked
        assertEq(safe.isValidSignature(TEST_ORDER_HASH, ""), bytes4(0xffffffff));

        // Approval revoked
        assertEq(usdc.allowance(address(safe), AGGREGATION_ROUTER), 0);
    }

    function test_fusion_settleSwap_revertsWhenNoPendingSwap() public {
        (address[] memory signers, bytes[] memory signatures) = _createSettleSwapSignatures();

        vm.expectRevert(OneInchSwapModule.NoPendingSwap.selector);
        oneInchModule.settleSwap(address(safe), signers, signatures);
    }

    function test_fusion_settleSwap_revertsWhenNotExecuted() public {
        _setupRequestSwap();

        (address[] memory signers, bytes[] memory signatures) = _createSettleSwapSignatures();

        vm.expectRevert(OneInchSwapModule.SwapNotExecuted.selector);
        oneInchModule.settleSwap(address(safe), signers, signatures);
    }

    function test_fusion_settleSwap_revertsWhenOrderNotFilled() public {
        _setupRequestAndExecuteSwap();

        // Don't simulate fill — tokens still on Safe
        deal(address(weETH), address(safe), MIN_TO_AMOUNT);

        (address[] memory signers, bytes[] memory signatures) = _createSettleSwapSignatures();

        vm.expectRevert(OneInchSwapModule.OrderNotFilled.selector);
        oneInchModule.settleSwap(address(safe), signers, signatures);
    }

    function test_fusion_settleSwap_revertsWhenInsufficientReceived() public {
        _setupRequestAndExecuteSwap();

        // Simulate fill but safe doesn't receive enough toToken
        vm.prank(AGGREGATION_ROUTER);
        usdc.transferFrom(address(safe), makeAddr("resolver"), SWAP_AMOUNT);
        // Don't deal toToken to safe — balance is 0

        (address[] memory signers, bytes[] memory signatures) = _createSettleSwapSignatures();

        vm.expectRevert(OneInchSwapModule.InsufficientReceivedAmount.selector);
        oneInchModule.settleSwap(address(safe), signers, signatures);
    }

    function test_fusion_settleSwap_partialFill() public {
        _setupRequestAndExecuteSwap();

        // Simulate partial fill: router only takes half
        uint256 halfAmount = SWAP_AMOUNT / 2;
        vm.prank(AGGREGATION_ROUTER);
        usdc.transferFrom(address(safe), makeAddr("resolver"), halfAmount);
        deal(address(weETH), address(safe), MIN_TO_AMOUNT);

        (address[] memory signers, bytes[] memory signatures) = _createSettleSwapSignatures();
        oneInchModule.settleSwap(address(safe), signers, signatures);

        // Remaining half stays on Safe (never left)
        assertEq(usdc.balanceOf(address(safe)), halfAmount);

        // State cleaned up
        assertEq(oneInchModule.getPendingSwap(address(safe)).fromAmount, 0);
    }

    // ──────────────────────────────────────────────
    //  cancelSwap tests
    // ──────────────────────────────────────────────

    function test_fusion_cancelSwap_beforeExecute() public {
        _setupRequestSwap();

        (address[] memory signers, bytes[] memory signatures) = _createCancelSwapSignatures();
        oneInchModule.cancelSwap(address(safe), signers, signatures);

        assertEq(oneInchModule.getPendingSwap(address(safe)).fromAmount, 0);
        // Tokens still on Safe
        assertEq(usdc.balanceOf(address(safe)), SWAP_AMOUNT);
    }

    function test_fusion_cancelSwap_afterExecute() public {
        _setupRequestAndExecuteSwap();

        (address[] memory signers, bytes[] memory signatures) = _createCancelSwapSignatures();
        oneInchModule.cancelSwap(address(safe), signers, signatures);

        assertEq(oneInchModule.getPendingSwap(address(safe)).fromAmount, 0);
        // Tokens still on Safe
        assertEq(usdc.balanceOf(address(safe)), SWAP_AMOUNT);
        // Order hash revoked
        assertEq(safe.isValidSignature(TEST_ORDER_HASH, ""), bytes4(0xffffffff));
        // Approval revoked
        assertEq(usdc.allowance(address(safe), AGGREGATION_ROUTER), 0);
    }

    function test_fusion_cancelSwap_afterPartialFill() public {
        _setupRequestAndExecuteSwap();

        // Simulate partial fill — router took half
        uint256 halfAmount = SWAP_AMOUNT / 2;
        vm.prank(AGGREGATION_ROUTER);
        usdc.transferFrom(address(safe), makeAddr("resolver"), halfAmount);

        (address[] memory signers, bytes[] memory signatures) = _createCancelSwapSignatures();
        oneInchModule.cancelSwap(address(safe), signers, signatures);

        // Half remains on Safe
        assertEq(usdc.balanceOf(address(safe)), halfAmount);
        assertEq(oneInchModule.getPendingSwap(address(safe)).fromAmount, 0);
        assertEq(safe.isValidSignature(TEST_ORDER_HASH, ""), bytes4(0xffffffff));
    }

    function test_fusion_cancelSwap_revertsWhenNoPendingSwap() public {
        (address[] memory signers, bytes[] memory signatures) = _createCancelSwapSignatures();

        vm.expectRevert(OneInchSwapModule.NoPendingSwap.selector);
        oneInchModule.cancelSwap(address(safe), signers, signatures);
    }

    // ──────────────────────────────────────────────
    //  cancelBridgeByCashModule tests
    // ──────────────────────────────────────────────

    function test_fusion_cancelBridgeByCashModule_beforeExecute() public {
        _setupRequestSwap();

        vm.prank(address(cashModule));
        oneInchModule.cancelBridgeByCashModule(address(safe));

        assertEq(oneInchModule.getPendingSwap(address(safe)).fromAmount, 0);
        // Tokens still on Safe
        assertEq(usdc.balanceOf(address(safe)), SWAP_AMOUNT);
    }

    function test_fusion_cancelBridgeByCashModule_afterExecute() public {
        _setupRequestAndExecuteSwap();

        vm.prank(address(cashModule));
        oneInchModule.cancelBridgeByCashModule(address(safe));

        assertEq(oneInchModule.getPendingSwap(address(safe)).fromAmount, 0);
        // Tokens still on Safe
        assertEq(usdc.balanceOf(address(safe)), SWAP_AMOUNT);
        // Order hash revoked
        assertEq(safe.isValidSignature(TEST_ORDER_HASH, ""), bytes4(0xffffffff));
        // Approval revoked
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
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT
        );
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, signers, signatures);

        assertEq(safe.nonce(), nonceBefore + 1);
    }

    function test_fusion_signatureReplay_reverts() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT * 2);

        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT
        );
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, signers, signatures);

        (address[] memory cancelSigners, bytes[] memory cancelSigs) = _createCancelSwapSignatures();
        oneInchModule.cancelSwap(address(safe), cancelSigners, cancelSigs);

        vm.expectRevert(OneInchSwapModule.InvalidSignatures.selector);
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, signers, signatures);
    }

    // ──────────────────────────────────────────────
    //  Full lifecycle test
    // ──────────────────────────────────────────────

    function test_fusion_fullLifecycle() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);

        // Request — intent recorded, tokens stay on Safe
        (address[] memory reqSigners, bytes[] memory reqSigs) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT
        );
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, reqSigners, reqSigs);
        assertEq(usdc.balanceOf(address(safe)), SWAP_AMOUNT);

        // Execute — Safe approves router, authorizes order hash
        (address[] memory execSigners, bytes[] memory execSigs) = _createExecuteSwapSignatures(TEST_ORDER_HASH);
        oneInchModule.executeSwap(address(safe), TEST_ORDER_HASH, execSigners, execSigs);

        assertEq(safe.isValidSignature(TEST_ORDER_HASH, ""), bytes4(0x1626ba7e));
        assertEq(usdc.allowance(address(safe), AGGREGATION_ROUTER), SWAP_AMOUNT);

        // Simulate fill — resolver pulls from Safe, sends toToken to Safe
        vm.prank(AGGREGATION_ROUTER);
        usdc.transferFrom(address(safe), makeAddr("resolver"), SWAP_AMOUNT);
        deal(address(weETH), address(safe), MIN_TO_AMOUNT);

        // Settle — verify fill, clean up
        (address[] memory settleSigners, bytes[] memory settleSigs) = _createSettleSwapSignatures();
        oneInchModule.settleSwap(address(safe), settleSigners, settleSigs);

        assertEq(oneInchModule.getPendingSwap(address(safe)).fromAmount, 0);
        assertEq(safe.isValidSignature(TEST_ORDER_HASH, ""), bytes4(0xffffffff));
        assertEq(usdc.allowance(address(safe), AGGREGATION_ROUTER), 0);
    }

    // ──────────────────────────────────────────────
    //  Concurrent swaps — different Safes, same token (no mutex needed)
    // ──────────────────────────────────────────────

    // Note: Testing concurrent same-token swaps across different safes requires
    // deploying a second safe, which depends on the test harness infrastructure.
    // The key architectural point is: since tokens never leave each Safe, there is
    // no shared custody and no fungible token attribution problem.

    // ══════════════════════════════════════════════
    //  HELPERS
    // ══════════════════════════════════════════════

    function _setupRequestSwap() internal {
        deal(address(usdc), address(safe), SWAP_AMOUNT);

        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT
        );
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, signers, signatures);
    }

    function _setupRequestAndExecuteSwap() internal {
        _setupRequestSwap();

        (address[] memory signers, bytes[] memory signatures) = _createExecuteSwapSignatures(TEST_ORDER_HASH);
        oneInchModule.executeSwap(address(safe), TEST_ORDER_HASH, signers, signatures);
    }

    // Unified signature helper
    function _createSignatures(
        bytes32 selector,
        bytes memory data
    ) internal view returns (address[] memory, bytes[] memory) {
        bytes32 digestHash = keccak256(abi.encodePacked(
            selector,
            block.chainid,
            address(oneInchModule),
            safe.nonce(),
            address(safe),
            data
        )).toEthSignedMessageHash();

        return _signWithOwners(digestHash);
    }

    function _createClassicSwapSignatures(
        address fromAsset,
        address toAsset,
        uint256 fromAssetAmount,
        uint256 minToAssetAmount,
        bytes memory data
    ) internal view returns (address[] memory, bytes[] memory) {
        return _createSignatures(oneInchModule.SWAP_SIG(), abi.encode(fromAsset, toAsset, fromAssetAmount, minToAssetAmount, data));
    }

    function _createRequestSwapSignatures(
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 minToAmount
    ) internal view returns (address[] memory, bytes[] memory) {
        return _createSignatures(oneInchModule.REQUEST_SWAP_SIG(), abi.encode(fromToken, toToken, fromAmount, minToAmount));
    }

    function _createExecuteSwapSignatures(
        bytes32 orderHash
    ) internal view returns (address[] memory, bytes[] memory) {
        return _createSignatures(oneInchModule.EXECUTE_SWAP_SIG(), abi.encode(orderHash));
    }

    function _createSettleSwapSignatures() internal view returns (address[] memory, bytes[] memory) {
        return _createSignatures(oneInchModule.SETTLE_SWAP_SIG(), "");
    }

    function _createCancelSwapSignatures() internal view returns (address[] memory, bytes[] memory) {
        return _createSignatures(oneInchModule.CANCEL_SWAP_SIG(), "");
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

    /// @dev Builds mock 1inch swap() calldata with selector 0x12aa3caf
    function _buildOneInchSwapCalldata(
        address srcToken,
        address dstToken,
        address dstReceiver,
        uint256 amount,
        uint256 minReturnAmount
    ) internal pure returns (bytes memory) {
        OneInchSwapDescription memory desc = OneInchSwapDescription({
            srcToken: IERC20(srcToken),
            dstToken: IERC20(dstToken),
            srcReceiver: payable(address(0)),
            dstReceiver: payable(dstReceiver),
            amount: amount,
            minReturnAmount: minReturnAmount,
            flags: 0
        });

        return abi.encodeWithSelector(
            bytes4(0x12aa3caf),
            address(0),  // executor
            desc,
            "",           // permit
            ""            // data
        );
    }
}
