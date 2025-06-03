// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import { TopUpDestNativeGateway } from "../src/top-up/TopUpDestNativeGateway.sol";
import { Utils } from "./utils/Utils.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";

contract AddWETH is Utils {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address public WETH = 0x5300000000000000000000000000000000000004;
    
    IDebtManager debtManager;
    string deployments;

    function run() public {
        deployments = readDeploymentFile();

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        debtManager = IDebtManager(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        ));

        debtManager = IDebtManager(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        ));

        IDebtManager.CollateralTokenConfig memory collateralConfig = IDebtManager.CollateralTokenConfig({
            ltv: 50e18,
            liquidationThreshold: 80e18,
            liquidationBonus: 1e18
        });

        debtManager.supportCollateralToken(address(WETH), collateralConfig);

        TopUpDestNativeGateway nativeGateway = new TopUpDestNativeGateway();

        vm.stopBroadcast();
    }
}