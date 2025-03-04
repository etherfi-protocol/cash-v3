// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../../../src/UUPSProxy.sol";

import { DebtManagerAdmin } from "../../../../src/debt-manager/DebtManagerAdmin.sol";
import { DebtManagerCore, DebtManagerStorage } from "../../../../src/debt-manager/DebtManagerCore.sol";
import {CashbackDispatcher} from "../../../../src/cashback-dispatcher/CashbackDispatcher.sol";
import { Mode, SafeTiers } from "../../../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../../../src/interfaces/IDebtManager.sol";
import { IPriceProvider } from "../../../../src/interfaces/IPriceProvider.sol";
import { CashVerificationLib } from "../../../../src/libraries/CashVerificationLib.sol";
import { CashLens } from "../../../../src/modules/cash/CashLens.sol";
import { CashModule } from "../../../../src/modules/cash/CashModule.sol";
import { ArrayDeDupLib, EtherFiDataProvider, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup } from "../../SafeTestSetup.t.sol";
import { CashEventEmitter } from "../../../../src/modules/cash/CashEventEmitter.sol";

contract CashModuleTestSetup is SafeTestSetup {
    using MessageHashUtils for bytes32;

    IERC20 public usdcScroll = IERC20(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
    IERC20 public weETHScroll = IERC20(0x01f0a31698C4d065659b9bdC21B3610292a1c506);
    IERC20 public scrToken = IERC20(0xd29687c813D741E2F938F4aC377128810E217b1b);

    address public withdrawRecipient = makeAddr("withdrawRecipient");
    bytes32 txId = keccak256("txId");

    function setUp() public virtual override {
        vm.createSelectFork("https://rpc.scroll.io");

        super.setUp();
    
        vm.startPrank(cashOwnerGnosisSafe);
        DebtManagerCore debtManagerCore = new DebtManagerCore();
        DebtManagerAdmin debtManagerAdmin = new DebtManagerAdmin();
        CashbackDispatcher cashbackDispatcherImpl = new CashbackDispatcher();
        CashEventEmitter cashEventEmitterImpl = new CashEventEmitter();

        UUPSUpgradeable(address(debtManager)).upgradeToAndCall(address(debtManagerCore), abi.encodeWithSelector(DebtManagerStorage.initializeOnUpgrade.selector, address(dataProvider)));
        debtManager.setAdminImpl(address(debtManagerAdmin));

        UUPSUpgradeable(address(cashbackDispatcher)).upgradeToAndCall(address(cashbackDispatcherImpl), abi.encodeWithSelector(CashbackDispatcher.initializeOnUpgrade.selector, address(cashModule)));
        UUPSUpgradeable(address(cashEventEmitter)).upgradeToAndCall(address(cashEventEmitterImpl), abi.encodeWithSelector(CashEventEmitter.initializeOnUpgrade.selector, address(cashModule)));

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

        address[] memory withdrawRecipients = new address[](1);
        withdrawRecipients[0] = withdrawRecipient;

        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;

        _configureWithdrawRecipients(withdrawRecipients, shouldAdd);

        SafeTiers[] memory tiers = new SafeTiers[](4);
        tiers[0] = SafeTiers.Pepe;
        tiers[1] = SafeTiers.Wojak;
        tiers[2] = SafeTiers.Chad;
        tiers[3] = SafeTiers.Whale;

        uint256[] memory cashbackPercentages = new uint256[](4);
        cashbackPercentages[0] = 200;
        cashbackPercentages[1] = 300;
        cashbackPercentages[2] = 400;
        cashbackPercentages[3] = 400;

        cashModule.setTierCashbackPercentage(tiers, cashbackPercentages);

        vm.stopPrank();
    }

    function _configureWithdrawRecipients(address[] memory withdrawRecipients, bool[] memory shouldAdd) internal {
        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.CONFIGURE_WITHDRAWAL_RECIPIENT, block.chainid, address(safe), nonce, abi.encode(withdrawRecipients, shouldAdd))).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        cashModule.configureWithdrawRecipients(address(safe), withdrawRecipients, shouldAdd, signers, signatures);
    }

    function _requestWithdrawal(address[] memory tokens, uint256[] memory amounts, address recipient) internal {
        uint256 nonce = cashModule.getNonce(address(safe));

        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, address(safe), nonce, abi.encode(tokens, amounts, recipient))).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        cashModule.requestWithdrawal(address(safe), tokens, amounts, recipient, signers, signatures);
    }

    function _setMode(Mode mode) internal {
        uint256 nonce = cashModule.getNonce(address(safe));

        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.SET_MODE_METHOD, block.chainid, address(safe), nonce, abi.encode(mode))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);

        bytes memory signature = abi.encodePacked(r, s, v);

        cashModule.setMode(address(safe), mode, owner1, signature);
    }

    function _updateSpendingLimit(uint256 dailyLimit, uint256 monthlyLimit) internal {
        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.UPDATE_SPENDING_LIMIT_METHOD, block.chainid, address(safe), nonce, abi.encode(dailyLimit, monthlyLimit))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        cashModule.updateSpendingLimit(address(safe), dailyLimit, monthlyLimit, owner1, signature);
    }
}
