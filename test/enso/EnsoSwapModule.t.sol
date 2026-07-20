// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Vm } from "forge-std/Vm.sol";

import { EnsoSwapModule } from "../../src/enso/EnsoSwapModule.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { ModuleBase } from "../../src/modules/ModuleBase.sol";
import { UpgradeableProxy } from "../../src/utils/UpgradeableProxy.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { SafeTestSetup } from "../safe/SafeTestSetup.t.sol";

/// @dev Mock Enso Router for the forward-calldata path: when called with the encoded
///      `swap(token, amount)`, it pulls `amount` of `token` from the caller (the safe),
///      recording the pull so the test can assert the approve->call->reset flow.
contract EnsoRouterStub {
    address public lastCaller;
    uint256 public pulled;
    uint256 public callCount;

    function swap(address token, uint256 amount) external {
        lastCaller = msg.sender;
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        pulled = amount;
        callCount++;
    }

    function swapTo(
        address srcToken,
        uint256 srcAmount,
        address dstToken,
        address recipient,
        uint256 dstAmount
    ) external {
        lastCaller = msg.sender;
        IERC20(srcToken).transferFrom(msg.sender, address(this), srcAmount);
        IERC20(dstToken).transfer(recipient, dstAmount);
        pulled = srcAmount;
        callCount++;
    }

    function swapToNative(
        address srcToken,
        uint256 srcAmount,
        address payable recipient,
        uint256 dstAmount
    ) external {
        lastCaller = msg.sender;
        IERC20(srcToken).transferFrom(msg.sender, address(this), srcAmount);
        (bool success,) = recipient.call{ value: dstAmount }("");
        require(success, "native transfer failed");
        pulled = srcAmount;
        callCount++;
    }

    receive() external payable {}
}

contract EnsoSwapModuleTest is SafeTestSetup {
    using MessageHashUtils for bytes32;

    EnsoSwapModule internal module;
    EnsoRouterStub internal ensoRouter;
    address internal keeper = makeAddr("keeper");
    address internal moduleAdmin = makeAddr("moduleAdmin");
    address internal recipient = makeAddr("recipient");

    uint256 internal constant DST_CHAIN = 1;
    uint256 internal constant SRC_AMOUNT = 1_000e6;
    uint256 internal constant MIN_OUT = 990_000_000_000_000;
    address internal constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function setUp() public override {
        super.setUp();

        ensoRouter = new EnsoRouterStub();
        address moduleImpl = address(new EnsoSwapModule(address(dataProvider)));
        module = EnsoSwapModule(address(new UUPSProxy(
            moduleImpl,
            abi.encodeWithSelector(
                EnsoSwapModule.initialize.selector,
                address(roleRegistry),
                address(ensoRouter)
            )
        )));

        address[] memory mods = new address[](1);
        mods[0] = address(module);
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.startPrank(owner);
        dataProvider.configureModules(mods, shouldWhitelist);
        cashModule.configureModulesCanRequestWithdraw(mods, shouldWhitelist);

        roleRegistry.grantRole(module.ENSO_SWAP_MODULE_ADMIN_ROLE(), moduleAdmin);
        vm.stopPrank();

        bytes[] memory setupData = new bytes[](1);
        _configureModules(mods, shouldWhitelist, setupData);

        deal(address(usdc), address(safe), SRC_AMOUNT);
    }

    // ---- Admin setter ----

    function test_setEnsoRouter_revertsForNonAdmin() public {
        vm.expectRevert(EnsoSwapModule.OnlyAdmin.selector);
        module.setEnsoRouter(address(ensoRouter));
    }

    function test_setEnsoRouter_revertsForZero() public {
        vm.prank(moduleAdmin);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        module.setEnsoRouter(address(0));
    }

    function test_setEnsoRouter_storesAndEmits() public {
        address newAddr = makeAddr("newEnsoRouter");
        vm.expectEmit(false, false, false, true, address(module));
        emit EnsoSwapModule.EnsoRouterSet(address(ensoRouter), newAddr);
        vm.prank(moduleAdmin);
        module.setEnsoRouter(newAddr);
        assertEq(module.getEnsoRouter(), newAddr);
    }

    function test_initialize_revertsOnZeroConfig() public {
        address impl = address(new EnsoSwapModule(address(dataProvider)));
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        new UUPSProxy(impl, abi.encodeWithSelector(
            EnsoSwapModule.initialize.selector,
            address(roleRegistry), address(0)
        ));
    }

    // ---- requestSwap ----

    function test_requestSwap_storesSwapAndPlacesHold() public {
        EnsoSwapModule.Order memory order = _baseOrder();
        bytes memory swapData = _swapData(SRC_AMOUNT);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order, swapData);
        module.requestSwap(address(safe), order, swapData, signers, sigs);

        assertEq(module.getOrder(address(safe)).srcAmount, SRC_AMOUNT);
        // The Enso calldata is captured at request for executeSwap to replay verbatim.
        assertEq(module.getSwap(address(safe)).swapData, swapData);
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient, address(module));
    }

    function test_requestSwap_revertsOnEmptySwapData() public {
        EnsoSwapModule.Order memory order = _baseOrder();
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order, "");
        vm.expectRevert(EnsoSwapModule.EmptySwapData.selector);
        module.requestSwap(address(safe), order, "", signers, sigs);
    }

    function test_requestSwap_revertsOnInvalidInput() public {
        EnsoSwapModule.Order memory order = _baseOrder();
        order.srcAmount = 0;
        bytes memory swapData = _swapData(SRC_AMOUNT);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order, swapData);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        module.requestSwap(address(safe), order, swapData, signers, sigs);
    }

    function test_requestSwap_revertsForExpiredDeadline() public {
        EnsoSwapModule.Order memory order = _baseOrder();
        order.deadline = block.timestamp;
        bytes memory swapData = _swapData(SRC_AMOUNT);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order, swapData);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        module.requestSwap(address(safe), order, swapData, signers, sigs);
    }

    function test_requestSwap_revertsForBadSignature() public {
        EnsoSwapModule.Order memory order = _baseOrder();
        EnsoSwapModule.Order memory tampered = _baseOrder();
        tampered.srcAmount = SRC_AMOUNT + 1;
        bytes memory swapData = _swapData(SRC_AMOUNT);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(tampered, swapData);
        vm.expectRevert(EnsoSwapModule.InvalidSignatures.selector);
        module.requestSwap(address(safe), order, swapData, signers, sigs);
    }

    function test_requestSwap_revertsWhenOrderAlreadyActive() public {
        EnsoSwapModule.Order memory order = _baseOrder();
        _request(order);

        bytes memory swapData = _swapData(SRC_AMOUNT);
        (address[] memory s2, bytes[] memory si2) = _signRequest(order, swapData);
        vm.expectRevert(EnsoSwapModule.OrderAlreadyActive.selector);
        module.requestSwap(address(safe), order, swapData, s2, si2);
    }

    // ---- executeSwap ----

    function test_executeSwap_dispatchesApproveCallReset() public {
        EnsoSwapModule.Order memory order = _baseOrder();
        _request(order);
        _warpPastDelay();

        _executeAsKeeper();

        assertEq(ensoRouter.callCount(), 1);
        assertEq(ensoRouter.pulled(), SRC_AMOUNT);
        assertEq(ensoRouter.lastCaller(), address(safe));
        assertEq(module.getOrder(address(safe)).srcToken, address(0));
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient, address(0));
        // Approval is reset to zero after forwarding the swap.
        assertEq(usdc.allowance(address(safe), address(ensoRouter)), 0);
    }

    function test_executeSwap_sameChainEnforcesRecipientTokenAndMinOut() public {
        MockERC20 dstToken = new MockERC20("Output", "OUT", 18);
        uint256 outputAmount = MIN_OUT + 1;
        dstToken.mint(address(ensoRouter), outputAmount);

        EnsoSwapModule.Order memory order = _baseOrder();
        order.dstChainId = block.chainid;
        order.dstToken = address(dstToken);
        bytes memory swapData = abi.encodeCall(
            EnsoRouterStub.swapTo,
            (address(usdc), SRC_AMOUNT, address(dstToken), recipient, outputAmount)
        );
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order, swapData);
        module.requestSwap(address(safe), order, swapData, signers, sigs);
        _warpPastDelay();

        _executeAsKeeper();

        assertEq(dstToken.balanceOf(recipient), outputAmount);
    }

    function test_executeSwap_sameChainRevertsWhenOutputBelowMinOut() public {
        MockERC20 dstToken = new MockERC20("Output", "OUT", 18);
        uint256 outputAmount = MIN_OUT - 1;
        dstToken.mint(address(ensoRouter), outputAmount);

        EnsoSwapModule.Order memory order = _baseOrder();
        order.dstChainId = block.chainid;
        order.dstToken = address(dstToken);
        bytes memory swapData = abi.encodeCall(
            EnsoRouterStub.swapTo,
            (address(usdc), SRC_AMOUNT, address(dstToken), recipient, outputAmount)
        );
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order, swapData);
        module.requestSwap(address(safe), order, swapData, signers, sigs);
        _warpPastDelay();

        vm.prank(keeper);
        vm.expectRevert(EnsoSwapModule.InsufficientOutputAmount.selector);
        module.executeSwap(address(safe));

        assertEq(module.getOrder(address(safe)).srcToken, address(usdc), "order should remain active");
        assertEq(dstToken.balanceOf(recipient), 0, "router execution should roll back");
    }

    function test_executeSwap_sameChainRevertsWhenRouterPaysDifferentRecipient() public {
        MockERC20 dstToken = new MockERC20("Output", "OUT", 18);
        address wrongRecipient = makeAddr("wrongRecipient");
        dstToken.mint(address(ensoRouter), MIN_OUT);

        EnsoSwapModule.Order memory order = _baseOrder();
        order.dstChainId = block.chainid;
        order.dstToken = address(dstToken);
        bytes memory swapData = abi.encodeCall(
            EnsoRouterStub.swapTo,
            (address(usdc), SRC_AMOUNT, address(dstToken), wrongRecipient, MIN_OUT)
        );
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order, swapData);
        module.requestSwap(address(safe), order, swapData, signers, sigs);
        _warpPastDelay();

        vm.prank(keeper);
        vm.expectRevert(EnsoSwapModule.InsufficientOutputAmount.selector);
        module.executeSwap(address(safe));

        assertEq(dstToken.balanceOf(wrongRecipient), 0, "wrong-recipient transfer should roll back");
    }

    function test_executeSwap_sameChainEnforcesNativeOutput() public {
        deal(address(ensoRouter), MIN_OUT);

        EnsoSwapModule.Order memory order = _baseOrder();
        order.dstChainId = block.chainid;
        order.dstToken = NATIVE_TOKEN;
        bytes memory swapData = abi.encodeCall(
            EnsoRouterStub.swapToNative,
            (address(usdc), SRC_AMOUNT, payable(recipient), MIN_OUT)
        );
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order, swapData);
        module.requestSwap(address(safe), order, swapData, signers, sigs);
        _warpPastDelay();

        _executeAsKeeper();

        assertEq(recipient.balance, MIN_OUT);
    }

    function test_executeSwap_permissionless_anyCallerCanExecute() public {
        _request(_baseOrder());
        _warpPastDelay();

        // No role required: an arbitrary caller can execute the user-signed stored swap.
        vm.prank(makeAddr("randomCaller"));
        module.executeSwap(address(safe));

        assertEq(ensoRouter.callCount(), 1);
        assertEq(module.getOrder(address(safe)).srcToken, address(0), "order not cleared");
    }

    function test_executeSwap_revertsForNoActiveOrder() public {
        _expectExecuteRevert(EnsoSwapModule.NoActiveOrder.selector, keeper);
    }

    function test_executeSwap_revertsAfterDeadline() public {
        EnsoSwapModule.Order memory order = _baseOrder();
        _request(order);
        vm.warp(order.deadline + 1);
        _expectExecuteRevert(EnsoSwapModule.OrderExpired.selector, keeper);
    }

    function test_executeSwap_revertsBeforeWithdrawalDelayMatures() public {
        _request(_baseOrder());
        _expectExecuteRevert(EnsoSwapModule.WithdrawalDelayNotElapsed.selector, keeper);
    }

    // ---- cancelSwap ----

    function test_cancelSwap_clearsOrderAndHold() public {
        _request(_baseOrder());

        (address[] memory signers, bytes[] memory sigs) = _signCancel();
        // Match the safe topic only; swapId is asserted in the dedicated linking tests.
        vm.expectEmit(true, false, false, false);
        emit EnsoSwapModule.SwapCancelled(address(safe), bytes32(0));
        module.cancelSwap(address(safe), signers, sigs);

        assertEq(module.getOrder(address(safe)).srcToken, address(0));
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient, address(0));
    }

    function test_cancelSwap_revertsForNoActiveOrder() public {
        (address[] memory signers, bytes[] memory sigs) = _signCancel();
        vm.expectRevert(EnsoSwapModule.NoActiveOrder.selector);
        module.cancelSwap(address(safe), signers, sigs);
    }

    function test_cancelSwap_revertsForBadSig() public {
        _request(_baseOrder());

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;
        bytes[] memory sigs = new bytes[](2);
        bytes32 baddigest = keccak256("not the right digest").toEthSignedMessageHash();
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, baddigest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, baddigest);
        sigs[0] = abi.encodePacked(r1, s1, v1);
        sigs[1] = abi.encodePacked(r2, s2, v2);

        vm.expectRevert(EnsoSwapModule.InvalidSignatures.selector);
        module.cancelSwap(address(safe), signers, sigs);
    }

    // ---- cancelExpiredSwap ----

    function test_cancelExpiredSwap_clearsOrderAndHold_permissionlessAfterDeadline() public {
        EnsoSwapModule.Order memory order = _baseOrder();
        _request(order);
        vm.warp(order.deadline + 1);

        // No signature and no role: any caller can clean up an expired order.
        vm.expectEmit(true, false, false, false);
        emit EnsoSwapModule.SwapCancelled(address(safe), bytes32(0));
        vm.prank(makeAddr("randomCaller"));
        module.cancelExpiredSwap(address(safe));

        assertEq(module.getOrder(address(safe)).srcToken, address(0), "order not cleared");
        assertEq(
            cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient,
            address(0),
            "hold not cleared"
        );
    }

    function test_cancelExpiredSwap_revertsForNoActiveOrder() public {
        vm.expectRevert(EnsoSwapModule.NoActiveOrder.selector);
        module.cancelExpiredSwap(address(safe));
    }

    function test_cancelExpiredSwap_revertsBeforeDeadline() public {
        EnsoSwapModule.Order memory order = _baseOrder();
        _request(order);

        // At the deadline (inclusive) it is not yet expired.
        vm.warp(order.deadline);
        vm.expectRevert(EnsoSwapModule.OrderNotExpired.selector);
        module.cancelExpiredSwap(address(safe));
    }

    // ---- swapId linking ----

    /// @dev The swapId committed at request time is `keccak256(chainid, module, safe, nonce, order)`.
    function _expectedSwapId(EnsoSwapModule.Order memory order, uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(module), address(safe), nonce, order));
    }

    /// @dev Pull the `swapId` topic (topic[2]) of the first recorded log matching `sig`.
    ///      Event topic layout is `[sig, safe, swapId]` for all three lifecycle events.
    function _swapIdFromLogs(bytes32 sig) internal returns (bytes32) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 3 && logs[i].topics[0] == sig) return logs[i].topics[2];
        }
        revert("event not found");
    }

    function test_requestSwap_storesAndEmitsSwapId() public {
        EnsoSwapModule.Order memory order = _baseOrder();
        bytes32 expected = _expectedSwapId(order, safe.nonce());

        vm.recordLogs();
        _request(order);

        assertEq(module.getSwap(address(safe)).swapId, expected, "stored swapId");
        assertEq(_swapIdFromLogs(EnsoSwapModule.SwapRequested.selector), expected, "emitted SwapRequested swapId");
    }

    function test_executeSwap_emitsSameSwapIdAsRequest() public {
        _request(_baseOrder());
        bytes32 stored = module.getSwap(address(safe)).swapId;
        _warpPastDelay();

        vm.recordLogs();
        _executeAsKeeper();

        assertEq(_swapIdFromLogs(EnsoSwapModule.SwapExecuted.selector), stored, "execute swapId links to request");
    }

    function test_cancelSwap_emitsSameSwapIdAsRequest() public {
        _request(_baseOrder());
        bytes32 stored = module.getSwap(address(safe)).swapId;

        (address[] memory signers, bytes[] memory sigs) = _signCancel();
        vm.recordLogs();
        module.cancelSwap(address(safe), signers, sigs);

        assertEq(_swapIdFromLogs(EnsoSwapModule.SwapCancelled.selector), stored, "cancel swapId links to request");
    }

    function test_cancelBridgeByCashModule_emitsSameSwapIdAsRequest() public {
        _request(_baseOrder());
        bytes32 stored = module.getSwap(address(safe)).swapId;

        vm.recordLogs();
        vm.prank(address(cashModule));
        module.cancelBridgeByCashModule(address(safe));

        assertEq(_swapIdFromLogs(EnsoSwapModule.SwapCancelled.selector), stored, "cancelBridge swapId links to request");
    }

    /// @dev Two sequential swaps for the same safe must get distinct ids (the nonce advances).
    function test_swapId_distinctAcrossSequentialSwaps() public {
        bytes32 firstId = _firstSwapIdThenCancel();
        bytes32 secondId = _firstSwapIdThenCancel();
        assertTrue(firstId != bytes32(0), "first id set");
        assertTrue(firstId != secondId, "sequential swaps get distinct ids");
    }

    function _firstSwapIdThenCancel() internal returns (bytes32 id) {
        _request(_baseOrder());
        id = module.getSwap(address(safe)).swapId;
        (address[] memory signers, bytes[] memory sigs) = _signCancel();
        module.cancelSwap(address(safe), signers, sigs);
    }

    // ---- cancelBridgeByCashModule ----

    function test_cancelBridgeByCashModule_clearsOrderOnly() public {
        _request(_baseOrder());

        vm.prank(address(cashModule));
        module.cancelBridgeByCashModule(address(safe));

        assertEq(module.getOrder(address(safe)).srcToken, address(0));
    }

    function test_cancelBridgeByCashModule_revertsForNonCashModule() public {
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        module.cancelBridgeByCashModule(address(safe));
    }

    // ---- Helpers ----

    function _baseOrder() internal returns (EnsoSwapModule.Order memory) {
        return EnsoSwapModule.Order({
            srcToken: address(usdc),
            srcAmount: SRC_AMOUNT,
            dstChainId: DST_CHAIN,
            dstToken: makeAddr("dstToken"),
            recipient: recipient,
            minOut: MIN_OUT,
            deadline: block.timestamp + 1 hours
        });
    }

    /// @dev Enso calldata the mock router understands: pull `amount` of usdc from the safe.
    function _swapData(uint256 amount) internal view returns (bytes memory) {
        return abi.encodeWithSelector(EnsoRouterStub.swap.selector, address(usdc), amount);
    }

    function _signRequest(EnsoSwapModule.Order memory order, bytes memory swapData)
        internal view returns (address[] memory, bytes[] memory)
    {
        bytes32 digest = keccak256(abi.encodePacked(
            keccak256("EnsoSwapModule.requestSwap"),
            block.chainid,
            address(module),
            safe.nonce(),
            address(safe),
            abi.encode(order),
            keccak256(swapData)
        )).toEthSignedMessageHash();
        return _twoSig(digest);
    }

    function _signCancel() internal view returns (address[] memory, bytes[] memory) {
        bytes32 digest = keccak256(abi.encodePacked(
            keccak256("EnsoSwapModule.cancelSwap"),
            block.chainid,
            address(module),
            safe.nonce(),
            address(safe)
        )).toEthSignedMessageHash();
        return _twoSig(digest);
    }

    function _twoSig(bytes32 digest) internal view returns (address[] memory, bytes[] memory) {
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;
        bytes[] memory sigs = new bytes[](2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digest);
        sigs[0] = abi.encodePacked(r1, s1, v1);
        sigs[1] = abi.encodePacked(r2, s2, v2);
        return (signers, sigs);
    }

    function _request(EnsoSwapModule.Order memory order) internal {
        bytes memory swapData = _swapData(SRC_AMOUNT);
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order, swapData);
        module.requestSwap(address(safe), order, swapData, signers, sigs);
    }

    function _warpPastDelay() internal {
        (uint64 withdrawalDelay, , ) = cashModule.getDelays();
        vm.warp(block.timestamp + withdrawalDelay + 1);
    }

    function _executeAsKeeper() internal {
        vm.prank(keeper);
        module.executeSwap(address(safe));
    }

    function _expectExecuteRevert(bytes4 selector, address caller) internal {
        vm.prank(caller);
        vm.expectRevert(selector);
        module.executeSwap(address(safe));
    }
}
