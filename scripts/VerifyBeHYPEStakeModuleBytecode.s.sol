// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {ContractCodeChecker} from "./utils/ContractCodeChecker.sol";
import {Utils} from "./utils/Utils.sol";

import {BeHYPEStakeModule} from "../src/modules/hype/BeHYPEStakeModule.sol";

/// @title Bytecode verification for BeHYPEStakeModule on OP Mainnet
/// @notice Deploys the contract locally with the same constructor args and compares
///         runtime bytecode against the on-chain deployed contract.
///
/// Usage:
///   ENV=mainnet forge script scripts/VerifyBeHYPEStakeModuleBytecode.s.sol --rpc-url $OPTIMISM_RPC -vvv
contract VerifyBeHYPEStakeModuleBytecode is Script, ContractCodeChecker, Utils {
    uint32 constant REFUND_GAS_LIMIT = 5_000;

    function run() public {
        require(block.chainid == 10, "Must run on OP Mainnet (chain 10)");

        string memory deployments = readDeploymentFile();
        string memory chainId = vm.toString(block.chainid);

        address onchain = stdJson.readAddress(deployments, ".addresses.BeHYPEStakeModule");
        address dp = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");

        string memory fixturesFile = string.concat(
            vm.projectRoot(),
            string.concat("/deployments/", getEnv(), "/fixtures/fixtures.json")
        );
        string memory fixtures = vm.readFile(fixturesFile);

        address l2BeHypeStaker = stdJson.readAddress(fixtures, string.concat(".", chainId, ".l2BeHypeStaker"));
        address whype = stdJson.readAddress(fixtures, string.concat(".", chainId, ".wHYPE"));
        address beHYPE = stdJson.readAddress(fixtures, string.concat(".", chainId, ".beHYPE"));

        console2.log("==========================================");
        console2.log("  BeHYPEStakeModule Bytecode Verification");
        console2.log("==========================================\n");
        console2.log("On-chain:", onchain);
        console2.log("DataProvider:", dp);
        console2.log("L2BeHypeStaker:", l2BeHypeStaker);
        console2.log("wHYPE:", whype);
        console2.log("beHYPE:", beHYPE);
        console2.log("");

        address local = address(new BeHYPEStakeModule(dp, l2BeHypeStaker, whype, beHYPE, REFUND_GAS_LIMIT));
        verifyContractByteCodeMatch(onchain, local);

        console2.log("\n==========================================");
        console2.log("  Bytecode Verification Complete");
        console2.log("==========================================");
    }
}
