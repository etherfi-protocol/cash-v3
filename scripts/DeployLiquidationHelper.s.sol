// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import { CashLiquidationHelper } from "../src/modules/cash/CashLiquidationHelper.sol";
import {Utils, ChainConfig} from "./utils/Utils.sol";

contract DeployLiquidationHelper is Utils {
    CashLiquidationHelper liquidationHelper;

    address public eUsd = 0x939778D83b46B456224A33Fb59630B11DEC56663;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();

        address debtManager = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        );

        
        liquidationHelper = new CashLiquidationHelper(debtManager, eUsd);
        vm.stopBroadcast();
    }    
}
