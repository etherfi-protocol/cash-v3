// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { RampVolumeEmitter } from "../../src/ramp-volume/RampVolumeEmitter.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/// @title GrantRampVolumeEmitterRole (Gnosis)
/// @notice Generates a Gnosis Safe batch to grant RAMP_VOLUME_EMITTER_ROLE to the backend
///         relayer. Use on networks where the RoleRegistry owner is the cash controller
///         multisig (e.g. OP mainnet prod) and the deploy script's inline grantRole was
///         skipped.
///
/// Env: RAMP_VOLUME_RELAYER (relayer address to authorize), plus ENV + chain so
///      readDeploymentFile() resolves RoleRegistry + RampVolumeEmitter.
contract GrantRampVolumeEmitterRole is GnosisHelpers, Utils {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    function run() public {
        address relayer = 0xeEf15d7Cef5246e03DCafE459D0a7DDf9bf3aA0F;

        string memory deployments = readDeploymentFile();
        string memory chainId = vm.toString(block.chainid);

        address roleRegistry = stdJson.readAddress(deployments, ".addresses.RoleRegistry");
        address rampVolumeEmitter = stdJson.readAddress(deployments, ".addresses.RampVolumeEmitter");

        bytes32 role = RampVolumeEmitter(rampVolumeEmitter).RAMP_VOLUME_EMITTER_ROLE();

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory grantRole = iToHex(abi.encodeWithSelector(RoleRegistry.grantRole.selector, role, relayer));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(roleRegistry), grantRole, "0", true)));

        vm.createDir("./output", true);
        string memory path = string.concat("./output/GrantRampVolumeEmitterRole-", chainId, ".json");
        vm.writeFile(path, txs);

        console.log("Generated gnosis tx granting RAMP_VOLUME_EMITTER_ROLE to %s on chain %s", relayer, chainId);

        executeGnosisTransactionBundle(path);
    }
}
