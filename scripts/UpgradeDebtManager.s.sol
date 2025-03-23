// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {DebtManagerAdmin} from "../src/debt-manager/DebtManagerAdmin.sol";
import {DebtManagerCore} from "../src/debt-manager/DebtManagerCore.sol";
import {IDebtManager} from "../src/interfaces/IDebtManager.sol";
import {Utils, ChainConfig} from "./utils/Utils.sol";

contract UpgradeDebtManager is Utils {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();

        IDebtManager debtManager = IDebtManager(stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "DebtManager"))
        ));

        address dataProvider = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider"))
        );

        DebtManagerCore debtManagerCoreImpl = new DebtManagerCore(dataProvider);
        DebtManagerAdmin debtManagerAdminImpl = new DebtManagerAdmin(dataProvider);

        UUPSUpgradeable(address(debtManager)).upgradeToAndCall(address(debtManagerCoreImpl), "");
        IDebtManager(address(debtManager)).setAdminImpl(address(debtManagerAdminImpl));
        vm.stopBroadcast();
    }
}