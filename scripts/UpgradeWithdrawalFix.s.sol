// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { CashModuleCore } from "../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../src/modules/cash/CashModuleSetters.sol";
import { CashEventEmitter } from "../src/modules/cash/CashEventEmitter.sol";
import { DebtManagerCore } from "../src/debt-manager/DebtManagerCore.sol";
import { DebtManagerAdmin } from "../src/debt-manager/DebtManagerAdmin.sol";
import { GnosisHelpers } from "./utils/GnosisHelpers.sol";
import { Utils } from "./utils/Utils.sol";

contract UpgradeWithdrawalFix is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address cashModule;
    address cashEventEmitter;
    address debtManager;
    address dataProvider;

    address cashModuleCoreImpl;
    address cashModuleSettersImpl;
    address cashEventEmitterImpl;
    address debtManagerCoreImpl;

    address[] withdrawTokens;
    bool[] shouldWhitelist;

    address public weth = 0x5300000000000000000000000000000000000004;
    address public weEth = 0x01f0a31698C4d065659b9bdC21B3610292a1c506;
    address public usdc = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    address public liquidEth = 0xf0bb20865277aBd641a307eCe5Ee04E79073416C;   
    address public liquidUsd = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address public liquidBtc = 0x5f46d540b6eD704C3c8789105F30E075AA900726;
    address public eUsd = 0x939778D83b46B456224A33Fb59630B11DEC56663;
    address public eBtc = 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;
    address public scr = 0xd29687c813D741E2F938F4aC377128810E217b1b;
    address public ethfi = 0x056A5FA5da84ceb7f93d36e545C5905607D8bD81;

    function run() public {
        string memory deployments = readDeploymentFile();
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        cashModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModule")
        );
        debtManager = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        );
        cashEventEmitter = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashEventEmitter")
        );
        dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );

        cashModuleCoreImpl = address(new CashModuleCore(dataProvider));
        cashModuleSettersImpl = address(new CashModuleSetters(dataProvider));
        debtManagerCoreImpl = address(new DebtManagerCore(dataProvider));
        cashEventEmitterImpl = address(new CashEventEmitter(cashModule));

        _buildWithdrawArrays();

        UUPSUpgradeable(debtManager).upgradeToAndCall(debtManagerCoreImpl, "");
        UUPSUpgradeable(cashModule).upgradeToAndCall(cashModuleCoreImpl, "");
        CashModuleCore(cashModule).setCashModuleSettersAddress(cashModuleSettersImpl);
        UUPSUpgradeable(cashEventEmitter).upgradeToAndCall(cashEventEmitterImpl, "");
        CashModuleSetters(cashModule).configureWithdrawAssets(withdrawTokens, shouldWhitelist);

        vm.stopBroadcast();
    }

    function _buildWithdrawArrays() internal {
        withdrawTokens.push(weth);
        withdrawTokens.push(weEth);
        withdrawTokens.push(usdc);
        withdrawTokens.push(liquidEth);
        withdrawTokens.push(liquidUsd);
        withdrawTokens.push(liquidBtc);
        withdrawTokens.push(eUsd);
        withdrawTokens.push(eBtc);
        withdrawTokens.push(scr);
        withdrawTokens.push(ethfi);

        shouldWhitelist.push(true);
        shouldWhitelist.push(true);
        shouldWhitelist.push(true);
        shouldWhitelist.push(true);
        shouldWhitelist.push(true);
        shouldWhitelist.push(true);
        shouldWhitelist.push(true);
        shouldWhitelist.push(true);
        shouldWhitelist.push(true);
        shouldWhitelist.push(true);
    }
}