// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Mode } from "../../../../src/interfaces/ICashModule.sol";
import { CashModule, CashModuleTestSetup, CashVerificationLib, IDebtManager, MessageHashUtils } from "./CashModuleTestSetup.t.sol";

contract CashModuleModeTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;

    function test_getMode_initialValueIsDebit() public view {
        assertEq(uint8(cashModule.getMode(address(safe))), uint8(Mode.Debit));
    }

    function test_setMode_incursDelay_whenSwitchingFromDebitToCreditMode() public {
        assertEq(uint8(cashModule.getMode(address(safe))), uint8(Mode.Debit));

        _setMode(Mode.Credit);
        assertEq(uint8(cashModule.getMode(address(safe))), uint8(Mode.Debit));

        (,, uint256 modeDelay) = cashModule.getDelays();

        vm.warp(block.timestamp + modeDelay + 1);
        assertEq(uint8(cashModule.getMode(address(safe))), uint8(Mode.Credit));
    }

    function test_setMode_doesNotIncursDelay_whenSwitchingFromCreditToDebitMode() public {
        _setMode(Mode.Credit);
        (,, uint256 modeDelay) = cashModule.getDelays();

        vm.warp(block.timestamp + modeDelay + 1);
        assertEq(uint8(cashModule.getMode(address(safe))), uint8(Mode.Credit));

        _setMode(Mode.Debit);
        assertEq(uint8(cashModule.getMode(address(safe))), uint8(Mode.Debit));
    }

    function test_setMode_fails_whenModeIsAlreadyTheSame() public {
        Mode mode = cashModule.getMode(address(safe));
        uint256 nonce = cashModule.getNonce(address(safe));

        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.SET_MODE_METHOD, block.chainid, address(safe), nonce, abi.encode(mode))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);

        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(CashModule.ModeAlreadySet.selector);
        cashModule.setMode(address(safe), mode, owner1, signature);
    }
}
