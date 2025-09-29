// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { BinSponsor, SettlementDispatcher } from "../../src/settlement-dispatcher/SettlementDispatcher.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { DebtManagerAdmin } from "../../src/debt-manager/DebtManagerAdmin.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract UpgradePix is GnosisHelpers, Utils {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    SettlementDispatcher pixSettlementDispatcherImpl;
    UUPSProxy pixSettlementDispatcherProxy;

    address cashModule;
    address cashEventEmitter;
    address debtManager;
    address dataProvider;
    address roleRegistry;

    address cashModuleCoreImpl;
    address cashModuleSettersImpl;
    address cashEventEmitterImpl;
    address debtManagerCoreImpl;
    address debtManagerAdminImpl;

    address public usdc = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    address public usdt = 0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df;
    address public liquidUsd = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address public liquidUsdBoringQueue = 0x38FC1BA73b7ED289955a07d9F11A85b6E388064A;

    function run() public {
        string memory deployments = readDeploymentFile();
        // uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast();

        roleRegistry = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "RoleRegistry")
        );
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

        require(roleRegistry != address(0), "Invalid roleRegistry");
        require(cashModule != address(0), "Invalid cashModule");
        require(debtManager != address(0), "Invalid debtManager");
        require(cashEventEmitter != address(0), "Invalid cashEventEmitter");
        require(dataProvider != address(0), "Invalid dataProvider");

        pixSettlementDispatcherImpl = new SettlementDispatcher(BinSponsor.PIX, dataProvider);

        address[] memory tokens = new address[](2);
        tokens[0] = usdc;
        tokens[1] = usdt;

        SettlementDispatcher.DestinationData[] memory destDatas = new SettlementDispatcher.DestinationData[](2);

        destDatas[0] = SettlementDispatcher.DestinationData({
            destEid: 0,
            destRecipient: 0x6f7F522075AA5483d049dF0Ef81FcdD3b0ace7f4,
            stargate: address(0),
            useCanonicalBridge: true,
            minGasLimit: 0
        });
        destDatas[1] = SettlementDispatcher.DestinationData({
            destEid: 0,
            destRecipient: 0x6f7F522075AA5483d049dF0Ef81FcdD3b0ace7f4,
            stargate: address(0),
            useCanonicalBridge: true,
            minGasLimit: 0
        });

        pixSettlementDispatcherProxy = new UUPSProxy(
            address(pixSettlementDispatcherImpl),
            abi.encodeWithSelector(SettlementDispatcher.initialize.selector, roleRegistry, tokens, destDatas)
        );

        cashModuleCoreImpl = address(new CashModuleCore(dataProvider));
        cashModuleSettersImpl = address(new CashModuleSetters(dataProvider));
        debtManagerCoreImpl = address(new DebtManagerCore(dataProvider));
        cashEventEmitterImpl = address(new CashEventEmitter(cashModule));
        debtManagerAdminImpl = address(new DebtManagerAdmin(dataProvider));

        string memory txs = getGnosisTransactions();

        string memory path = string.concat("./output/UpgradePix.json");
        vm.writeFile(path, txs);

        vm.stopBroadcast();
        
        executeGnosisTransactionBundle(path);
    }

    function getGnosisTransactions() internal view returns (string memory) {
        string memory chainId = vm.toString(block.chainid);
        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory debtManagerCoreUpgrade = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, debtManagerCoreImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), debtManagerCoreUpgrade, "0", false)));

        string memory debtManagerAdminUpgrade = iToHex(abi.encodeWithSelector(DebtManagerCore.setAdminImpl.selector, debtManagerAdminImpl));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), debtManagerAdminUpgrade, "0", false)));

        string memory cashModuleCoreUpgrade = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashModuleCoreImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), cashModuleCoreUpgrade, "0", false)));

        string memory cashModuleSettersUpgrade = iToHex(abi.encodeWithSelector(CashModuleCore.setCashModuleSettersAddress.selector, cashModuleSettersImpl));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), cashModuleSettersUpgrade, "0", false)));

        string memory cashEventEmitterUpgrade = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashEventEmitterImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashEventEmitter), cashEventEmitterUpgrade, "0", false)));

        string memory setSettlementDispatcher = iToHex(abi.encodeWithSelector(CashModuleSetters.setSettlementDispatcher.selector, BinSponsor.PIX, address(pixSettlementDispatcherProxy)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), setSettlementDispatcher, "0", false)));

        string memory setLiquidAssetWithdrawQueue = iToHex(abi.encodeWithSelector(SettlementDispatcher.setLiquidAssetWithdrawQueue.selector, liquidUsd, liquidUsdBoringQueue));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(pixSettlementDispatcherProxy)), setLiquidAssetWithdrawQueue, "0", true)));

        return txs;
    }
}