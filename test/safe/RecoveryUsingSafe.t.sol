// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { ArrayDeDupLib, EtherFiSafe, EtherFiSafeErrors } from "./SafeTestSetup.t.sol";
import { RecoveryManager } from "../../src/safe/RecoveryManager.sol";

contract RecoveryUsingSafe is Test {
    using MessageHashUtils for bytes32;

    EtherFiSafe safe = EtherFiSafe(payable(0x62cfF8CcCfde97790A599A85bE430873E09c4f5a));
    address newOwner = 0x7fEd99d0aA90423de55e238Eb5F9416FF7Cc58eF;

    function setUp() public {
        string memory scrollRpc = vm.envString("SCROLL_RPC");
        if (bytes(scrollRpc).length != 0) scrollRpc = "https://rpc.scroll.io"; 
        vm.createSelectFork(scrollRpc);
    }

    function test_BuildMessageHashAndDigest() external {
        bytes32 structHash = keccak256(abi.encode(safe.RECOVER_SAFE_TYPEHASH(), newOwner, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        emit log_named_bytes32("structHash", structHash);
        emit log_named_bytes32("digestHash", digestHash);
    }
    
    function test_recoverSafeUsingGnosisSafe() public {
        bytes[] memory signatures = new bytes[](2);
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = 0xa265C271adbb0984EFd67310cfe85A77f449e291;
        recoverySigners[1] = 0xbfCe61CE31359267605F18dcE65Cb6c3cc9694A7;

        safe.recoverSafe(newOwner, recoverySigners, signatures);
    }
}