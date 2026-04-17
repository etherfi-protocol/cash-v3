// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { ContractCodeChecker } from "./utils/ContractCodeChecker.sol";
import { Utils } from "./utils/Utils.sol";

import { MidasModule } from "../src/modules/midas/MidasModule.sol";

/// @title Bytecode verification for OP Mainnet MidasModule (weEUR)
/// @notice Deploys the contract locally with the same constructor args and compares
///         runtime bytecode against the on-chain deployed contract.
///
/// Usage:
///   ENV=mainnet forge script scripts/VerifyMidasModuleBytecode.s.sol --rpc-url $OPTIMISM_RPC -vvv
contract VerifyMidasModuleBytecode is Script, ContractCodeChecker, Utils {
    address constant MIDAS_MODULE = 0x2D43400058cE6810916Fd312FB38a7DcdF9708aa;

    address constant WEEUR_TOKEN = 0xcC476B1a49bcDf5192561e87b6Fb8ea78aa28C13;
    address constant DEPOSIT_VAULT = 0xF1b45eE795C8e1B858e191654C95A1B33c573632;
    address constant REDEMPTION_VAULT = 0xDC87653FCc5c16407Cd2e199d5Db48BaB71e7861;

    function run() public {
        require(block.chainid == 10, "Must run on OP Mainnet (chain 10)");

        string memory deployments = readDeploymentFile();
        address dp = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "EtherFiDataProvider"));

        console2.log("==========================================");
        console2.log("  MidasModule Bytecode Verification");
        console2.log("==========================================\n");
        console2.log("On-chain address:", MIDAS_MODULE);

        address[] memory midasTokens = new address[](1);
        midasTokens[0] = WEEUR_TOKEN;

        address[] memory depositVaults = new address[](1);
        depositVaults[0] = DEPOSIT_VAULT;

        address[] memory redemptionVaults = new address[](1);
        redemptionVaults[0] = REDEMPTION_VAULT;

        address local = address(new MidasModule(dp, midasTokens, depositVaults, redemptionVaults));
        verifyContractByteCodeMatch(MIDAS_MODULE, local);

        console2.log("\n==========================================");
        console2.log("  Bytecode Verification Complete");
        console2.log("==========================================");
    }
}
