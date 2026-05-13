// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { ContractCodeChecker } from "./utils/ContractCodeChecker.sol";

import { PriceProviderV2 } from "../src/oracle/PriceProviderV2.sol";

/// @title Bytecode verification for PriceProviderV2 deployment
/// Usage:
///   source .env && ENV=mainnet forge script scripts/VerifyPriceProviderV2DeploymentBytecode.s.sol --rpc-url optimism -vvv
contract VerifyPriceProviderV2DeploymentBytecode is Script, ContractCodeChecker {
    function run() public {
        address priceProviderImpl = 0x5C37f6A9cE6cb2EE82B8e5c1c38B0fd799350152;

        console2.log("==========================================");
        console2.log("  Bytecode Verification:");
        console2.log("==========================================");
        console2.log("");

        _verifyPriceProviderV2(priceProviderImpl);

        console2.log("==========================================");
        console2.log("  Bytecode Verification Complete");
        console2.log("==========================================");
    }

    function _verifyPriceProviderV2(address onchainImpl) internal {
        console2.log("On-chain impl:   ", onchainImpl);

        address local = address(new PriceProviderV2());
        console2.log("Local re-deploy: ", local);

        verifyContractByteCodeMatch(onchainImpl, local);
    }
}
