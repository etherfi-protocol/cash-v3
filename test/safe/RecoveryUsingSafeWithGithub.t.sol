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
    address safeAddress;

    function setUp() public {
        string memory scrollRpc = vm.envString("SCROLL_RPC");
        
        try vm.envAddress("RECOVERY_SAFE_ADDRESS") returns (address addr) {
            safeAddress = addr;
        } catch {
            safeAddress = address(0);
        }
        try vm.envAddress("RECOVERY_NEW_OWNER") returns (address addr) {
            newOwner = addr;
        } catch {
            newOwner = address(0);
        }

        // skip the tests if the env vars are not set
        if (safeAddress == address(0) || newOwner == address(0)) {
            vm.skip(true);
            return;
        }

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
