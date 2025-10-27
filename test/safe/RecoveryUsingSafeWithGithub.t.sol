// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { ArrayDeDupLib, EtherFiSafe, EtherFiSafeErrors } from "./SafeTestSetup.t.sol";
import { RecoveryManager } from "../../src/safe/RecoveryManager.sol";

contract RecoveryUsingSafeWithGithub is Test {
    using MessageHashUtils for bytes32;

    EtherFiSafe safe;
    address newOwner;

    function setUp() public {
        string memory scrollRpc = vm.envString("SCROLL_RPC");
        address safeAddress = vm.envAddress("RECOVERY_SAFE_ADDRESS");
        newOwner = vm.envAddress("RECOVERY_NEW_OWNER");

        if (safeAddress == address(0)) revert("RECOVERY_SAFE_ADDRESS is not set");
        if (newOwner == address(0)) revert("RECOVERY_NEW_OWNER is not set");

        safe = EtherFiSafe(payable(safeAddress));
        if (bytes(scrollRpc).length == 0) scrollRpc = "https://rpc.scroll.io"; 
        vm.createSelectFork(scrollRpc);
    }

    function test_BuildMessageHashAndDigestGithub() external {
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