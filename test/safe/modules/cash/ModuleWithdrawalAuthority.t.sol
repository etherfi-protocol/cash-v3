// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BinSponsor, Cashback, ICashModule, WithdrawalRequest } from "../../../../src/interfaces/ICashModule.sol";
import { IBridgeModule } from "../../../../src/interfaces/IBridgeModule.sol";
import { CashModuleTestSetup, CashVerificationLib, MessageHashUtils } from "./CashModuleTestSetup.t.sol";

/// @dev A withdraw-requesting module whose cancelBridgeByCashModule can record, revert, burn all its gas, or
///      record after two fresh storage writes (about what an escrow module's record cleanup costs).
contract MockWithdrawModule is IBridgeModule {
    enum Callback {
        Record,
        Revert,
        BurnGas,
        Heavy
    }

    error CallbackReverted();

    ICashModule internal immutable cashModule;
    Callback public callbackMode;
    uint256 public callbackCount;
    mapping(uint256 => uint256) internal scratch;

    constructor(ICashModule _cashModule) {
        cashModule = _cashModule;
    }

    function setCallbackMode(Callback mode) external {
        callbackMode = mode;
    }

    function requestWithdrawal(address safe, address token, uint256 amount) external {
        cashModule.requestWithdrawalByModule(safe, token, amount);
    }

    function processWithdrawal(address safe) external {
        cashModule.processWithdrawal(safe);
    }

    function cancelWithdrawal(address safe) external {
        cashModule.cancelWithdrawalByModule(safe);
    }

    function cancelBridgeByCashModule(address) external {
        require(msg.sender == address(cashModule), "only CashModule");
        if (callbackMode == Callback.Revert) revert CallbackReverted();
        if (callbackMode == Callback.BurnGas) {
            while (true) { }
        }
        if (callbackMode == Callback.Heavy) {
            scratch[2 * callbackCount] = 1;
            scratch[2 * callbackCount + 1] = 1;
        }
        callbackCount++;
    }
}

/**
 * @title CashModuleModuleWithdrawalAuthorityTest
 * @notice A module keeps sole authority over its own pending withdrawal after governance removes it from
 *         CashModule's withdraw-requester list, the DataProvider whitelist, or both in either order. Removal
 *         only blocks new requests: nobody else can process the module's hold, the module can still process
 *         and cancel it, and the module still hears of cancels made elsewhere without being able to block them.
 */
contract CashModuleModuleWithdrawalAuthorityTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;

    enum Removal {
        RequesterListOnly,
        DataProviderOnly,
        RequesterListThenDataProvider,
        DataProviderThenRequesterList
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("etherfi.storage.CashModuleStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant CASH_MODULE_STORAGE_LOCATION = 0xe000c7adec5855bcf51f74b73aa86172d0a325bc54c3f73cb406d259df90ea00;
    /// @dev SafeCashConfig member slot and byte offset of withdrawalRequestedByModule (after usesLendGateway at offset 14)
    uint256 internal constant RECORD_SLOT = 17;
    uint256 internal constant RECORD_OFFSET = 15;

    uint256 internal constant HOLD = 150e6;

    MockWithdrawModule internal module;
    address internal rando = makeAddr("rando");

    function setUp() public override {
        super.setUp();

        module = new MockWithdrawModule(cashModule);
        _setDataProviderWhitelist(true);
        _setRequesterList(true);

        (, uint64 spendLimitDelay, uint64 modeDelay) = cashModule.getDelays();
        vm.prank(owner);
        cashModule.setDelays(1 hours, spendLimitDelay, modeDelay);

        deal(address(usdc), address(safe), 200e6);
    }

    // ---- processing ----

    function test_processWithdrawal_onlyModule_afterRemovalFromRequesterListOnly() public {
        _assertOnlyModuleCanProcess(Removal.RequesterListOnly);
    }

    function test_processWithdrawal_onlyModule_afterRemovalFromDataProviderOnly() public {
        _assertOnlyModuleCanProcess(Removal.DataProviderOnly);
    }

    function test_processWithdrawal_onlyModule_afterRemoval_requesterListFirst() public {
        _assertOnlyModuleCanProcess(Removal.RequesterListThenDataProvider);
    }

    function test_processWithdrawal_onlyModule_afterRemoval_dataProviderFirst() public {
        _assertOnlyModuleCanProcess(Removal.DataProviderThenRequesterList);
    }

    // ---- module cancel ----

    function test_cancelWithdrawalByModule_works_afterRemovalFromRequesterListOnly() public {
        _assertModuleCanCancel(Removal.RequesterListOnly);
    }

    function test_cancelWithdrawalByModule_works_afterRemovalFromDataProviderOnly() public {
        _assertModuleCanCancel(Removal.DataProviderOnly);
    }

    function test_cancelWithdrawalByModule_works_afterRemoval_requesterListFirst() public {
        _assertModuleCanCancel(Removal.RequesterListThenDataProvider);
    }

    function test_cancelWithdrawalByModule_works_afterRemoval_dataProviderFirst() public {
        _assertModuleCanCancel(Removal.DataProviderThenRequesterList);
    }

    function test_cancelWithdrawalByModule_otherModuleStillRejected_afterRemoval() public {
        module.requestWithdrawal(address(safe), address(usdc), HOLD);
        _remove(Removal.RequesterListThenDataProvider);

        vm.prank(rando);
        vm.expectRevert(ICashModule.OnlyModuleThatRequestedCanCancel.selector);
        cashModule.cancelWithdrawalByModule(address(safe));
    }

    // ---- owners ----

    function test_cancelWithdrawal_ownersStillRejected_afterRemoval_requesterListFirst() public {
        _assertOwnersCannotCancelDirectly(Removal.RequesterListThenDataProvider);
    }

    function test_cancelWithdrawal_ownersStillRejected_afterRemoval_dataProviderFirst() public {
        _assertOwnersCannotCancelDirectly(Removal.DataProviderThenRequesterList);
    }

    function test_ownerReplacementRequest_notifiesRemovedModule_requesterListFirst() public {
        _assertOwnerReplacementNotifiesModule(Removal.RequesterListThenDataProvider);
    }

    function test_ownerReplacementRequest_notifiesRemovedModule_dataProviderFirst() public {
        _assertOwnerReplacementNotifiesModule(Removal.DataProviderThenRequesterList);
    }

    // ---- new requests ----

    function test_requestWithdrawalByModule_blocked_afterRemovalFromRequesterList() public {
        _remove(Removal.RequesterListOnly);
        vm.expectRevert(ICashModule.OnlyWhitelistedModuleCanRequestWithdraw.selector);
        module.requestWithdrawal(address(safe), address(usdc), HOLD);
    }

    function test_requestWithdrawalByModule_blocked_afterRemovalFromDataProvider() public {
        _remove(Removal.DataProviderOnly);
        vm.expectRevert(ICashModule.ModuleNotWhitelistedOnDataProvider.selector);
        module.requestWithdrawal(address(safe), address(usdc), HOLD);
    }

    // ---- callback to a removed module ----

    function test_cardSpend_notifiesRemovedModule() public {
        module.requestWithdrawal(address(safe), address(usdc), HOLD);
        _remove(Removal.DataProviderThenRequesterList);

        // 100 spent against 200 loose with 150 reserved: the spend cancels the reservation
        _spendUsdc(100e6);

        assertEq(_pendingTokensLength(), 0);
        assertEq(module.callbackCount(), 1);
        assertFalse(_record());
    }

    function test_removedModule_revertingCallback_cannotBlockOwnerReplacement() public {
        module.requestWithdrawal(address(safe), address(usdc), HOLD);
        _remove(Removal.RequesterListThenDataProvider);
        module.setCallbackMode(MockWithdrawModule.Callback.Revert);

        _requestWithdrawal(_single(address(usdc)), _single(1e6), withdrawRecipient);

        WithdrawalRequest memory request = cashModule.getData(address(safe)).pendingWithdrawalRequest;
        assertEq(request.recipient, withdrawRecipient);
        assertFalse(_record());
    }

    function test_removedModule_revertingCallback_cannotBlockCardSpend() public {
        module.requestWithdrawal(address(safe), address(usdc), HOLD);
        _remove(Removal.RequesterListOnly);
        module.setCallbackMode(MockWithdrawModule.Callback.Revert);

        _spendUsdc(100e6);
        assertEq(_pendingTokensLength(), 0);
    }

    function test_removedModule_revertingCallback_cannotBlockPreLiquidate() public {
        module.requestWithdrawal(address(safe), address(usdc), HOLD);
        _remove(Removal.DataProviderOnly);
        module.setCallbackMode(MockWithdrawModule.Callback.Revert);

        vm.prank(address(debtManager));
        cashModule.preLiquidate(address(safe));
        assertEq(_pendingTokensLength(), 0);
    }

    function test_removedModule_gasBurningCallback_isCapped() public {
        module.requestWithdrawal(address(safe), address(usdc), HOLD);
        _remove(Removal.RequesterListThenDataProvider);
        module.setCallbackMode(MockWithdrawModule.Callback.BurnGas);

        uint256 gasBefore = gasleft();
        _requestWithdrawal(_single(address(usdc)), _single(1e6), withdrawRecipient);
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient, withdrawRecipient);
        assertLt(gasUsed, 1_000_000, "the removed module's callback burned more than its cap");
    }

    /// @dev EIP-150: whoever submits a cancel picks its gas limit, but cannot make the capped callback run out of
    ///      gas while the cancel itself succeeds. Finds a cheap successful gas limit for a relayed owner replacement
    ///      request, then sweeps every limit from far below it to 100k above it in 1k steps: each one that succeeds
    ///      must have delivered the callback. Past that range a successful call leaves the callback the full cap.
    function test_removedModuleCallback_notStarvableByOuterGasLimit() public {
        module.requestWithdrawal(address(safe), address(usdc), HOLD);
        _remove(Removal.RequesterListThenDataProvider);
        module.setCallbackMode(MockWithdrawModule.Callback.Heavy);

        bytes memory replacement = _signedReplacementCall(1e6);
        uint256 snapshot = vm.snapshotState();
        uint256 cheapest = _cheapestSuccess(replacement, snapshot);

        uint256 successes;
        for (uint256 gasLimit = 50_000; gasLimit <= cheapest + 100_000; gasLimit += 1_000) {
            if (_probeReplacement(replacement, gasLimit)) successes++;
            vm.revertToState(snapshot);
        }
        assertGt(successes, 0);
    }

    function test_whitelistedModule_revertingCallback_stillRevertsCancel() public {
        module.requestWithdrawal(address(safe), address(usdc), HOLD);
        module.setCallbackMode(MockWithdrawModule.Callback.Revert);

        vm.expectRevert(MockWithdrawModule.CallbackReverted.selector);
        module.cancelWithdrawal(address(safe));

        // Unchanged for a module on both whitelists: its revert reverts every cancel, as before
        vm.expectRevert(MockWithdrawModule.CallbackReverted.selector);
        _spendUsdc(100e6);
    }

    // ---- the per-request record ----

    function test_record_setByModuleRequest_clearedOnProcess() public {
        module.requestWithdrawal(address(safe), address(usdc), HOLD);
        assertTrue(_record());

        _warpPastDelay();
        module.processWithdrawal(address(safe));
        assertFalse(_record());
        assertEq(usdc.balanceOf(address(module)), HOLD);
    }

    function test_record_setByModuleRequest_clearedOnCancel() public {
        module.requestWithdrawal(address(safe), address(usdc), HOLD);
        assertTrue(_record());

        module.cancelWithdrawal(address(safe));
        assertFalse(_record());
        assertEq(module.callbackCount(), 1);
    }

    function test_record_clearedWhenZeroDelayProcessesInline() public {
        (, uint64 spendLimitDelay, uint64 modeDelay) = cashModule.getDelays();
        vm.prank(owner);
        cashModule.setDelays(0, spendLimitDelay, modeDelay);

        module.requestWithdrawal(address(safe), address(usdc), HOLD);
        assertEq(_pendingTokensLength(), 0);
        assertFalse(_record());
        assertEq(usdc.balanceOf(address(module)), HOLD);
    }

    /// @dev A module override of zero (global delay one hour) also processes inline: the record is written before
    ///      that processing and cleared by it
    function test_record_clearedWhenModuleOverrideOfZeroProcessesInline() public {
        vm.prank(owner);
        cashModule.configureModuleWithdrawalDelay(address(module), 0, true);

        module.requestWithdrawal(address(safe), address(usdc), HOLD);
        assertEq(_pendingTokensLength(), 0);
        assertFalse(_record());
        assertEq(usdc.balanceOf(address(module)), HOLD);
    }

    function test_record_notSetByOwnerRequest() public {
        _requestWithdrawal(_single(address(usdc)), _single(HOLD), withdrawRecipient);
        assertFalse(_record());

        // An owner request stays processable by anyone
        _warpPastDelay();
        vm.prank(rando);
        cashModule.processWithdrawal(address(safe));
        assertEq(usdc.balanceOf(withdrawRecipient), HOLD);
    }

    function test_record_packsIntoSafeCashConfigTailSlot() public {
        bytes32 slot = _recordSlot();
        uint256 before = uint256(vm.load(address(cashModule), slot));
        bool usesLendGateway = cashModule.usesLendGateway(address(safe));

        module.requestWithdrawal(address(safe), address(usdc), HOLD);
        uint256 word = uint256(vm.load(address(cashModule), slot));

        // Only the record's byte changed; the neighbouring usesLendGateway flag (offset 14) is intact
        assertEq(word ^ before, uint256(1) << (RECORD_OFFSET * 8));
        assertEq(cashModule.usesLendGateway(address(safe)), usesLendGateway);
    }

    /// @dev A request placed before the upgrade carries no record. It keeps today's rules: it is the module's
    ///      only while the module is on the requester list, so the "no live holds" check before removing a
    ///      module still applies until such requests have cleared.
    function test_requestWithoutRecord_followsCurrentRequesterListMembership() public {
        module.requestWithdrawal(address(safe), address(usdc), HOLD);
        _clearRecord();

        _warpPastDelay();
        vm.prank(rando);
        vm.expectRevert(ICashModule.OnlyModuleThatRequestedCanWithdraw.selector);
        cashModule.processWithdrawal(address(safe));

        _remove(Removal.RequesterListOnly);
        vm.prank(rando);
        cashModule.processWithdrawal(address(safe));
        assertEq(usdc.balanceOf(address(module)), HOLD);
    }

    function test_requestWithoutRecord_moduleCancelStillNeedsDataProvider() public {
        module.requestWithdrawal(address(safe), address(usdc), HOLD);
        _clearRecord();
        _remove(Removal.DataProviderOnly);

        vm.expectRevert(ICashModule.ModuleNotWhitelistedOnDataProvider.selector);
        module.cancelWithdrawal(address(safe));
    }

    // ---- shared assertions ----

    function _assertOnlyModuleCanProcess(Removal removal) internal {
        module.requestWithdrawal(address(safe), address(usdc), HOLD);
        _remove(removal);
        _warpPastDelay();

        vm.prank(rando);
        vm.expectRevert(ICashModule.OnlyModuleThatRequestedCanWithdraw.selector);
        cashModule.processWithdrawal(address(safe));
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdc)), HOLD, "hold still in place");

        module.processWithdrawal(address(safe));
        assertEq(usdc.balanceOf(address(module)), HOLD);
        assertEq(_pendingTokensLength(), 0);
        assertFalse(_record());
    }

    function _assertModuleCanCancel(Removal removal) internal {
        module.requestWithdrawal(address(safe), address(usdc), HOLD);
        _remove(removal);

        module.cancelWithdrawal(address(safe));
        assertEq(_pendingTokensLength(), 0);
        assertEq(module.callbackCount(), 1, "module heard of its own cancel");
        assertEq(usdc.balanceOf(address(safe)), 200e6);
        assertFalse(_record());
    }

    function _assertOwnersCannotCancelDirectly(Removal removal) internal {
        module.requestWithdrawal(address(safe), address(usdc), HOLD);
        _remove(removal);

        vm.expectRevert(ICashModule.InvalidWithdrawRequest.selector);
        cashModule.cancelWithdrawal(address(safe), new address[](0), new bytes[](0));
    }

    function _assertOwnerReplacementNotifiesModule(Removal removal) internal {
        module.requestWithdrawal(address(safe), address(usdc), HOLD);
        _remove(removal);

        _requestWithdrawal(_single(address(usdc)), _single(1e6), withdrawRecipient);

        assertEq(module.callbackCount(), 1);
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient, withdrawRecipient);
        assertFalse(_record());
    }

    // ---- helpers ----

    function _remove(Removal removal) internal {
        if (removal == Removal.RequesterListOnly) {
            _setRequesterList(false);
        } else if (removal == Removal.DataProviderOnly) {
            _setDataProviderWhitelist(false);
        } else if (removal == Removal.RequesterListThenDataProvider) {
            _setRequesterList(false);
            _setDataProviderWhitelist(false);
        } else {
            _setDataProviderWhitelist(false);
            _setRequesterList(false);
        }
    }

    function _setRequesterList(bool allowed) internal {
        vm.prank(owner);
        cashModule.configureModulesCanRequestWithdraw(_single(address(module)), _singleBool(allowed));
    }

    function _setDataProviderWhitelist(bool allowed) internal {
        vm.prank(owner);
        dataProvider.configureModules(_single(address(module)), _singleBool(allowed));
    }

    /// @dev Binary search for a gas limit at which `callData` succeeds; every probe checks the callback ran
    function _cheapestSuccess(bytes memory callData, uint256 snapshot) internal returns (uint256 hi) {
        uint256 lo = 50_000;
        hi = 5_000_000;
        assertTrue(_probeReplacement(callData, hi));
        vm.revertToState(snapshot);
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_probeReplacement(callData, mid)) hi = mid;
            else lo = mid;
            vm.revertToState(snapshot);
        }
    }

    /// @dev Calls CashModule with an owner-signed replacement request at `gasLimit`; a success must notify the module
    function _probeReplacement(bytes memory callData, uint256 gasLimit) internal returns (bool ok) {
        (ok,) = address(cashModule).call{ gas: gasLimit }(callData);
        if (ok) assertEq(module.callbackCount(), 1, "the cancel succeeded with the callback starved");
    }

    function _signedReplacementCall(uint256 amount) internal view returns (bytes memory) {
        address[] memory tokens = _single(address(usdc));
        uint256[] memory amounts = _single(amount);
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, address(safe), safe.nonce(), abi.encode(tokens, amounts, withdrawRecipient))).toEthSignedMessageHash();
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digest);
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        return abi.encodeCall(ICashModule.requestWithdrawal, (address(safe), tokens, amounts, withdrawRecipient, signers, signatures));
    }

    function _spendUsdc(uint256 amountUsd) internal {
        Cashback[] memory cashbacks;
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), keccak256(abi.encode("spend", amountUsd)), BinSponsor.Reap, _single(address(usdc)), _single(amountUsd), cashbacks);
    }

    function _warpPastDelay() internal {
        (uint64 withdrawalDelay,,) = cashModule.getDelays();
        vm.warp(block.timestamp + withdrawalDelay + 1);
    }

    function _pendingTokensLength() internal view returns (uint256) {
        return cashModule.getData(address(safe)).pendingWithdrawalRequest.tokens.length;
    }

    function _recordSlot() internal view returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(address(safe), CASH_MODULE_STORAGE_LOCATION))) + RECORD_SLOT);
    }

    function _record() internal view returns (bool) {
        return (uint256(vm.load(address(cashModule), _recordSlot())) >> (RECORD_OFFSET * 8)) & 0xff != 0;
    }

    /// @dev Models a request placed before the record existed
    function _clearRecord() internal {
        bytes32 slot = _recordSlot();
        uint256 word = uint256(vm.load(address(cashModule), slot));
        vm.store(address(cashModule), slot, bytes32(word & ~(uint256(0xff) << (RECORD_OFFSET * 8))));
        assertFalse(_record());
    }

    function _single(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _single(uint256 v) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = v;
    }

    function _singleBool(bool v) internal pure returns (bool[] memory arr) {
        arr = new bool[](1);
        arr[0] = v;
    }
}
