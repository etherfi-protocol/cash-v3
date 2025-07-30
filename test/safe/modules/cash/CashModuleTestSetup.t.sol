// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../../../src/UUPSProxy.sol";
import { CashbackDispatcher } from "../../../../src/cashback-dispatcher/CashbackDispatcher.sol";
import { DebtManagerAdmin } from "../../../../src/debt-manager/DebtManagerAdmin.sol";
import { DebtManagerCore, DebtManagerStorageContract } from "../../../../src/debt-manager/DebtManagerCore.sol";
import { ICashModule } from "../../../../src/interfaces/ICashModule.sol";
import { Mode, SafeTiers, Cashback, CashbackTokens, CashbackTypes } from "../../../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../../../src/interfaces/IDebtManager.sol";
import { IPriceProvider } from "../../../../src/interfaces/IPriceProvider.sol";
import { CashVerificationLib } from "../../../../src/libraries/CashVerificationLib.sol";
import { SpendingLimit } from "../../../../src/libraries/SpendingLimitLib.sol";
import { TimeLib } from "../../../../src/libraries/TimeLib.sol";

import { CashEventEmitter } from "../../../../src/modules/cash/CashEventEmitter.sol";
import { CashLens } from "../../../../src/modules/cash/CashLens.sol";
import { ArrayDeDupLib, EtherFiDataProvider, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup } from "../../SafeTestSetup.t.sol";

contract CashModuleTestSetup is SafeTestSetup {
    using MessageHashUtils for bytes32;
    using TimeLib for uint256;

    address withdrawRecipient = makeAddr("withdrawRecipient");
    bytes32 txId = keccak256("txId");

    function setUp() public virtual override {
        super.setUp();

        vm.stopPrank();

        vm.startPrank(owner);
        bytes memory safeCashSetupData = abi.encode(dailyLimitInUsd, monthlyLimitInUsd, timezoneOffset);
        bytes[] memory setupData = new bytes[](1);
        setupData[0] = safeCashSetupData;

        address[] memory modules = new address[](1);
        modules[0] = address(cashModule);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        _configureModules(modules, shouldWhitelist, setupData);        

        vm.stopPrank();
    }

    function _requestWithdrawal(address[] memory tokens, uint256[] memory amounts, address recipient) internal {
        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, address(safe), safe.nonce(), abi.encode(tokens, amounts, recipient))).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        (uint64 withdrawalDelay,,) = cashModule.getDelays();

        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.WithdrawalRequested(address(safe), tokens, amounts, recipient, block.timestamp + withdrawalDelay);
        cashModule.requestWithdrawal(address(safe), tokens, amounts, recipient, signers, signatures);
    }

    function _cancelWithdrawal(address[] memory tokens, uint256[] memory amounts, address recipient) internal {
        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.CANCEL_WITHDRAWAL_METHOD, block.chainid, address(safe), safe.nonce())).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.WithdrawalCancelled(address(safe), tokens, amounts, recipient);
        cashModule.cancelWithdrawal(address(safe), signers, signatures);
    }

    function _setMode(Mode mode) internal {
        uint256 nonce = cashModule.getNonce(address(safe));

        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.SET_MODE_METHOD, block.chainid, address(safe), nonce, abi.encode(mode))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);

        bytes memory signature = abi.encodePacked(r, s, v);

        Mode prevMode = mode == Mode.Debit ? Mode.Credit : Mode.Debit;
        (,, uint64 modeDelay) = cashModule.getDelays();
        uint256 modeStartTime = block.timestamp + modeDelay;

        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.ModeSet(address(safe), prevMode, mode, modeStartTime);
        cashModule.setMode(address(safe), mode, owner1, signature);
    }

    function _updateSpendingLimit(uint256 dailyLimit, uint256 monthlyLimit) internal {
        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.UPDATE_SPENDING_LIMIT_METHOD, block.chainid, address(safe), nonce, abi.encode(dailyLimit, monthlyLimit))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        (, uint64 spendLimitDelay,) = cashModule.getDelays();

        SpendingLimit memory oldLimit = cashLens.applicableSpendingLimit(address(safe));
        SpendingLimit memory newLimit = SpendingLimit({
            dailyLimit: oldLimit.dailyLimit,
            monthlyLimit: oldLimit.monthlyLimit,
            spentToday: oldLimit.spentToday,
            spentThisMonth: oldLimit.spentThisMonth,
            newDailyLimit: oldLimit.newDailyLimit,
            newMonthlyLimit: oldLimit.newMonthlyLimit,
            dailyRenewalTimestamp: oldLimit.dailyRenewalTimestamp,
            monthlyRenewalTimestamp: oldLimit.monthlyRenewalTimestamp,
            dailyLimitChangeActivationTime: oldLimit.dailyLimitChangeActivationTime,
            monthlyLimitChangeActivationTime: oldLimit.monthlyLimitChangeActivationTime,
            timezoneOffset: oldLimit.timezoneOffset
        });

        if (dailyLimit < oldLimit.dailyLimit) {
            newLimit.newDailyLimit = dailyLimit;
            newLimit.dailyLimitChangeActivationTime = uint64(block.timestamp) + spendLimitDelay;
        } else {
            newLimit.dailyLimit = dailyLimit;
            newLimit.newDailyLimit = 0;
            newLimit.dailyLimitChangeActivationTime = 0;
        }

        if (monthlyLimit < newLimit.monthlyLimit) {
            newLimit.newMonthlyLimit = monthlyLimit;
            newLimit.monthlyLimitChangeActivationTime = uint64(block.timestamp) + spendLimitDelay;
        } else {
            newLimit.monthlyLimit = monthlyLimit;
            newLimit.newMonthlyLimit = 0;
            newLimit.monthlyLimitChangeActivationTime = 0;
        }

        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.SpendingLimitChanged(address(safe), oldLimit, newLimit);
        cashModule.updateSpendingLimit(address(safe), dailyLimit, monthlyLimit, owner1, signature);
    }
}
