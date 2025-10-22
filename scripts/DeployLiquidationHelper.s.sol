// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import { CashLiquidationHelper } from "../src/modules/cash/CashLiquidationHelper.sol";
import {Utils, ChainConfig} from "./utils/Utils.sol";

contract DeployLiquidationHelper is Utils {
    CashLiquidationHelper liquidationHelper;

    address public usdc = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    address public usdt = 0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df;
    address public liquidUsd = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address public eUsd = 0x939778D83b46B456224A33Fb59630B11DEC56663;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();

        address debtManager = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        );

        
        liquidationHelper = new CashLiquidationHelper(debtManager, usdc, usdt, liquidUsd, eUsd);
        vm.stopBroadcast();
    }    
}
