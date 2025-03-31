// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Mode } from "../../../../src/interfaces/ICashModule.sol";
import { ArrayDeDupLib } from "../../../../src/libraries/ArrayDeDupLib.sol";
import { ModuleBase } from "../../../../src/modules/ModuleBase.sol";
import { CashEventEmitter, CashModuleTestSetup, CashVerificationLib, ICashModule, IDebtManager, MessageHashUtils } from "./CashModuleTestSetup.t.sol";

contract CashModuleWithdrawalTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;

    function test_requestWithdrawal_works() public {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // Verify pending withdrawal was set up correctly
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), withdrawalAmount);
    }

    function test_processWithdrawals_works() external {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // Verify pending withdrawal was set up correctly
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), withdrawalAmount);

        uint256 balBeforeSafe = usdcScroll.balanceOf(address(safe));
        uint256 balBeforeWithdrawRecipient = usdcScroll.balanceOf(address(withdrawRecipient));

        (uint64 withdrawalDelay,,) = cashModule.getDelays();
        vm.warp(block.timestamp + withdrawalDelay); // withdraw delay is 60 secs

        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.WithdrawalProcessed(address(safe), tokens, amounts, withdrawRecipient);
        cashModule.processWithdrawal(address(safe));

        uint256 balAfterSafe = usdcScroll.balanceOf(address(safe));
        uint256 balAfterWithdrawRecipient = usdcScroll.balanceOf(address(withdrawRecipient));

        assertEq(balBeforeSafe, withdrawalAmount);
        assertEq(balAfterSafe, 0);
        assertEq(balBeforeWithdrawRecipient, 0);
        assertEq(balAfterWithdrawRecipient, withdrawalAmount);

        // Verify pending withdrawal is 0
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), 0);
    }

    function test_processWithdrawals_fails_whenTheDelayIsNotOver() external {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // Verify pending withdrawal was set up correctly
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), withdrawalAmount);

        vm.expectRevert(ICashModule.CannotWithdrawYet.selector);
        cashModule.processWithdrawal(address(safe));
    }

    function test_requestWithdrawal_fails_whenAccountBecomesUnhealthy() external {
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdcScroll);
        tokens[1] = address(weETHScroll);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e6;
        amounts[1] = 1 ether;

        deal(tokens[0], address(safe), amounts[0]);
        deal(tokens[1], address(safe), amounts[1]);
        deal(address(usdcScroll), address(debtManager), 1 ether);

        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), 10e6, true);

        uint256 nonce = safe.nonce();

        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, address(safe), nonce, abi.encode(tokens, amounts, withdrawRecipient))).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        vm.expectRevert(IDebtManager.AccountUnhealthy.selector);
        cashModule.requestWithdrawal(address(safe), tokens, amounts, withdrawRecipient, signers, signatures);
    }

    function test_requestWithdrawal_resetWithdrawalWithNewRequest() public {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), 1000e6);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // Verify pending withdrawal was set up correctly
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), withdrawalAmount);

        uint256 newWithdrawalAmt = 100e6;
        amounts[0] = newWithdrawalAmt;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), newWithdrawalAmt);
    }
    
    function test_requestWithdrawal_fails_whenFundsAreInsufficient() public {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount - 1);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        uint256 nonce = safe.nonce();

        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, address(safe), nonce, abi.encode(tokens, amounts, withdrawRecipient))).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        cashModule.requestWithdrawal(address(safe), tokens, amounts, withdrawRecipient, signers, signatures);
    }

    function test_requestWithdrawal_fails_whenRecipientIsNull() public {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        uint256 nonce = safe.nonce();

        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, address(safe), nonce, abi.encode(tokens, amounts, address(0)))).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        vm.expectRevert(ICashModule.RecipientCannotBeAddressZero.selector);
        cashModule.requestWithdrawal(address(safe), tokens, amounts, address(0), signers, signatures);
    }

    function test_requestWithdrawal_fails_whenArrayLengthMismatch() public {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = withdrawalAmount;

        uint256 nonce = safe.nonce();

        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, address(safe), nonce, abi.encode(tokens, amounts, withdrawRecipient))).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        vm.expectRevert(ModuleBase.ArrayLengthMismatch.selector);
        cashModule.requestWithdrawal(address(safe), tokens, amounts, withdrawRecipient, signers, signatures);
    }

    function test_requestWithdrawal_fails_whenDuplicateTokens() public {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), 2 * withdrawalAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdcScroll);
        tokens[1] = address(usdcScroll);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = withdrawalAmount;
        amounts[1] = withdrawalAmount;

        uint256 nonce = safe.nonce();

        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, address(safe), nonce, abi.encode(tokens, amounts, withdrawRecipient))).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        vm.expectRevert(ArrayDeDupLib.DuplicateElementFound.selector);
        cashModule.requestWithdrawal(address(safe), tokens, amounts, withdrawRecipient, signers, signatures);
    }

    function test_requestWithdrawal_fails_whenInvalidSignature() public {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        uint256 nonce = safe.nonce();

        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, address(safe), nonce, abi.encode(tokens, amounts, withdrawRecipient))).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);

        // use the signature from owner1 itself for owner2 so its a wrong signature
        signatures[1] = abi.encodePacked(r1, s1, v1);

        vm.expectRevert(CashVerificationLib.InvalidSignatures.selector);
        cashModule.requestWithdrawal(address(safe), tokens, amounts, withdrawRecipient, signers, signatures);
    }
}
