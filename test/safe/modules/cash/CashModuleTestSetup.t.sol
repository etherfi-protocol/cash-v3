// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../../../src/UUPSProxy.sol";

import { ICashDataProvider } from "../../../../src/interfaces/ICashDataProvider.sol";

import { Mode } from "../../../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../../../src/interfaces/IDebtManager.sol";
import { IPriceProvider } from "../../../../src/interfaces/IPriceProvider.sol";
import { CashVerificationLib } from "../../../../src/libraries/CashVerificationLib.sol";
import { CashModule } from "../../../../src/modules/cash/CashModule.sol";

import { ArrayDeDupLib, EtherFiDataProvider, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup } from "../../SafeTestSetup.t.sol";

contract CashModuleTestSetup is SafeTestSetup {
    using MessageHashUtils for bytes32;

    CashModule public cashModule;

    address public etherFiWallet = makeAddr("etherFiWallet");

    IERC20 public usdcScroll = IERC20(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
    IERC20 public weETHScroll = IERC20(0x01f0a31698C4d065659b9bdC21B3610292a1c506);
    IERC20 public scrToken = IERC20(0xd29687c813D741E2F938F4aC377128810E217b1b);

    ICashDataProvider cashDataProvider = ICashDataProvider(0xb1F5bBc3e4DE0c767ace41EAb8A28b837fBA966F);
    IDebtManager debtManager = IDebtManager(0x8f9d2Cd33551CE06dD0564Ba147513F715c2F4a0);
    IPriceProvider priceProvider = IPriceProvider(0x8B4C8c403fc015C46061A8702799490FD616E3bf);
    address settlementDispatcher = 0x4Dca5093E0bB450D7f7961b5Df0A9d4c24B24786;
    address cashOwnerGnosisSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    uint256 dailyLimitInUsd = 10_000e6;
    uint256 monthlyLimitInUsd = 100_000e6;
    int256 timezoneOffset = -4 * 3600; // cayman timezone

    address public withdrawRecipient = makeAddr("withdrawRecipient");

    function setUp() public override {
        vm.createSelectFork("https://rpc.scroll.io");

        super.setUp();

        // the cash data provider currently whitelists all user safes
        vm.prank(cashOwnerGnosisSafe);
        cashDataProvider.setUserSafeFactory(owner);
        vm.prank(owner);
        cashDataProvider.whitelistUserSafe(address(safe));

        address cashModuleImpl = address(new CashModule(address(dataProvider)));
        cashModule = CashModule(address(new UUPSProxy(cashModuleImpl, abi.encodeWithSelector(CashModule.initialize.selector, address(roleRegistry), address(debtManager), settlementDispatcher, address(priceProvider)))));

        bytes memory safeCashSetupData = abi.encode(dailyLimitInUsd, monthlyLimitInUsd, timezoneOffset);
        bytes[] memory setupData = new bytes[](1);
        setupData[0] = safeCashSetupData;

        vm.startPrank(owner);
        roleRegistry.grantRole(cashModule.ETHER_FI_WALLET_ROLE(), etherFiWallet);

        address[] memory modules = new address[](1);
        modules[0] = address(cashModule);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        dataProvider.configureModules(modules, shouldWhitelist);

        _configureModules(modules, shouldWhitelist, setupData);

        address[] memory withdrawRecipients = new address[](1);
        withdrawRecipients[0] = withdrawRecipient;

        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;

        _configureWithdrawRecipients(withdrawRecipients, shouldAdd);

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

        /// TODO: Remove this when debt manager is upgraded
        vm.mockCall(address(debtManager), abi.encodeWithSelector(IDebtManager.ensureHealth.selector, address(safe)), abi.encode());

        cashModule.requestWithdrawal(address(safe), tokens, amounts, recipient, signers, signatures);
    }

    function _setMode(Mode mode) internal {
        uint256 nonce = cashModule.getNonce(address(safe));

        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.SET_MODE_METHOD, block.chainid, address(safe), nonce, abi.encode(mode))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);

        bytes memory signature = abi.encodePacked(r, s, v);

        cashModule.setMode(address(safe), mode, owner1, signature);
    }
}
