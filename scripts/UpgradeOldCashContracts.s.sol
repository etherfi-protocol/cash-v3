// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {console} from "forge-std/console.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {Utils, ChainConfig} from "./utils/Utils.sol";
import {DebtManagerCore} from "../src/debt-manager/DebtManagerCore.sol";
import {DebtManagerStorage} from "../src/debt-manager/DebtManagerStorage.sol";
import {DebtManagerAdmin} from "../src/debt-manager/DebtManagerAdmin.sol";
import {CashbackDispatcher} from "../src/cashback-dispatcher/CashbackDispatcher.sol";
import {CashEventEmitter} from "../src/modules/cash/CashEventEmitter.sol";
import {EtherFiDataProvider} from "../src/data-provider/EtherFiDataProvider.sol";
import {IDebtManager} from "../src/interfaces/IDebtManager.sol";
import {ICashbackDispatcher} from "../src/interfaces/ICashbackDispatcher.sol";
import {IPriceProvider} from "../src/interfaces/IPriceProvider.sol";
import {ICashEventEmitter} from "../src/interfaces/ICashEventEmitter.sol";

contract UpgradeOldCashContracts is Utils {
    IDebtManager debtManager = IDebtManager(0x8f9d2Cd33551CE06dD0564Ba147513F715c2F4a0);
    ICashbackDispatcher cashbackDispatcher = ICashbackDispatcher(0x7d372C3ca903CA2B6ecd8600D567eb6bAfC5e6c9);
    IPriceProvider priceProvider = IPriceProvider(0x8B4C8c403fc015C46061A8702799490FD616E3bf);
    ICashEventEmitter cashEventEmitter = ICashEventEmitter(0x5423885B376eBb4e6104b8Ab1A908D350F6A162e);
    address settlementDispatcher = 0x4Dca5093E0bB450D7f7961b5Df0A9d4c24B24786;
    address cashOwnerGnosisSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        // DebtManagerCore debtManagerCore = new DebtManagerCore();
        // DebtManagerAdmin debtManagerAdmin = new DebtManagerAdmin();
        // CashbackDispatcher cashbackDispatcherImpl = new CashbackDispatcher();
        // CashEventEmitter cashEventEmitterImpl = new CashEventEmitter();
        address debtManagerCore = 0x0a7245f50f980985beB4D2e1887904598A1Fa2e4;
        address debtManagerAdmin = 0x3716254F192Bf7D779B6341Bf6D7BD4a690b751b;
        address cashbackDispatcherImpl = 0x98A824ba25e8B0a865113A06949f73B8749D1444;
        address cashEventEmitterImpl = 0xcD8F1f89F65a53e28F6B7E0Df7184e00080BbEfB;

        string memory deployments = readDeploymentFile();

        EtherFiDataProvider dataProvider = EtherFiDataProvider(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        ));

        address cashModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModule")
        );

        // console.log("from");
        // console.log(address(cashOwnerGnosisSafe));
        // console.log("to");
        // console.log(address(cashEventEmitter));
        // console.log("data");
        // console.logBytes(
        //     abi.encodeWithSelector(
        //         UUPSUpgradeable.upgradeToAndCall.selector,
        //         address(cashEventEmitterImpl),
        //         abi.encodeWithSelector(CashEventEmitter.initializeOnUpgrade.selector, address(cashModule))
        //     )
        // );
        UUPSUpgradeable(address(debtManager)).upgradeToAndCall(address(debtManagerCore), abi.encodeWithSelector(DebtManagerCore.initializeOnUpgrade.selector, address(dataProvider)));
        debtManager.setAdminImpl(address(debtManagerAdmin));

        UUPSUpgradeable(address(cashbackDispatcher)).upgradeToAndCall(address(cashbackDispatcherImpl), abi.encodeWithSelector(CashbackDispatcher.initializeOnUpgrade.selector, address(cashModule)));
        UUPSUpgradeable(address(cashEventEmitter)).upgradeToAndCall(address(cashEventEmitterImpl), abi.encodeWithSelector(CashEventEmitter.initializeOnUpgrade.selector, address(cashModule)));
        vm.stopBroadcast();
    }
}