// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {console} from "forge-std/console.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {SettlementDispatcher, BinSponsor} from "../src/settlement-dispatcher/SettlementDispatcher.sol";
import {SettlementDispatcherV2} from "../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import {Utils} from "./utils/Utils.sol";

/**
 * @title UpgradeSettlementDispatchersToV2
 * @notice Upgrades Reap, Rain, and Pix settlement dispatchers from V1 to V2,
 *         re-sets V1 destination data (V2 uses a different ERC-7201 storage slot),
 *         and configures Frax + Midas on all four dispatchers (including CardOrder which is already V2).
 *
 * @dev CRITICAL: V1 storage slot (etherfi.storage.SettlementDispatcher) differs from
 *      V2 storage slot (etherfi.storage.SettlementDispatcherV2). After upgrade, all V1
 *      config (destinationData, liquidWithdrawQueue) is inaccessible. This script reads
 *      V1 configs before upgrade and re-sets them on V2 afterward.
 *
 *      Run with:
 *        ENV=dev forge script scripts/UpgradeSettlementDispatchersToV2.s.sol \
 *          --rpc-url <SCROLL_RPC> --broadcast
 */
contract UpgradeSettlementDispatchersToV2 is Utils {

    // ═══════════════════════════════════════════════════════════════════════
    //  Tokens on Scroll
    // ═══════════════════════════════════════════════════════════════════════
    address constant USDC_SCROLL = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    address constant USDT_SCROLL = 0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df;

    // ═══════════════════════════════════════════════════════════════════════
    //  Frax infrastructure
    // ═══════════════════════════════════════════════════════════════════════
    address constant FRAX_USD            = 0x397F939C3b91A74C321ea7129396492bA9Cdce82;
    address constant FRAX_CUSTODIAN      = 0x05bF905356fbeA7E59500f904b908402dB7A53DD;
    address constant FRAX_REMOTE_HOP     = 0xF6f45CCB5E85D1400067ee66F9e168f83e86124E;
    address constant FRAX_DEPOSIT_ADDRESS_REAP       = 0x8ff130cF5d1e7D055592a978bc68e0C0ff2A3A6f;
    address constant FRAX_DEPOSIT_ADDRESS_RAIN       = 0x812174A1662Ddf543EB9ABE17687Ed539F859019;
    address constant FRAX_DEPOSIT_ADDRESS_PIX        = 0xcb9d8F5D048046A69594A552d468215EbBEb088b;
    address constant FRAX_DEPOSIT_ADDRESS_CARD_ORDER = 0x4C7fc68F658a51a196a4937bf9dacE86fe978e81;

    // ═══════════════════════════════════════════════════════════════════════
    //  Midas infrastructure
    // ═══════════════════════════════════════════════════════════════════════
    address constant MIDAS_LR               = 0xb7Fb3768CAAC98354EaDF514b48f28F2fE822bF0;
    address constant MIDAS_REDEMPTION_VAULT = 0x904EA8d7FcaB7351758fAC82bDbc738E2010BC25;

    // ═══════════════════════════════════════════════════════════════════════
    //  Liquid token (for liquidWithdrawQueue re-set)
    // ═══════════════════════════════════════════════════════════════════════
    address constant LIQUID_USD = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;

    // ═══════════════════════════════════════════════════════════════════════
    //  Expected V1 destination data (hardcoded for validation)
    //  Reap & Rain: USDC + USDT via canonical bridge
    // ═══════════════════════════════════════════════════════════════════════
    address constant EXPECTED_REAP_RAIN_DEST_RECIPIENT = address(0); // TODO: fill in the settlement address for dev env

    // Pix: TODO - fill in expected destination recipient and tokens
    // address constant EXPECTED_PIX_DEST_RECIPIENT = address(0);

    // ═══════════════════════════════════════════════════════════════════════
    //  Structs to reduce stack depth
    // ═══════════════════════════════════════════════════════════════════════

    struct Proxies {
        address reap;
        address rain;
        address pix;
        address cardOrder;
        address dataProvider;
    }

    struct V1Data {
        SettlementDispatcher.DestinationData usdc;
        SettlementDispatcher.DestinationData usdt;
        SettlementDispatcher.DestinationData liquidUsd;
        address liquidUsdQueue;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Entry point
    // ═══════════════════════════════════════════════════════════════════════

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        Proxies memory p = _loadProxies();

        // ── Read V1 configs from chain (before upgrade) ─────────────────
        console.log("Reading V1 destination data before upgrade...");
        V1Data memory reapV1 = _readV1Data(p.reap);
        V1Data memory rainV1 = _readV1Data(p.rain);
        V1Data memory pixV1  = _readV1Data(p.pix);

        // ══════════════════════════════════════════════════════════════════
        //  BROADCAST: all following calls execute on-chain
        // ══════════════════════════════════════════════════════════════════
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer address:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        _deployAndUpgrade(p);
        _resetDestinationData(p, reapV1, rainV1, pixV1);
        _configureFrax(p);
        _configureMidas(p);
        _resetLiquidWithdrawQueues(p, reapV1, rainV1, pixV1);

        vm.stopBroadcast();

        // ══════════════════════════════════════════════════════════════════
        //  POST-UPGRADE VERIFICATION (runs against simulated fork state)
        // ══════════════════════════════════════════════════════════════════
        _verifyAll(p, reapV1, rainV1, pixV1);

        console.log("All post-upgrade verifications passed");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Phase helpers
    // ═══════════════════════════════════════════════════════════════════════

    function _loadProxies() internal returns (Proxies memory p) {
        string memory deployments = readDeploymentFile();

        p.reap        = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherReap");
        p.rain        = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherRain");
        p.pix         = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherPix");
        p.cardOrder   = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherCardOrder");
        p.dataProvider = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");

        require(p.reap != address(0), "Invalid reapProxy");
        require(p.rain != address(0), "Invalid rainProxy");
        require(p.pix != address(0), "Invalid pixProxy");
        require(p.cardOrder != address(0), "Invalid cardOrderProxy");
        require(p.dataProvider != address(0), "Invalid dataProvider");
    }

    function _readV1Data(address proxy) internal view returns (V1Data memory d) {
        d.usdc      = SettlementDispatcher(payable(proxy)).destinationData(USDC_SCROLL);
        d.usdt      = SettlementDispatcher(payable(proxy)).destinationData(USDT_SCROLL);
        d.liquidUsd = SettlementDispatcher(payable(proxy)).destinationData(LIQUID_USD);
        d.liquidUsdQueue = SettlementDispatcher(payable(proxy)).getLiquidAssetWithdrawQueue(LIQUID_USD);
    }

    /// @dev Deploys V2 implementations and upgrades all 4 proxies.
    function _deployAndUpgrade(Proxies memory p) internal {
        address reapV2Impl      = address(new SettlementDispatcherV2(BinSponsor.Reap, p.dataProvider));
        address rainV2Impl      = address(new SettlementDispatcherV2(BinSponsor.Rain, p.dataProvider));
        address pixV2Impl       = address(new SettlementDispatcherV2(BinSponsor.PIX, p.dataProvider));
        address cardOrderV2Impl = address(new SettlementDispatcherV2(BinSponsor.CardOrder, p.dataProvider));

        UUPSUpgradeable(p.reap).upgradeToAndCall(reapV2Impl, "");
        UUPSUpgradeable(p.rain).upgradeToAndCall(rainV2Impl, "");
        UUPSUpgradeable(p.pix).upgradeToAndCall(pixV2Impl, "");
        UUPSUpgradeable(p.cardOrder).upgradeToAndCall(cardOrderV2Impl, "");

        console.log("Proxies upgraded to V2");
    }

    /// @dev Re-sets V1 destination data on V2 (lost due to storage slot change).
    function _resetDestinationData(
        Proxies memory p,
        V1Data memory reapV1,
        V1Data memory rainV1,
        V1Data memory pixV1
    ) internal {
        _setV2DestinationData(p.reap, reapV1);
        _setV2DestinationData(p.rain, rainV1);
        _setV2DestinationData(p.pix, pixV1);

        console.log("Destination data re-set on V2");
    }

    /// @dev Sets Frax config on all 4 dispatchers.
    function _configureFrax(Proxies memory p) internal {
        SettlementDispatcherV2(payable(p.reap)).setFraxConfig(FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_ADDRESS_REAP);
        SettlementDispatcherV2(payable(p.rain)).setFraxConfig(FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_ADDRESS_RAIN);
        SettlementDispatcherV2(payable(p.pix)).setFraxConfig(FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_ADDRESS_PIX);
        SettlementDispatcherV2(payable(p.cardOrder)).setFraxConfig(FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_ADDRESS_CARD_ORDER);

        console.log("Frax config set on all 4 dispatchers");
    }

    /// @dev Sets Midas redemption vault on all 4 dispatchers.
    function _configureMidas(Proxies memory p) internal {
        SettlementDispatcherV2(payable(p.reap)).setMidasRedemptionVault(MIDAS_LR, MIDAS_REDEMPTION_VAULT);
        SettlementDispatcherV2(payable(p.rain)).setMidasRedemptionVault(MIDAS_LR, MIDAS_REDEMPTION_VAULT);
        SettlementDispatcherV2(payable(p.pix)).setMidasRedemptionVault(MIDAS_LR, MIDAS_REDEMPTION_VAULT);
        SettlementDispatcherV2(payable(p.cardOrder)).setMidasRedemptionVault(MIDAS_LR, MIDAS_REDEMPTION_VAULT);

        console.log("Midas redemption vault set on all 4 dispatchers");
    }

    /// @dev Re-sets liquidWithdrawQueue for LIQUID_USD (lost due to storage slot change).
    function _resetLiquidWithdrawQueues(
        Proxies memory p,
        V1Data memory reapV1,
        V1Data memory rainV1,
        V1Data memory pixV1
    ) internal {
        if (reapV1.liquidUsdQueue != address(0)) {
            SettlementDispatcherV2(payable(p.reap)).setLiquidAssetWithdrawQueue(LIQUID_USD, reapV1.liquidUsdQueue);
        }
        if (rainV1.liquidUsdQueue != address(0)) {
            SettlementDispatcherV2(payable(p.rain)).setLiquidAssetWithdrawQueue(LIQUID_USD, rainV1.liquidUsdQueue);
        }
        if (pixV1.liquidUsdQueue != address(0)) {
            SettlementDispatcherV2(payable(p.pix)).setLiquidAssetWithdrawQueue(LIQUID_USD, pixV1.liquidUsdQueue);
        }
        if (reapV1.liquidUsdQueue != address(0)) {
            SettlementDispatcherV2(payable(p.cardOrder)).setLiquidAssetWithdrawQueue(LIQUID_USD, reapV1.liquidUsdQueue);
        }

        console.log("LiquidWithdrawQueue for LIQUID_USD re-set on all dispatchers");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Verification
    // ═══════════════════════════════════════════════════════════════════════

    function _verifyAll(
        Proxies memory p,
        V1Data memory reapV1,
        V1Data memory rainV1,
        V1Data memory pixV1
    ) internal view {
        console.log("Verifying post-upgrade state...");

        // Verify destination data was re-set correctly
        _verifyDestinationData("Reap", p.reap, reapV1);
        _verifyDestinationData("Rain", p.rain, rainV1);
        _verifyDestinationData("Pix", p.pix, pixV1);

        // Verify Frax config on all 4 dispatchers
        _verifyFraxConfig("Reap", p.reap, FRAX_DEPOSIT_ADDRESS_REAP);
        _verifyFraxConfig("Rain", p.rain, FRAX_DEPOSIT_ADDRESS_RAIN);
        _verifyFraxConfig("Pix", p.pix, FRAX_DEPOSIT_ADDRESS_PIX);
        _verifyFraxConfig("CardOrder", p.cardOrder, FRAX_DEPOSIT_ADDRESS_CARD_ORDER);

        // Verify Midas redemption vault on all 4 dispatchers
        _verifyMidasConfig("Reap", p.reap);
        _verifyMidasConfig("Rain", p.rain);
        _verifyMidasConfig("Pix", p.pix);
        _verifyMidasConfig("CardOrder", p.cardOrder);

        // Verify liquidWithdrawQueue for LIQUID_USD on all dispatchers
        _verifyLiquidWithdrawQueue("Reap", p.reap, reapV1.liquidUsdQueue);
        _verifyLiquidWithdrawQueue("Rain", p.rain, rainV1.liquidUsdQueue);
        _verifyLiquidWithdrawQueue("Pix", p.pix, pixV1.liquidUsdQueue);
        if (reapV1.liquidUsdQueue != address(0)) {
            _verifyLiquidWithdrawQueue("CardOrder", p.cardOrder, reapV1.liquidUsdQueue);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Internal helpers
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Converts V1 destination data for USDC and USDT, then sets on the V2 proxy.
    function _setV2DestinationData(address proxy, V1Data memory v1) internal {
        address[] memory tokens = new address[](2);
        SettlementDispatcherV2.DestinationData[] memory destDatas = new SettlementDispatcherV2.DestinationData[](2);

        tokens[0] = USDC_SCROLL;
        tokens[1] = USDT_SCROLL;

        destDatas[0] = SettlementDispatcherV2.DestinationData({
            destEid: v1.usdc.destEid,
            destRecipient: v1.usdc.destRecipient,
            stargate: v1.usdc.stargate,
            useCanonicalBridge: v1.usdc.useCanonicalBridge,
            minGasLimit: v1.usdc.minGasLimit
        });

        destDatas[1] = SettlementDispatcherV2.DestinationData({
            destEid: v1.usdt.destEid,
            destRecipient: v1.usdt.destRecipient,
            stargate: v1.usdt.stargate,
            useCanonicalBridge: v1.usdt.useCanonicalBridge,
            minGasLimit: v1.usdt.minGasLimit
        });

        SettlementDispatcherV2(payable(proxy)).setDestinationData(tokens, destDatas);
    }

    /// @dev Logs a DestinationData struct for debugging.
    function _logDestinationData(string memory label, SettlementDispatcher.DestinationData memory data) internal pure {
        console.log(string.concat(label, ":"));
        console.log("  destRecipient:", data.destRecipient);
        console.log("  useCanonicalBridge:", data.useCanonicalBridge);
        console.log("  destEid:", uint256(data.destEid));
        console.log("  stargate:", data.stargate);
        console.log("  minGasLimit:", uint256(data.minGasLimit));
    }

    /// @dev Verifies V2 destination data matches the original V1 values.
    function _verifyDestinationData(
        string memory name,
        address proxy,
        V1Data memory v1
    ) internal view {
        SettlementDispatcherV2 v2 = SettlementDispatcherV2(payable(proxy));

        SettlementDispatcherV2.DestinationData memory actualUsdc = v2.destinationData(USDC_SCROLL);
        require(actualUsdc.destRecipient == v1.usdc.destRecipient, string.concat(name, " USDC: destRecipient mismatch"));
        require(actualUsdc.useCanonicalBridge == v1.usdc.useCanonicalBridge, string.concat(name, " USDC: useCanonicalBridge mismatch"));
        require(actualUsdc.destEid == v1.usdc.destEid, string.concat(name, " USDC: destEid mismatch"));
        require(actualUsdc.stargate == v1.usdc.stargate, string.concat(name, " USDC: stargate mismatch"));
        require(actualUsdc.minGasLimit == v1.usdc.minGasLimit, string.concat(name, " USDC: minGasLimit mismatch"));

        SettlementDispatcherV2.DestinationData memory actualUsdt = v2.destinationData(USDT_SCROLL);
        require(actualUsdt.destRecipient == v1.usdt.destRecipient, string.concat(name, " USDT: destRecipient mismatch"));
        require(actualUsdt.useCanonicalBridge == v1.usdt.useCanonicalBridge, string.concat(name, " USDT: useCanonicalBridge mismatch"));
        require(actualUsdt.destEid == v1.usdt.destEid, string.concat(name, " USDT: destEid mismatch"));
        require(actualUsdt.stargate == v1.usdt.stargate, string.concat(name, " USDT: stargate mismatch"));
        require(actualUsdt.minGasLimit == v1.usdt.minGasLimit, string.concat(name, " USDT: minGasLimit mismatch"));

        console.log(string.concat("  ", name, " destination data: OK"));
    }

    /// @dev Verifies Frax config was set correctly on a V2 dispatcher.
    function _verifyFraxConfig(string memory name, address proxy, address expectedDepositAddress) internal view {
        SettlementDispatcherV2 v2 = SettlementDispatcherV2(payable(proxy));
        (address fraxUsd_, address fraxCustodian_, address fraxRemoteHop_, address fraxAsyncRedeemRecipient_) = v2.getFraxConfig();

        require(fraxUsd_ == FRAX_USD, string.concat(name, ": fraxUsd mismatch"));
        require(fraxCustodian_ == FRAX_CUSTODIAN, string.concat(name, ": fraxCustodian mismatch"));
        require(fraxRemoteHop_ == FRAX_REMOTE_HOP, string.concat(name, ": fraxRemoteHop mismatch"));
        require(fraxAsyncRedeemRecipient_ == expectedDepositAddress, string.concat(name, ": fraxAsyncRedeemRecipient mismatch"));

        console.log(string.concat("  ", name, " Frax config: OK"));
    }

    /// @dev Verifies Midas redemption vault was set correctly on a V2 dispatcher.
    function _verifyMidasConfig(string memory name, address proxy) internal view {
        SettlementDispatcherV2 v2 = SettlementDispatcherV2(payable(proxy));
        address vault = v2.getMidasRedemptionVault(MIDAS_LR);

        require(vault == MIDAS_REDEMPTION_VAULT, string.concat(name, ": Midas redemption vault mismatch"));

        console.log(string.concat("  ", name, " Midas config: OK"));
    }

    /// @dev Verifies liquidWithdrawQueue for LIQUID_USD was set correctly on a V2 dispatcher.
    function _verifyLiquidWithdrawQueue(string memory name, address proxy, address expectedQueue) internal view {
        SettlementDispatcherV2 v2 = SettlementDispatcherV2(payable(proxy));
        address actualQueue = v2.getLiquidAssetWithdrawQueue(LIQUID_USD);

        require(actualQueue == expectedQueue, string.concat(name, ": LIQUID_USD withdraw queue mismatch"));

        console.log(string.concat("  ", name, " LIQUID_USD withdraw queue: OK"));
    }
}
