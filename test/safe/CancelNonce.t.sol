// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { ArrayDeDupLib, EtherFiSafe, EtherFiSafeErrors, ModuleBase, SafeTestSetup } from "./SafeTestSetup.t.sol";

contract SafeCancelNonceTest is SafeTestSetup {
    function test_cancelNonce_incrementsTheNonce() public {
        uint256 currentNonce = safe.nonce();
        _cancelNonce();

        assertEq(safe.nonce(), currentNonce + 1);
    }

    function test_cancelNonce_reverts_withInvalidSingatures() public {
        uint256 nonce = safe.nonce();
        bytes32 structHash = keccak256(abi.encode(safe.CANCEL_NONCE_TYPEHASH(), nonce));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        // Sign with wrong private key (owner2) and send owner3 signer
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner3;

        vm.expectRevert(EtherFiSafeErrors.InvalidSignatures.selector);
        safe.cancelNonce(signers, signatures);
    }
}