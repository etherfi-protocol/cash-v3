// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { SettlementDispatcherV2 } from "../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract UpgradeSettlementDispatcherV2 is Utils, GnosisHelpers {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    // Implementation addresses
    address constant reapImpl = 0xAc52B92C9B3c131B233B747cDfa15e5ec3013Fb2;
    address constant rainImpl = 0x6B7Db0886A7e9F95E3d39630A42456eeF8439119;
    address constant pixImpl = 0xa3b882edc0c9D31A311f1d59b97E21823d40a0d6;
    address constant cardOrderImpl = 0xa93AA25303a2DF853eaAB6ffD46F08D60002B4b9;

    // Frax infrastructure
    address constant FRAX_USD              = 0x397F939C3b91A74C321ea7129396492bA9Cdce82;
    address constant FRAX_CUSTODIAN        = 0x05bF905356fbeA7E59500f904b908402dB7A53DD;
    address constant FRAX_REMOTE_HOP       = 0xF6f45CCB5E85D1400067ee66F9e168f83e86124E;
    address constant FRAX_DEPOSIT_ADDRESS_REAP       = 0x8ff130cF5d1e7D055592a978bc68e0C0ff2A3A6f;
    address constant FRAX_DEPOSIT_ADDRESS_RAIN       = 0x812174A1662Ddf543EB9ABE17687Ed539F859019;
    address constant FRAX_DEPOSIT_ADDRESS_PIX        = 0xcb9d8F5D048046A69594A552d468215EbBEb088b;
    address constant FRAX_DEPOSIT_ADDRESS_CARD_ORDER = 0x4C7fc68F658a51a196a4937bf9dacE86fe978e81;

    // Midas infrastructure
    address constant MIDAS_LR               = 0xb7Fb3768CAAC98354EaDF514b48f28F2fE822bF0;
    address constant MIDAS_REDEMPTION_VAULT = 0x904EA8d7FcaB7351758fAC82bDbc738E2010BC25;

    function run() public {
        string memory deployments = readDeploymentFile();
        string memory chainId = vm.toString(block.chainid);

        address reapProxy = stdJson.readAddress(deployments, string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcherReap")));
        address rainProxy = stdJson.readAddress(deployments, string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcherRain")));
        address pixProxy = stdJson.readAddress(deployments, string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcherPix")));
        address cardOrderProxy = stdJson.readAddress(deployments, string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcherCardOrder")));

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory upgradeData;

        upgradeData = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, reapImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(reapProxy), upgradeData, "0", false)));

        upgradeData = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, rainImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(rainProxy), upgradeData, "0", false)));

        upgradeData = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, pixImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(pixProxy), upgradeData, "0", false)));

        upgradeData = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cardOrderImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cardOrderProxy), upgradeData, "0", false)));

        // Set Frax config on each proxy
        string memory fraxData;

        fraxData = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setFraxConfig.selector, FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_ADDRESS_REAP));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(reapProxy), fraxData, "0", false)));

        fraxData = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setFraxConfig.selector, FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_ADDRESS_RAIN));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(rainProxy), fraxData, "0", false)));

        fraxData = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setFraxConfig.selector, FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_ADDRESS_PIX));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(pixProxy), fraxData, "0", false)));

        fraxData = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setFraxConfig.selector, FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_ADDRESS_CARD_ORDER));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cardOrderProxy), fraxData, "0", false)));

        // Set Midas redemption vault on each proxy
        string memory midasData = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setMidasRedemptionVault.selector, MIDAS_LR, MIDAS_REDEMPTION_VAULT));

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(reapProxy), midasData, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(rainProxy), midasData, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(pixProxy), midasData, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cardOrderProxy), midasData, "0", true)));

        string memory path = string.concat("./output/UpgradeSettlementDispatcherV2-", chainId, ".json");
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);
    }
}
