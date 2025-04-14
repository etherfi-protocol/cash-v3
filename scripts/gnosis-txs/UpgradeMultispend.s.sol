// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { CashModuleCore, BinSponsor } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { CashLens } from "../../src/modules/cash/CashLens.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { TopUpDestNativeGateway } from "../../src/top-up/TopUpDestNativeGateway.sol";
import { SettlementDispatcher } from "../../src/settlement-dispatcher/SettlementDispatcher.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";

import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract UpgradeMultispend is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address weth = 0x5300000000000000000000000000000000000004;

    address usdcScroll = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;

    // https://docs.layerzero.network/v2/developers/evm/technical-reference/deployed-contracts
    uint32 optimismDestEid = 30111;
    address rykiOpAddress = 0x6f7F522075AA5483d049dF0Ef81FcdD3b0ace7f4;
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
        settlementDispatcherReap = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "SettlementDispatcherReap")
        );
        roleRegistry = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "RoleRegistry")
        );

        vm.startBroadcast();

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
            destRecipient: rykiOpAddress,
            stargate: stargateUsdcPool
        });

        settlementDispatcherRain = payable(deployWithCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(settlementDispatcherRainImpl, "")), getSalt(SETTLEMENT_DISPATCHER_RAIN_PROXY)));
        SettlementDispatcher(settlementDispatcherRain).initialize(address(roleRegistry), tokens, destDatas);

        IDebtManager.CollateralTokenConfig memory collateralConfig = IDebtManager.CollateralTokenConfig({
            ltv: 50e18,
            liquidationThreshold: 80e18,
            liquidationBonus: 1e18
        });

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory settlementDispatcherReapUpgrade = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, settlementDispatcherReapImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherReap), settlementDispatcherReapUpgrade, false)));
        
        string memory debtManagerCoreUpgrade = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, debtManagerCoreImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), debtManagerCoreUpgrade, false)));

        string memory cashModuleCoreUpgrade = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashModuleCoreImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), cashModuleCoreUpgrade, false)));

        string memory cashModuleSettersUpgrade = iToHex(abi.encodeWithSelector(CashModuleCore.setCashModuleSettersAddress.selector, cashModuleSettersImpl));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), cashModuleSettersUpgrade, false)));
        
        string memory cashEventEmitterUpgrade = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashEventEmitterImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(eventEmitter), cashEventEmitterUpgrade, false)));

        string memory setReferrerCashbackPercentage = iToHex(abi.encodeWithSelector(CashModuleSetters.setReferrerCashbackPercentageInBps.selector, 1_00));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), setReferrerCashbackPercentage, false)));
        
        string memory setSettlementDispatcherRain = iToHex(abi.encodeWithSelector(CashModuleSetters.setSettlementDispatcher.selector, BinSponsor.Rain, settlementDispatcherRain));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), setSettlementDispatcherRain, false)));
        
        string memory setWETHConfig = iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, address(weth), collateralConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(debtManager)), setWETHConfig, false)));
        
        string memory cashLensUpgrade = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashLensImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashLens), cashLensUpgrade, true)));

        vm.createDir("./output", true);
        string memory path = "./output/UpgradeMultispendAndSettlementDispatcher.json";
        vm.writeFile(path, txs);

        vm.stopBroadcast();

        /// below here is just a test
        executeGnosisTransactionBundle(path);
        assert(CashModuleCore(cashModule).getReferrerCashbackPercentage() == 1_00);
        assert(CashModuleCore(cashModule).getSettlementDispatcher(BinSponsor.Reap) == settlementDispatcherReap);
        assert(CashModuleCore(cashModule).getSettlementDispatcher(BinSponsor.Rain) == settlementDispatcherRain);
        assert(IDebtManager(debtManager).isCollateralToken(weth));
    }   
}