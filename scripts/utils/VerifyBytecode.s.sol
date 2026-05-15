// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ContractCodeChecker } from "./ContractCodeChecker.sol";

/**
 * @notice Generic on-chain bytecode verification. Deploys the contract locally from
 *         the compiled artifact + constructor args, then compares runtime bytecode
 *         against what's on-chain. A full match proves the on-chain code was compiled
 *         from this exact source with these exact constructor args and compiler settings.
 *
 * Env:
 *   ADDRESS          - on-chain address to verify
 *   ARTIFACT         - artifact name, e.g. "AssetRecoveryModule" (resolved from out/)
 *   CONSTRUCTOR_ARGS - ABI-encoded constructor args (hex). Pass "0x" if none.
 *
 * Usage:
 *   ADDRESS=0x431d... \
 *   ARTIFACT=AssetRecoveryModule \
 *   CONSTRUCTOR_ARGS=$(cast abi-encode "c(address,address,address)" $DP $LZ $SAFE) \
 *     forge script scripts/utils/VerifyBytecode.s.sol --rpc-url $RPC
 */
contract VerifyBytecode is Script, ContractCodeChecker {
    function run() external {
        address target = vm.envAddress("ADDRESS");
        string memory artifact = vm.envString("ARTIFACT");
        bytes memory constructorArgs = _readConstructorArgs();

        require(target.code.length > 0, "ADDRESS has no code on this chain");

        console.log("=== Bytecode Verification ===");
        console.log("Target   : %s", target);
        console.log("Artifact : %s", artifact);
        console.log("Chain ID : %s", block.chainid);
        console.log("On-chain : %s bytes", target.code.length);
        console.log("On-chain hash:");
        console.logBytes32(keccak256(target.code));

        bytes memory creationCode = abi.encodePacked(
            vm.getCode(artifact),
            constructorArgs
        );

        address local;
        assembly {
            local := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(local != address(0), "Local deployment failed - check ARTIFACT and CONSTRUCTOR_ARGS");

        console.log("Local    : %s bytes", local.code.length);
        console.log("Local hash:");
        console.logBytes32(keccak256(local.code));
        console.log("");

        verifyContractByteCodeMatch(target, local);
    }

    function _readConstructorArgs() internal view returns (bytes memory) {
        try vm.envBytes("CONSTRUCTOR_ARGS") returns (bytes memory args) {
            return args;
        } catch {
            return "";
        }
    }
}
