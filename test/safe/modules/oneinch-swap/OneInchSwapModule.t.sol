// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {OneInchSwapModule, ModuleBase, ModuleCheckBalance} from "../../../../src/modules/oneinch-swap/OneInchSwapModule.sol";
import {ArrayDeDupLib, EtherFiDataProvider, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup, IDebtManager} from "../../SafeTestSetup.t.sol";
import {ICashModule} from "../../../../src/interfaces/ICashModule.sol";
import {CashVerificationLib} from "../../../../src/libraries/CashVerificationLib.sol";

contract OneInchSwapModuleTest is SafeTestSetup {
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

        vm.startPrank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);
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
    //  requestSwap tests (merged request+execute)
    // ──────────────────────────────────────────────

    function test_fusion_requestSwap_works() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);

        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, TEST_ORDER_HASH
        );

        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, TEST_ORDER_HASH, signers, signatures);

        OneInchSwapModule.PendingSwap memory pendingSwap = oneInchModule.getPendingSwap(address(safe));
        assertEq(pendingSwap.fromToken, address(usdc));
        assertEq(pendingSwap.toToken, address(weETH));
        assertEq(pendingSwap.fromAmount, SWAP_AMOUNT);
        assertEq(pendingSwap.minToAmount, MIN_TO_AMOUNT);
        assertEq(pendingSwap.orderHash, TEST_ORDER_HASH);
        assertEq(pendingSwap.fromBalanceBefore, SWAP_AMOUNT);
        assertEq(pendingSwap.toBalanceBefore, 0);

        assertEq(usdc.balanceOf(address(safe)), SWAP_AMOUNT);
        assertEq(usdc.allowance(address(safe), AGGREGATION_ROUTER), SWAP_AMOUNT);
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient, address(oneInchModule));
    }

    function test_fusion_requestSwap_revertsWithNativeETH() public {
        address ETH_ADDR = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            ETH_ADDR, address(weETH), 1 ether, MIN_TO_AMOUNT, TEST_ORDER_HASH
        );

        vm.expectRevert(OneInchSwapModule.NativeETHNotSupported.selector);
        oneInchModule.requestSwap(address(safe), ETH_ADDR, address(weETH), 1 ether, MIN_TO_AMOUNT, TEST_ORDER_HASH, signers, signatures);
    }

    function test_fusion_requestSwap_revertsWhenSameAsset() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);

        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(usdc), SWAP_AMOUNT, MIN_TO_AMOUNT, TEST_ORDER_HASH
        );

        vm.expectRevert(OneInchSwapModule.SwappingToSameAsset.selector);
        oneInchModule.requestSwap(address(safe), address(usdc), address(usdc), SWAP_AMOUNT, MIN_TO_AMOUNT, TEST_ORDER_HASH, signers, signatures);
    }

    function test_fusion_requestSwap_revertsWhenZeroAmount() public {
        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), 0, MIN_TO_AMOUNT, TEST_ORDER_HASH
        );

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), 0, MIN_TO_AMOUNT, TEST_ORDER_HASH, signers, signatures);
    }

    function test_fusion_requestSwap_revertsWhenZeroOrderHash() public {
        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, bytes32(0)
        );

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, bytes32(0), signers, signatures);
    }

    function test_fusion_requestSwap_revertsWhenInsufficientBalance() public {
        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, TEST_ORDER_HASH
        );

        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, TEST_ORDER_HASH, signers, signatures);
    }

    function test_fusion_requestSwap_revertsWhenSwapAlreadyPending() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT * 2);

        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, TEST_ORDER_HASH
        );
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, TEST_ORDER_HASH, signers, signatures);

        bytes32 orderHash2 = keccak256("second-order");
        (address[] memory signers2, bytes[] memory signatures2) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, orderHash2
        );

        vm.expectRevert(OneInchSwapModule.SwapAlreadyPending.selector);
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, orderHash2, signers2, signatures2);
    }

    function test_fusion_requestSwap_revertsWithInvalidSignatures() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);

        // Signers authorize a different fromAmount than what's passed to requestSwap
        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT + 1, MIN_TO_AMOUNT, TEST_ORDER_HASH
        );

        vm.expectRevert(OneInchSwapModule.InvalidSignatures.selector);
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, TEST_ORDER_HASH, signers, signatures);
    }

    // ──────────────────────────────────────────────
    //  ERC-1271 direct-validation tests (on Safe)
    // ──────────────────────────────────────────────

    function test_fusion_isValidSignature_validQuorumReturnsMagic() public view {
        bytes memory sigBlob = _buildOwnerSignatureBlob(TEST_ORDER_HASH);
        assertEq(safe.isValidSignature(TEST_ORDER_HASH, sigBlob), bytes4(0x1626ba7e));
    }

    function test_fusion_isValidSignature_nonOwnerSignerReturnsFail() public {
        (address nonOwner, uint256 nonOwnerPk) = makeAddrAndKey("nonOwner");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(nonOwnerPk, TEST_ORDER_HASH);

        address[] memory signers = new address[](1);
        signers[0] = nonOwner;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(r, s, v);

        assertEq(safe.isValidSignature(TEST_ORDER_HASH, abi.encode(signers, sigs)), bytes4(0xffffffff));
    }

    function test_fusion_isValidSignature_malformedBlobReturnsFail() public view {
        assertEq(safe.isValidSignature(TEST_ORDER_HASH, hex"deadbeef"), bytes4(0xffffffff));
    }

    function test_fusion_isValidSignature_emptyBlobReturnsFail() public view {
        assertEq(safe.isValidSignature(TEST_ORDER_HASH, ""), bytes4(0xffffffff));
    }

    function test_fusion_isValidSignature_mismatchedHashReturnsFail() public view {
        bytes memory sigBlob = _buildOwnerSignatureBlob(TEST_ORDER_HASH);
        assertEq(safe.isValidSignature(keccak256("other"), sigBlob), bytes4(0xffffffff));
    }

    // ──────────────────────────────────────────────
    //  settleSwap tests (admin-only, no signatures)
    // ──────────────────────────────────────────────

    function test_fusion_settleSwap_works() public {
        _setupRequestSwap();

        // Simulate full fill: resolver pulls fromToken from Safe, sends toToken to Safe
        vm.prank(AGGREGATION_ROUTER);
        usdc.transferFrom(address(safe), makeAddr("resolver"), SWAP_AMOUNT);
        deal(address(weETH), address(safe), MIN_TO_AMOUNT);

        // Any safe admin can settle (owners are admins by default)
        vm.prank(owner1);
        oneInchModule.settleSwap(address(safe));

        assertEq(oneInchModule.getPendingSwap(address(safe)).fromAmount, 0);
        assertEq(usdc.allowance(address(safe), AGGREGATION_ROUTER), 0);
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient, address(0));
    }

    function test_fusion_settleSwap_revertsWhenNotAdmin() public {
        _setupRequestSwap();

        vm.prank(AGGREGATION_ROUTER);
        usdc.transferFrom(address(safe), makeAddr("resolver"), SWAP_AMOUNT);
        deal(address(weETH), address(safe), MIN_TO_AMOUNT);

        vm.prank(makeAddr("random"));
        vm.expectRevert(OneInchSwapModule.Unauthorized.selector);
        oneInchModule.settleSwap(address(safe));
    }

    function test_fusion_settleSwap_revertsWhenNoPendingSwap() public {
        vm.prank(owner1);
        vm.expectRevert(OneInchSwapModule.NoPendingSwap.selector);
        oneInchModule.settleSwap(address(safe));
    }

    function test_fusion_settleSwap_revertsWhenOrderNotFilled() public {
        _setupRequestSwap();

        // Don't simulate fill — tokens still on Safe
        deal(address(weETH), address(safe), MIN_TO_AMOUNT);

        vm.prank(owner1);
        vm.expectRevert(OneInchSwapModule.OrderNotFilled.selector);
        oneInchModule.settleSwap(address(safe));
    }

    function test_fusion_settleSwap_revertsWhenInsufficientReceived() public {
        _setupRequestSwap();

        vm.prank(AGGREGATION_ROUTER);
        usdc.transferFrom(address(safe), makeAddr("resolver"), SWAP_AMOUNT);
        // Don't deal toToken to safe

        vm.prank(owner1);
        vm.expectRevert(OneInchSwapModule.InsufficientReceivedAmount.selector);
        oneInchModule.settleSwap(address(safe));
    }

    // NOTE: partial-fill tests removed per design D5 (no partial fills allowed).
    // A partial fill would leave safe balance < registered pendingWithdrawalAmount, which
    // underflows CashLens.getUserTotalCollateral (balance - pending) during postOpHook →
    // DebtManagerCore.ensureHealth. That's a CashLens edge case, but the design forbids
    // the precondition from occurring.

    // ──────────────────────────────────────────────
    //  cancelSwap tests
    // ──────────────────────────────────────────────

    function test_fusion_cancelSwap_works() public {
        _setupRequestSwap();

        (address[] memory signers, bytes[] memory signatures) = _createCancelSwapSignatures();
        oneInchModule.cancelSwap(address(safe), signers, signatures);

        assertEq(oneInchModule.getPendingSwap(address(safe)).fromAmount, 0);
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
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, TEST_ORDER_HASH
        );
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, TEST_ORDER_HASH, signers, signatures);

        assertEq(safe.nonce(), nonceBefore + 1);
    }

    function test_fusion_signatureReplay_reverts() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT * 2);

        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, TEST_ORDER_HASH
        );
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, TEST_ORDER_HASH, signers, signatures);

        (address[] memory cancelSigners, bytes[] memory cancelSigs) = _createCancelSwapSignatures();
        oneInchModule.cancelSwap(address(safe), cancelSigners, cancelSigs);

        vm.expectRevert(OneInchSwapModule.InvalidSignatures.selector);
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, TEST_ORDER_HASH, signers, signatures);
    }

    // ──────────────────────────────────────────────
    //  Full lifecycle test
    // ──────────────────────────────────────────────

    function test_fusion_fullLifecycle() public {
        deal(address(usdc), address(safe), SWAP_AMOUNT);

        // Request — intent recorded, router approved, withdrawal locked, tokens stay on Safe
        (address[] memory reqSigners, bytes[] memory reqSigs) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, TEST_ORDER_HASH
        );
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, TEST_ORDER_HASH, reqSigners, reqSigs);

        assertEq(usdc.balanceOf(address(safe)), SWAP_AMOUNT);
        assertEq(usdc.allowance(address(safe), AGGREGATION_ROUTER), SWAP_AMOUNT);

        // ERC-1271: owners' sig blob over order hash validates
        bytes memory sigBlob = _buildOwnerSignatureBlob(TEST_ORDER_HASH);
        assertEq(safe.isValidSignature(TEST_ORDER_HASH, sigBlob), bytes4(0x1626ba7e));

        // Simulate fill
        vm.prank(AGGREGATION_ROUTER);
        usdc.transferFrom(address(safe), makeAddr("resolver"), SWAP_AMOUNT);
        deal(address(weETH), address(safe), MIN_TO_AMOUNT);

        // Settle (admin-only)
        vm.prank(owner1);
        oneInchModule.settleSwap(address(safe));

        assertEq(oneInchModule.getPendingSwap(address(safe)).fromAmount, 0);
        assertEq(usdc.allowance(address(safe), AGGREGATION_ROUTER), 0);
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient, address(0));
    }

    // ══════════════════════════════════════════════
    //  HELPERS
    // ══════════════════════════════════════════════

    function _setupRequestSwap() internal {
        deal(address(usdc), address(safe), SWAP_AMOUNT);

        (address[] memory signers, bytes[] memory signatures) = _createRequestSwapSignatures(
            address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, TEST_ORDER_HASH
        );
        oneInchModule.requestSwap(address(safe), address(usdc), address(weETH), SWAP_AMOUNT, MIN_TO_AMOUNT, TEST_ORDER_HASH, signers, signatures);
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
        bytes32 structHash = keccak256(abi.encode(
            oneInchModule.SWAP_TYPEHASH(),
            address(safe),
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
        bytes32 orderHash
    ) internal view returns (address[] memory, bytes[] memory) {
        bytes32 structHash = keccak256(abi.encode(
            oneInchModule.REQUEST_SWAP_TYPEHASH(),
            address(safe),
            fromToken,
            toToken,
            fromAmount,
            minToAmount,
            orderHash,
            safe.nonce()
        ));
        return _signWithOwners(_eip712Digest(structHash));
    }

    function _createCancelSwapSignatures() internal view returns (address[] memory, bytes[] memory) {
        bytes32 structHash = keccak256(abi.encode(
            oneInchModule.CANCEL_SWAP_TYPEHASH(),
            address(safe),
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

    /// @dev Builds an ERC-1271 sig blob (owners sign `hash` directly — not wrapped, as 1inch
    ///      passes its own order hash to isValidSignature).
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
