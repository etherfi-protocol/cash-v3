// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { CashEventEmitter } from "../src/modules/cash/CashEventEmitter.sol";
import { CashModuleCore, BinSponsor } from "../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../src/modules/cash/CashModuleSetters.sol";
import { CashLens } from "../src/modules/cash/CashLens.sol";
import { DebtManagerCore } from "../src/debt-manager/DebtManagerCore.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";
import { TopUpDestNativeGateway } from "../src/top-up/TopUpDestNativeGateway.sol";
import { SettlementDispatcher } from "../src/settlement-dispatcher/SettlementDispatcher.sol";
import { UUPSProxy } from "../src/UUPSProxy.sol";

import { GnosisHelpers } from "./utils/GnosisHelpers.sol";
import { Utils } from "./utils/Utils.sol";

contract MultispendUpgrade is GnosisHelpers, Utils, Test {
    address usdcScroll = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    address weth = 0x5300000000000000000000000000000000000004;

    // https://docs.layerzero.network/v2/developers/evm/technical-reference/deployed-contracts
    uint32 optimismDestEid = 30111;
    address destAddressForDev = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;
    // https://stargateprotocol.gitbook.io/stargate/v/v2-developer-docs/technical-reference/mainnet-contracts#scroll
    address stargateUsdcPool = 0x3Fc69CC4A842838bCDC9499178740226062b14E4;

    address eventEmitter;
    address cashModule;
    address topUpDest;
    address cashLens;
    address debtManager;
    address dataProvider;
    address settlementDispatcherReap;
    address payable settlementDispatcherRain;
    address roleRegistry;

    function run() public {
        string memory deployments = readDeploymentFile();

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
        settlementDispatcherReap = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "SettlementDispatcherReap")
        );
        roleRegistry = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "RoleRegistry")
        );

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        address cashModuleCoreImpl = address(new CashModuleCore(dataProvider));
        address cashModuleSettersImpl = address(new CashModuleSetters(dataProvider));
        address cashEventEmitterImpl = address(new CashEventEmitter(cashModule));
        address cashLensImpl = address(new CashLens(cashModule, dataProvider));
        address settlementDispatcherReapImpl = address(new SettlementDispatcher(BinSponsor.Reap));
        address settlementDispatcherRainImpl = address(new SettlementDispatcher(BinSponsor.Rain));
        address debtManagerCoreImpl = address(new DebtManagerCore(dataProvider));

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);

        SettlementDispatcher.DestinationData[] memory destDatas = new SettlementDispatcher.DestinationData[](1);
        destDatas[0] = SettlementDispatcher.DestinationData({
            destEid: optimismDestEid,
            destRecipient: destAddressForDev,
            stargate: stargateUsdcPool
        });

        settlementDispatcherRain = payable(deployWithCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(settlementDispatcherRainImpl, "")), getSalt("SettlementDispatcherRainProxy")));
        SettlementDispatcher(settlementDispatcherRain).initialize(address(roleRegistry), tokens, destDatas);

        UUPSUpgradeable(settlementDispatcherReap).upgradeToAndCall(settlementDispatcherReapImpl, "");
        UUPSUpgradeable(debtManager).upgradeToAndCall(debtManagerCoreImpl, "");
        UUPSUpgradeable(cashModule).upgradeToAndCall(cashModuleCoreImpl, "");
        CashModuleCore(cashModule).setCashModuleSettersAddress(cashModuleSettersImpl);
        UUPSUpgradeable(eventEmitter).upgradeToAndCall(cashEventEmitterImpl, "");
        CashModuleSetters(cashModule).setReferrerCashbackPercentageInBps(100);        
        CashModuleSetters(cashModule).setSettlementDispatcher(BinSponsor.Rain, settlementDispatcherRain);        
        UUPSUpgradeable(cashLens).upgradeToAndCall(cashLensImpl, "");

        assert(CashModuleCore(cashModule).getReferrerCashbackPercentage() == 1_00);
        assert(CashModuleCore(cashModule).getSettlementDispatcher(BinSponsor.Reap) == settlementDispatcherReap);
        assert(CashModuleCore(cashModule).getSettlementDispatcher(BinSponsor.Rain) == settlementDispatcherRain);
        assert(IDebtManager(debtManager).isCollateralToken(weth));
    }   
}