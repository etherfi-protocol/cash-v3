// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { SettlementDispatcher } from "../../src/settlement-dispatcher/SettlementDispatcher.sol";
import { SettlementDispatcherV2 } from "../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract UpgradeSettlementDispatcherV2 is Utils, GnosisHelpers, StdCheats {
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
    // Generated using the Frax API
    address constant FRAX_DEPOSIT_ADDRESS_REAP       = 0x0eD8993b5c9A707bfe0a04644B1C44456a61987D;
    address constant FRAX_DEPOSIT_ADDRESS_RAIN       = 0x2D4f918E4020C79DE6284CFa46b8310FFf41B736;
    address constant FRAX_DEPOSIT_ADDRESS_PIX        = 0x73880079a2660c1CBea7703436CD01ACD40492Ee;
    address constant FRAX_DEPOSIT_ADDRESS_CARD_ORDER = 0x5fC3bA932482f93503f0f7eB558Af2eC9e44f3F2;

    // Midas infrastructure
    address constant MIDAS_LR               = 0xb7Fb3768CAAC98354EaDF514b48f28F2fE822bF0;
    address constant MIDAS_REDEMPTION_VAULT = 0x904EA8d7FcaB7351758fAC82bDbc738E2010BC25;

    // Tokens on Scroll
    address constant USDC_SCROLL = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    address constant USDT_SCROLL = 0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df;

    // Liquid USD withdraw queue
    address constant LIQUID_USD              = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address constant LIQUID_USD_BORING_QUEUE = 0x38FC1BA73b7ED289955a07d9F11A85b6E388064A;

    // V1 destination recipients (re-set after upgrade since V2 uses a different storage slot)
    address constant REAP_RAIN_DEST_RECIPIENT = 0x6f7F522075AA5483d049dF0Ef81FcdD3b0ace7f4;
    address constant PIX_USDC_DEST_RECIPIENT  = 0xf76f1bea29b5f63409a9d9797540A8E7934B52ea;

    function run() public {
        string memory deployments = readDeploymentFile();
        string memory chainId = vm.toString(block.chainid);

        address reapProxy = stdJson.readAddress(deployments, string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcherReap")));
        address rainProxy = stdJson.readAddress(deployments, string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcherRain")));
        address pixProxy = stdJson.readAddress(deployments, string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcherPix")));
        address cardOrderProxy = stdJson.readAddress(deployments, string(abi.encodePacked(".", "addresses", ".", "SettlementDispatcherCardOrder")));

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        txs = _addUpgradeTransactions(txs, reapProxy, rainProxy, pixProxy, cardOrderProxy);
        txs = _addFraxConfigTransactions(txs, reapProxy, rainProxy, pixProxy, cardOrderProxy);
        txs = _addMidasConfigTransactions(txs, reapProxy, rainProxy, pixProxy, cardOrderProxy);


        // Verify hardcoded V1 configs match on-chain state before we re-set them after upgrade
        _verifyV1Configs(reapProxy, rainProxy, pixProxy);

        // Re-set destination data + liquid queue (V2 uses a different storage slot so V1 data is lost)
        txs = _addDestinationDataTransactions(txs, reapProxy, rainProxy, pixProxy);
        txs = _addLiquidWithdrawQueueTransactions(txs, reapProxy, rainProxy, pixProxy, cardOrderProxy);

        string memory path = string.concat("./output/UpgradeSettlementDispatcherV2-", chainId, ".json");
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);

        _smokeTestRainDispatcher(rainProxy, cardOrderProxy);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Transaction builders
    // ═══════════════════════════════════════════════════════════════════════

    function _addUpgradeTransactions(
        string memory txs,
        address reapProxy,
        address rainProxy,
        address pixProxy,
        address cardOrderProxy
    ) internal pure returns (string memory) {
        string memory upgradeData;

        upgradeData = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, reapImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(reapProxy), upgradeData, "0", false)));

        upgradeData = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, rainImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(rainProxy), upgradeData, "0", false)));

        upgradeData = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, pixImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(pixProxy), upgradeData, "0", false)));

        upgradeData = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cardOrderImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cardOrderProxy), upgradeData, "0", false)));

        return txs;
    }

    function _addDestinationDataTransactions(
        string memory txs,
        address reapProxy,
        address rainProxy,
        address pixProxy
    ) internal pure returns (string memory) {
        // Reap & Rain share the same dest recipient for both USDC and USDT
        string memory reapRainDestData = iToHex(abi.encodeWithSelector(
            SettlementDispatcherV2.setDestinationData.selector,
            _tokenPair(),
            _destDataPair(REAP_RAIN_DEST_RECIPIENT, REAP_RAIN_DEST_RECIPIENT)
        ));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(reapProxy), reapRainDestData, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(rainProxy), reapRainDestData, "0", false)));

        // Pix has a different USDC recipient but same USDT recipient
        string memory pixDestData = iToHex(abi.encodeWithSelector(
            SettlementDispatcherV2.setDestinationData.selector,
            _tokenPair(),
            _destDataPair(PIX_USDC_DEST_RECIPIENT, REAP_RAIN_DEST_RECIPIENT)
        ));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(pixProxy), pixDestData, "0", false)));

        return txs;
    }

    function _addLiquidWithdrawQueueTransactions(
        string memory txs,
        address reapProxy,
        address rainProxy,
        address pixProxy,
        address cardOrderProxy
    ) internal pure returns (string memory) {
        string memory queueData = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setLiquidAssetWithdrawQueue.selector, LIQUID_USD, LIQUID_USD_BORING_QUEUE));

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(reapProxy), queueData, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(rainProxy), queueData, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(pixProxy), queueData, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cardOrderProxy), queueData, "0", true)));

        return txs;
    }

    function _addFraxConfigTransactions(
        string memory txs,
        address reapProxy,
        address rainProxy,
        address pixProxy,
        address cardOrderProxy
    ) internal pure returns (string memory) {
        string memory fraxData;

        fraxData = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setFraxConfig.selector, FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_ADDRESS_REAP));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(reapProxy), fraxData, "0", false)));

        fraxData = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setFraxConfig.selector, FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_ADDRESS_RAIN));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(rainProxy), fraxData, "0", false)));

        fraxData = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setFraxConfig.selector, FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_ADDRESS_PIX));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(pixProxy), fraxData, "0", false)));

        fraxData = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setFraxConfig.selector, FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_ADDRESS_CARD_ORDER));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cardOrderProxy), fraxData, "0", false)));

        return txs;
    }

    function _addMidasConfigTransactions(
        string memory txs,
        address reapProxy,
        address rainProxy,
        address pixProxy,
        address cardOrderProxy
    ) internal pure returns (string memory) {
        string memory midasData = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setMidasRedemptionVault.selector, MIDAS_LR, MIDAS_REDEMPTION_VAULT));

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(reapProxy), midasData, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(rainProxy), midasData, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(pixProxy), midasData, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cardOrderProxy), midasData, "0", false)));

        return txs;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Pre-upgrade verification
    // ═══════════════════════════════════════════════════════════════════════

    function _verifyV1Configs(address reapProxy, address rainProxy, address pixProxy) internal view {
        _verifyV1DestData("Reap", reapProxy, REAP_RAIN_DEST_RECIPIENT, REAP_RAIN_DEST_RECIPIENT);
        _verifyV1DestData("Rain", rainProxy, REAP_RAIN_DEST_RECIPIENT, REAP_RAIN_DEST_RECIPIENT);
        _verifyV1DestData("Pix", pixProxy, PIX_USDC_DEST_RECIPIENT, REAP_RAIN_DEST_RECIPIENT);

        _verifyV1LiquidQueue("Reap", reapProxy);
        _verifyV1LiquidQueue("Rain", rainProxy);
        _verifyV1LiquidQueue("Pix", pixProxy);
    }

    function _verifyV1DestData(string memory name, address proxy, address expectedUsdcRecipient, address expectedUsdtRecipient) internal view {
        SettlementDispatcher sd = SettlementDispatcher(payable(proxy));

        SettlementDispatcher.DestinationData memory usdc = sd.destinationData(USDC_SCROLL);
        require(usdc.destRecipient == expectedUsdcRecipient, string.concat(name, ": USDC destRecipient mismatch"));
        require(usdc.useCanonicalBridge == true, string.concat(name, ": USDC useCanonicalBridge mismatch"));

        SettlementDispatcher.DestinationData memory usdt = sd.destinationData(USDT_SCROLL);
        require(usdt.destRecipient == expectedUsdtRecipient, string.concat(name, ": USDT destRecipient mismatch"));
        require(usdt.useCanonicalBridge == true, string.concat(name, ": USDT useCanonicalBridge mismatch"));
    }

    function _verifyV1LiquidQueue(string memory name, address proxy) internal view {
        SettlementDispatcher sd = SettlementDispatcher(payable(proxy));
        address queue = sd.getLiquidAssetWithdrawQueue(LIQUID_USD);
        require(queue == LIQUID_USD_BORING_QUEUE, string.concat(name, ": LIQUID_USD withdraw queue mismatch"));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Post-upgrade smoke tests (Rain dispatcher, one of each bridger op)
    // ═══════════════════════════════════════════════════════════════════════

    function _smokeTestRainDispatcher(address rainProxy, address cardOrderProxy) internal {
        SettlementDispatcherV2 rain = SettlementDispatcherV2(payable(rainProxy));
        SettlementDispatcherV2 cardOrder = SettlementDispatcherV2(payable(cardOrderProxy));

        address bridger = address(0xBEEF);
        IRoleRegistry roleReg = rain.roleRegistry();
        bytes32 bridgerRole = rain.SETTLEMENT_DISPATCHER_BRIDGER_ROLE();
        vm.prank(roleReg.owner());
        roleReg.grantRole(bridgerRole, bridger);

        // 1. bridge USDC via canonical bridge
        deal(USDC_SCROLL, rainProxy, 100e6);
        vm.prank(bridger);
        rain.bridge(USDC_SCROLL, 100e6, 0);

        // 2. transferFundsToRefundWallet
        deal(USDC_SCROLL, rainProxy, 100e6);
        vm.prank(bridger);
        rain.transferFundsToRefundWallet(USDC_SCROLL, 100e6);
        // transferFundsToRefundWallet (card order)
        deal(USDC_SCROLL, cardOrderProxy, 100e6);
        vm.prank(bridger);
        cardOrder.transferFundsToRefundWallet(USDC_SCROLL, 10e6);

        // 3. redeemFraxToUsdc (sync)
        deal(FRAX_USD, rainProxy, 100e18);
        deal(USDC_SCROLL, FRAX_CUSTODIAN, 200e6);
        vm.prank(bridger);
        rain.redeemFraxToUsdc(100e18, 0);

        // 4. redeemFraxAsync (via LayerZero OFT)
        deal(FRAX_USD, rainProxy, 100e18);
        vm.deal(rainProxy, 1 ether);
        vm.prank(bridger);
        rain.redeemFraxAsync(100e18);

        // 5. redeemMidasToAsset
        deal(MIDAS_LR, rainProxy, 100e18);
        vm.prank(bridger);
        rain.redeemMidasToAsset(MIDAS_LR, USDC_SCROLL, 100e18, 0);

        // 6. withdrawLiquidAsset
        deal(LIQUID_USD, rainProxy, 100e18);
        vm.prank(bridger);
        rain.withdrawLiquidAsset(LIQUID_USD, USDC_SCROLL, 100e18, 0, 0, 604800);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════════════

    function _tokenPair() internal pure returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = USDC_SCROLL;
        tokens[1] = USDT_SCROLL;
    }

    function _destDataPair(address usdcRecipient, address usdtRecipient) internal pure returns (SettlementDispatcherV2.DestinationData[] memory destDatas) {
        destDatas = new SettlementDispatcherV2.DestinationData[](2);
        destDatas[0] = SettlementDispatcherV2.DestinationData({
            destEid: 0,
            destRecipient: usdcRecipient,
            stargate: address(0),
            useCanonicalBridge: true,
            minGasLimit: 0
        });
        destDatas[1] = SettlementDispatcherV2.DestinationData({
            destEid: 0,
            destRecipient: usdtRecipient,
            stargate: address(0),
            useCanonicalBridge: true,
            minGasLimit: 0
        });
    }
}
