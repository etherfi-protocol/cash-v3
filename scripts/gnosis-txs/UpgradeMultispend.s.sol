// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { CashLens } from "../../src/modules/cash/CashLens.sol";
import { TopUpDestNativeGateway } from "../../src/top-up/TopUpDestNativeGateway.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";

import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract UpgradeMultispend is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address weth = 0x5300000000000000000000000000000000000004;

    address eventEmitter;
    address cashModule;
    address topUpDest;
    address cashLens;
    address debtManager;
    address dataProvider;

    function run() public {
        string memory deployments = readDeploymentFile();

        string memory chainId = vm.toString(block.chainid);

        cashModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModule")
        );
        cashLens = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashLens")
        );
        debtManager = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        );
        eventEmitter = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashEventEmitter")
        );
        topUpDest = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "TopUpDest")
        );
        dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );

        vm.startBroadcast();

        address cashModuleCoreImpl = address(new CashModuleCore(dataProvider));
        address cashModuleSettersImpl = address(new CashModuleSetters(dataProvider));
        address cashEventEmitterImpl = address(new CashEventEmitter(cashModule));
        address cashLensImpl = address(new CashLens(cashModule, dataProvider));

        IDebtManager.CollateralTokenConfig memory collateralConfig = IDebtManager.CollateralTokenConfig({
            ltv: 50e18,
            liquidationThreshold: 80e18,
            liquidationBonus: 1e18
        });

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory cashModuleCoreUpgrade = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashModuleCoreImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), cashModuleCoreUpgrade, false)));

        string memory cashModuleSettersUpgrade = iToHex(abi.encodeWithSelector(CashModuleCore.setCashModuleSettersAddress.selector, cashModuleSettersImpl));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), cashModuleSettersUpgrade, false)));
        
        string memory cashEventEmitterUpgrade = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashEventEmitterImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(eventEmitter), cashEventEmitterUpgrade, false)));

        string memory setReferrerCashbackPercentage = iToHex(abi.encodeWithSelector(CashModuleSetters.setReferrerCashbackPercentageInBps.selector, 1_00));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), setReferrerCashbackPercentage, false)));
        
        string memory setWETHConfig = iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, address(weth), collateralConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(debtManager)), setWETHConfig, false)));
        
        string memory cashLensUpgrade = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashLensImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashLens), cashLensUpgrade, true)));

        vm.createDir("./output", true);
        string memory path = "./output/UpgradeMultispend.json";
        vm.writeFile(path, txs);

        vm.stopBroadcast();

        /// below here is just a test
        executeGnosisTransactionBundle(path);
        assert(CashModuleCore(cashModule).getReferrerCashbackPercentage() == 1_00);
        assert(IDebtManager(debtManager).isCollateralToken(weth));
    }   
}