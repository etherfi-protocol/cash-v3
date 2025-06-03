// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import { CashLiquidationHelper } from "../src/modules/cash/CashLiquidationHelper.sol";
import {Utils, ChainConfig} from "./utils/Utils.sol";

contract DeployLiquidationHelper is Utils {
    CashLiquidationHelper liquidationHelper;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        ChainConfig memory chainConfig = getChainConfig(vm.toString(block.chainid));
        string memory deployments = readDeploymentFile();

        address debtManager = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        );

        address usdc = chainConfig.usdc;

        liquidationHelper = new CashLiquidationHelper(debtManager, usdc);
        vm.stopBroadcast();
    }    
}
