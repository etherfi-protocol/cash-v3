// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";

import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract AddWETH is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address public WETH = 0x5300000000000000000000000000000000000004;
    
    IDebtManager debtManager;
    string chainId;
    string deployments;

    function run() public {
        deployments = readDeploymentFile();

        chainId = vm.toString(block.chainid);

        vm.startBroadcast();

        debtManager = IDebtManager(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        ));

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        IDebtManager.CollateralTokenConfig memory collateralConfig = IDebtManager.CollateralTokenConfig({
            ltv: 50e18,
            liquidationThreshold: 80e18,
            liquidationBonus: 1e18
        });

        string memory setWETHConfig = iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, address(WETH), collateralConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(debtManager)), setWETHConfig, true)));

        vm.createDir("./output", true);
        string memory path = "./output/AddWETH.json";
        vm.writeFile(path, txs);

        vm.stopBroadcast();
    }
}