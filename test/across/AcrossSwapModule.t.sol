// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { AcrossSwapModule } from "../../src/across/AcrossSwapModule.sol";
import { ModuleBase } from "../../src/modules/ModuleBase.sol";
import { UpgradeableProxy } from "../../src/utils/UpgradeableProxy.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { SafeTestSetup } from "../safe/SafeTestSetup.t.sol";

/// @dev Stub that captures the last `depositV3` call. We use `fallback` instead of an
///      explicit `depositV3` function because the legacy codegen can't generate the
///      calldata-decoding entry code for a 12-arg signature with a dynamic `bytes`
///      parameter.
contract SpokePoolStub {
    bytes public lastCalldata;
    uint256 public callCount;

    fallback() external payable {
        lastCalldata = msg.data;
        callCount++;
    }

    receive() external payable {}
}

/// @dev Router stub for the sell swap leg: records the call and pays out a configured
///      amount of a token to a recipient — simulating the swap output landing at the
///      safe, which the module's delta check measures.
interface IMintable {
    function transfer(address, uint256) external returns (bool);
}

contract RouterStub {
    bytes public lastCalldata;
    uint256 public callCount;
    address public payToken;
    address public payTo;
    uint256 public payAmount;

    function configurePayout(address token, address to, uint256 amount) external {
        payToken = token;
        payTo = to;
        payAmount = amount;
    }

    fallback() external payable {
        lastCalldata = msg.data;
        callCount++;
        if (payAmount > 0) IMintable(payToken).transfer(payTo, payAmount);
    }

    receive() external payable {}
}

contract AcrossSwapModuleTest is SafeTestSetup {
    using MessageHashUtils for bytes32;

    AcrossSwapModule internal module;
    SpokePoolStub internal spokePool;
    address internal multicallHandler = makeAddr("multicallHandler");
    address internal keeper = makeAddr("keeper");
    address internal moduleAdmin = makeAddr("moduleAdmin");
    address internal recipient = makeAddr("recipient");

    uint256 internal constant DST_CHAIN = 1;
    uint256 internal constant SRC_AMOUNT = 1_000e6;
    uint256 internal constant MIN_OUT = 990_000_000_000_000;

    /// @dev Opaque BE-supplied MulticallHandler `message`. Module forwards verbatim; the
    ///      one happy-path test checks the bytes flow through unmodified.
    bytes internal constant FAKE_MESSAGE = hex"cafebabe";

    function setUp() public override {
        super.setUp();

        spokePool = new SpokePoolStub();
        address moduleImpl = address(new AcrossSwapModule(address(dataProvider)));
        module = AcrossSwapModule(address(new UUPSProxy(
            moduleImpl,
            abi.encodeWithSelector(
                AcrossSwapModule.initialize.selector,
                address(roleRegistry),
                address(spokePool),
                multicallHandler,
                topUpFactoryAddr
            )
        )));

        address[] memory mods = new address[](1);
        mods[0] = address(module);
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.startPrank(owner);
        dataProvider.configureModules(mods, shouldWhitelist);
        cashModule.configureModulesCanRequestWithdraw(mods, shouldWhitelist);

        roleRegistry.grantRole(module.ACROSS_SWAP_MODULE_ADMIN_ROLE(), moduleAdmin);
        roleRegistry.grantRole(module.ACROSS_SWAP_MODULE_KEEPER_ROLE(), keeper);
        vm.stopPrank();

        bytes[] memory setupData = new bytes[](1);
        _configureModules(mods, shouldWhitelist, setupData);

        deal(address(usdc), address(safe), SRC_AMOUNT);
    }

    // ---- Admin setters ----

    function test_setSpokePool_revertsForNonAdmin() public {
        vm.expectRevert(AcrossSwapModule.OnlyAdmin.selector);
        module.setSpokePool(address(spokePool));
    }

    function test_setSpokePool_revertsForZero() public {
        vm.prank(moduleAdmin);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        module.setSpokePool(address(0));
    }

    function test_setMulticallHandler_revertsForZero() public {
        vm.prank(moduleAdmin);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        module.setMulticallHandler(address(0));
    }

    function test_setSpokePool_storesAndEmits() public {
        address newAddr = makeAddr("newSpokePool");
        vm.expectEmit(false, false, false, true, address(module));
        emit AcrossSwapModule.SpokePoolSet(address(spokePool), newAddr);
        vm.prank(moduleAdmin);
        module.setSpokePool(newAddr);
        assertEq(module.getSpokePool(), newAddr);
    }

    function test_initialize_revertsOnZeroConfig() public {
        address impl = address(new AcrossSwapModule(address(dataProvider)));
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        new UUPSProxy(impl, abi.encodeWithSelector(
            AcrossSwapModule.initialize.selector,
            address(roleRegistry), address(0), multicallHandler, topUpFactoryAddr
        ));
    }

    // ---- requestSwap ----

    function test_requestSwap_storesOrderAndPlacesHold() public {
        AcrossSwapModule.Order memory order = _baseOrder();
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order);
        module.requestSwap(address(safe), order, signers, sigs);

        assertEq(module.getOrder(address(safe)).srcAmount, SRC_AMOUNT);
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient, address(module));
    }

    function test_requestSwap_revertsOnInvalidInput() public {
        AcrossSwapModule.Order memory order = _baseOrder();
        order.srcAmount = 0;
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        module.requestSwap(address(safe), order, signers, sigs);
    }

    function test_requestSwap_revertsForExpiredDeadline() public {
        AcrossSwapModule.Order memory order = _baseOrder();
        order.deadline = block.timestamp;
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        module.requestSwap(address(safe), order, signers, sigs);
    }

    function test_requestSwap_revertsForBadSignature() public {
        AcrossSwapModule.Order memory order = _baseOrder();
        AcrossSwapModule.Order memory tampered = _baseOrder();
        tampered.srcAmount = SRC_AMOUNT + 1;
        (address[] memory signers, bytes[] memory sigs) = _signRequest(tampered);
        vm.expectRevert(AcrossSwapModule.InvalidSignatures.selector);
        module.requestSwap(address(safe), order, signers, sigs);
    }

    function test_requestSwap_revertsWhenOrderAlreadyActive() public {
        AcrossSwapModule.Order memory order = _baseOrder();
        (address[] memory s1, bytes[] memory si1) = _signRequest(order);
        module.requestSwap(address(safe), order, s1, si1);

        (address[] memory s2, bytes[] memory si2) = _signRequest(order);
        vm.expectRevert(AcrossSwapModule.OrderAlreadyActive.selector);
        module.requestSwap(address(safe), order, s2, si2);
    }

    // ---- executeSwap ----

    function test_executeSwap_dispatchesApproveAndDepositV3() public {
        AcrossSwapModule.Order memory order = _baseOrder();
        _request(order);
        _warpPastDelay();

        _executeAsKeeper(MIN_OUT);

        assertEq(spokePool.callCount(), 1);
        assertEq(module.getOrder(address(safe)).srcToken, address(0));
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient, address(0));
        assertEq(usdc.allowance(address(safe), address(spokePool)), SRC_AMOUNT);
        _checkDepositV3Args(order);
    }

    function test_executeSwap_revertsForNonKeeper() public {
        _request(_baseOrder());
        _warpPastDelay();
        _expectExecuteRevert(MIN_OUT, AcrossSwapModule.OnlyKeeper.selector, address(this));
    }

    function test_executeSwap_revertsForNoActiveOrder() public {
        _expectExecuteRevert(MIN_OUT, AcrossSwapModule.NoActiveOrder.selector, keeper);
    }

    function test_executeSwap_revertsAfterDeadline() public {
        AcrossSwapModule.Order memory order = _baseOrder();
        _request(order);
        vm.warp(order.deadline + 1);
        _expectExecuteRevert(MIN_OUT, AcrossSwapModule.OrderExpired.selector, keeper);
    }

    function test_executeSwap_revertsWhenOutputBelowMinOut() public {
        _request(_baseOrder());
        _warpPastDelay();
        _expectExecuteRevert(MIN_OUT - 1, AcrossSwapModule.InsufficientOutputAmount.selector, keeper);
    }


    function test_executeSell_settlesToTopUpWhenOutputSupported() public {
        RouterStub router = _fundedRouter(990e6);
        _setupSell(true);

        AcrossSwapModule.Order memory order = _sellOrder();
        AcrossSwapModule.SellArgs memory sellArgs = _sellArgs(address(router));
        (address[] memory signers, bytes[] memory sigs) = _signSell(order);

        // The emitted outAmount is the MEASURED delta the router delivered.
        vm.expectEmit(true, true, true, true);
        emit AcrossSwapModule.SellExecuted(address(safe), order.srcToken, order.dstToken, 990e6, topUpAddr);
        vm.prank(keeper);
        module.executeSell(address(safe), order, sellArgs, signers, sigs);

        // Router leg ran with BE calldata; approval was reset after the swap.
        assertEq(router.callCount(), 1);
        assertEq(router.lastCalldata(), hex"beefbeef");
        assertEq(weETH.allowance(address(safe), address(router)), 0, "router approval must be reset");

        // Settlement leg: the full measured delta pushed to the factory-recorded TopUp.
        // The safe's PRE-EXISTING USDC (dealt in setUp) is untouched — only the swap
        // output settles.
        assertEq(usdc.balanceOf(topUpAddr), 990e6);
        assertEq(usdc.balanceOf(address(safe)), SRC_AMOUNT);
    }

    function test_executeSell_keepsOutputInSafeWhenNotSupported() public {
        RouterStub router = _fundedRouter(990e6);
        _setupSell(false); // output NOT topup-supported

        AcrossSwapModule.Order memory order = _sellOrder();
        AcrossSwapModule.SellArgs memory sellArgs = _sellArgs(address(router));
        (address[] memory signers, bytes[] memory sigs) = _signSell(order);

        vm.expectEmit(true, true, true, true);
        emit AcrossSwapModule.SellExecuted(address(safe), order.srcToken, order.dstToken, 990e6, address(safe));
        vm.prank(keeper);
        module.executeSell(address(safe), order, sellArgs, signers, sigs);

        // No settlement transfer: measured output stays in the TradingSafe as a holding
        // (on top of the pre-existing balance dealt in setUp).
        assertEq(usdc.balanceOf(topUpAddr), 0);
        assertEq(usdc.balanceOf(address(safe)), SRC_AMOUNT + 990e6);
    }

    function test_executeSell_revertsWhenRouteDeliversBelowMinOut() public {
        // The on-chain delta check: router delivers less than the signed minOut — the
        // whole sell reverts regardless of any BE claim.
        RouterStub router = _fundedRouter(_sellOrder().minOut - 1);
        _setupSell(true);

        AcrossSwapModule.Order memory order = _sellOrder();
        (address[] memory signers, bytes[] memory sigs) = _signSell(order);
        vm.prank(keeper);
        vm.expectRevert(AcrossSwapModule.InsufficientOutputAmount.selector);
        module.executeSell(address(safe), order, _sellArgs(address(router)), signers, sigs);
    }

    function test_executeSell_revertsWhenRouteDeliversNothing() public {
        // The previously-dangerous path: a malicious route takes the asset and delivers
        // zero output. The delta check makes this revert atomically.
        RouterStub router = new RouterStub(); // no payout configured
        _setupSell(false);

        AcrossSwapModule.Order memory order = _sellOrder();
        (address[] memory signers, bytes[] memory sigs) = _signSell(order);
        vm.prank(keeper);
        vm.expectRevert(AcrossSwapModule.InsufficientOutputAmount.selector);
        module.executeSell(address(safe), order, _sellArgs(address(router)), signers, sigs);
    }

    function test_executeSell_anyCallerCanExecute() public {
        // Permissionless: the user signature is the authorisation; the delta check +
        // factory-recorded destination bound what any caller can do.
        RouterStub router = _fundedRouter(990e6);
        _setupSell(true);

        AcrossSwapModule.Order memory order = _sellOrder();
        (address[] memory signers, bytes[] memory sigs) = _signSell(order);

        vm.prank(makeAddr("stranger"));
        module.executeSell(address(safe), order, _sellArgs(address(router)), signers, sigs);

        assertEq(usdc.balanceOf(topUpAddr), 990e6);
    }

    function test_executeSell_revertsWhenFactoryHasNoTopUpRecord() public {
        RouterStub router = _fundedRouter(990e6);
        _setupSell(true);
        AcrossSwapModule.Order memory order = _sellOrder();
        // Factory reverts for safes it didn't deploy — the lookup propagates the revert,
        // so a sell can never settle to an unrecorded destination.
        vm.mockCallRevert(
            address(safeFactory),
            abi.encodeWithSignature("getTopUpAddress(address)", address(safe)),
            abi.encodeWithSignature("InvalidTradingSafe()")
        );
        (address[] memory signers, bytes[] memory sigs) = _signSell(order);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSignature("InvalidTradingSafe()"));
        module.executeSell(address(safe), order, _sellArgs(address(router)), signers, sigs);
    }

    function test_executeSell_revertsAfterDeadline() public {
        _setupSell(true);
        AcrossSwapModule.Order memory order = _sellOrder();
        (address[] memory signers, bytes[] memory sigs) = _signSell(order);
        vm.warp(order.deadline + 1);
        vm.prank(keeper);
        vm.expectRevert(AcrossSwapModule.OrderExpired.selector);
        module.executeSell(address(safe), order, _sellArgs(makeAddr("router")), signers, sigs);
    }

    function test_executeSell_consumesNonce_replayFails() public {
        RouterStub router = _fundedRouter(990e6);
        _setupSell(true);

        AcrossSwapModule.Order memory order = _sellOrder();
        AcrossSwapModule.SellArgs memory sellArgs = _sellArgs(address(router));
        (address[] memory signers, bytes[] memory sigs) = _signSell(order);

        vm.prank(keeper);
        module.executeSell(address(safe), order, sellArgs, signers, sigs);

        // Same signed payload again: nonce moved, signature no longer valid.
        router.configurePayout(address(usdc), address(safe), 990e6);
        deal(address(usdc), address(router), 990e6);
        vm.prank(keeper);
        vm.expectRevert(AcrossSwapModule.InvalidSignatures.selector);
        module.executeSell(address(safe), order, sellArgs, signers, sigs);
    }

    // ---- sell helpers ----

    address internal topUpAddr = makeAddr("topUpAddr");
    address internal topUpFactoryAddr = makeAddr("topUpFactory");

    /// @dev Configures the sell surface: topUpFactory set + `isTokenSupported(usdc)`
    ///      mocked to `supported`, and the factory's deploy-time TopUp record mocked so
    ///      this safe settles to `topUpAddr` (in prod the TradingSafeFactory records this
    ///      at deploy; the test safe factory is the OP-style EtherFiSafeFactory).
    function _setupSell(bool supported) internal {
        vm.mockCall(
            topUpFactoryAddr,
            abi.encodeWithSignature("isTokenSupported(address)", address(usdc)),
            abi.encode(supported)
        );
        vm.mockCall(
            address(safeFactory),
            abi.encodeWithSignature("getTopUpAddress(address)", address(safe)),
            abi.encode(topUpAddr)
        );
    }

    /// @dev Sell weETH -> USDC locally on this chain.
    function _sellOrder() internal view returns (AcrossSwapModule.Order memory) {
        return AcrossSwapModule.Order({
            srcToken: address(weETH),
            srcAmount: 1e18,
            dstChainId: block.chainid,
            dstToken: address(usdc),
            recipient: topUpAddr,
            minOut: 980e6,
            deadline: block.timestamp + 1 hours
        });
    }

    function _sellArgs(address router) internal pure returns (AcrossSwapModule.SellArgs memory) {
        return AcrossSwapModule.SellArgs({
            router: router,
            routerCallData: hex"beefbeef"
        });
    }

    /// @dev Router stub funded + configured to deliver `payout` USDC to the safe when
    ///      called — what the module's delta check measures.
    function _fundedRouter(uint256 payout) internal returns (RouterStub router) {
        router = new RouterStub();
        if (payout > 0) {
            deal(address(usdc), address(router), payout);
            router.configurePayout(address(usdc), address(safe), payout);
        }
    }

    function _signSell(AcrossSwapModule.Order memory order) internal view returns (address[] memory, bytes[] memory) {
        bytes32 digest = keccak256(abi.encodePacked(
            keccak256("AcrossSwapModule.executeSell"),
            block.chainid,
            address(module),
            safe.nonce(),
            address(safe),
            abi.encode(order)
        )).toEthSignedMessageHash();
        return _twoSig(digest);
    }

    // ---- cancelSwap ----

    function test_cancelSwap_clearsOrderAndHold() public {
        _request(_baseOrder());

        (address[] memory signers, bytes[] memory sigs) = _signCancel();
        vm.expectEmit(true, false, false, false);
        emit AcrossSwapModule.SwapCancelled(address(safe));
        module.cancelSwap(address(safe), signers, sigs);

        assertEq(module.getOrder(address(safe)).srcToken, address(0));
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient, address(0));
    }

    function test_cancelSwap_revertsForNoActiveOrder() public {
        (address[] memory signers, bytes[] memory sigs) = _signCancel();
        vm.expectRevert(AcrossSwapModule.NoActiveOrder.selector);
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

        vm.expectRevert(AcrossSwapModule.InvalidSignatures.selector);
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

    function _baseOrder() internal returns (AcrossSwapModule.Order memory) {
        return AcrossSwapModule.Order({
            srcToken: address(usdc),
            srcAmount: SRC_AMOUNT,
            dstChainId: DST_CHAIN,
            dstToken: makeAddr("dstToken"),
            recipient: recipient,
            minOut: MIN_OUT,
            deadline: block.timestamp + 1 hours
        });
    }

    function _baseDepositArgs(uint256 outputAmount) internal view returns (AcrossSwapModule.DepositArgs memory) {
        return AcrossSwapModule.DepositArgs({
            outputAmount: outputAmount,
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 30 minutes),
            exclusivityDeadline: 0,
            exclusiveRelayer: address(0)
        });
    }

    function _signRequest(AcrossSwapModule.Order memory order) internal view returns (address[] memory, bytes[] memory) {
        bytes32 digest = keccak256(abi.encodePacked(
            keccak256("AcrossSwapModule.requestSwap"),
            block.chainid,
            address(module),
            safe.nonce(),
            address(safe),
            abi.encode(order)
        )).toEthSignedMessageHash();
        return _twoSig(digest);
    }

    function _signCancel() internal view returns (address[] memory, bytes[] memory) {
        bytes32 digest = keccak256(abi.encodePacked(
            keccak256("AcrossSwapModule.cancelSwap"),
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

    function _request(AcrossSwapModule.Order memory order) internal {
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order);
        module.requestSwap(address(safe), order, signers, sigs);
    }

    function _warpPastDelay() internal {
        (uint64 withdrawalDelay, , ) = cashModule.getDelays();
        vm.warp(block.timestamp + withdrawalDelay + 1);
    }

    function _executeAsKeeper(uint256 outputAmount) internal {
        AcrossSwapModule.DepositArgs memory args = _baseDepositArgs(outputAmount);
        vm.prank(keeper);
        module.executeSwap(address(safe), args, FAKE_MESSAGE);
    }

    function _expectExecuteRevert(uint256 outputAmount, bytes4 selector, address caller) internal {
        AcrossSwapModule.DepositArgs memory args = _baseDepositArgs(outputAmount);
        vm.prank(caller);
        vm.expectRevert(selector);
        module.executeSwap(address(safe), args, FAKE_MESSAGE);
    }

    /// @dev Pull each depositV3 arg out of the recorded calldata via word reads — avoids
    ///      a 12-tuple `abi.decode` that wouldn't fit the legacy stack budget.
    function _checkDepositV3Args(AcrossSwapModule.Order memory order) internal {
        bytes memory raw = spokePool.lastCalldata();
        assertEq(_readAddrAt(raw, 4 + 0 * 32), address(safe), "depositor should be safe");
        assertEq(_readAddrAt(raw, 4 + 1 * 32), multicallHandler, "recipient must be MulticallHandler");
        assertEq(_readAddrAt(raw, 4 + 2 * 32), order.srcToken, "inputToken");
        assertEq(_readAddrAt(raw, 4 + 3 * 32), order.dstToken, "outputToken");
        assertEq(_readUintAt(raw, 4 + 4 * 32), order.srcAmount, "inputAmount");
        assertGe(_readUintAt(raw, 4 + 5 * 32), order.minOut, "outputAmount >= minOut");
        assertEq(_readUintAt(raw, 4 + 6 * 32), order.dstChainId, "destinationChainId");
        _checkMessage(raw);
    }

    function _checkMessage(bytes memory raw) internal {
        uint256 msgOffset = _readUintAt(raw, 4 + 11 * 32);
        uint256 msgLen = _readUintAt(raw, 4 + msgOffset);
        bytes memory extracted = new bytes(msgLen);
        for (uint256 i = 0; i < msgLen; i++) extracted[i] = raw[4 + msgOffset + 32 + i];
        assertEq(extracted, FAKE_MESSAGE, "message must forward verbatim");
    }

    function _readAddrAt(bytes memory raw, uint256 offset) internal pure returns (address out) {
        assembly { out := mload(add(add(raw, 32), offset)) }
    }

    function _readUintAt(bytes memory raw, uint256 offset) internal pure returns (uint256 out) {
        assembly { out := mload(add(add(raw, 32), offset)) }
    }
}
