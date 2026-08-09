// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { QqqxFeedDeployer } from "./DeployQqqxProdFeeds.s.sol";
import { DynamicReserveConfigLike, IAaveOracleLike, IHubConfiguratorLike, IHubLike, ISpokeConfiguratorLike, ISpokeLike, InterestRateDataLike, QqqxProd as C, ReserveConfigLike, ReserveLike, SpokeConfigLike } from "./QqqxProdConfig.sol";

/**
 * @title ListQqqxSummerLend3CP
 * @notice Generates the LEND OWNER SAFE (0x082B…E844) bundle that lists iwQQQx as a
 *         collateral-only reserve on the prod Summer Lend instance on Optimism. The Owner Safe
 *         holds the configurator domain-admin role (400), so every call goes through the
 *         Hub/Spoke configurators — the same path the wSPYx/PAXG listing used.
 *
 *         Three calls, mirroring the iwSPYx collateral-only house style (flat 0% curve, 0%
 *         liquidity fee, 10% liquidation fee, risk premium 0, receiveShares on):
 *           1. HubConfigurator.addAsset(iwQQQx)     — flat IR curve, treasury fee receiver
 *           2. HubConfigurator.addSpoke(Cash Spoke) — addCap 2000, drawCap 0, active
 *           3. SpokeConfigurator.addReserve         — CF 78%, max liquidation bonus 10%, on the
 *              DeployQqqxProdFeeds iwQQQx/USD feed
 *
 *         Asset and reserve ids are consumed from the live counters (sequential), then the whole
 *         bundle is fork-simulated and the post-state asserted before the JSON is trusted.
 *
 *         PREREQUISITE THAT IS FORK-ONLY HERE: unlike wSPYx/PAXG, neither the iwQQQx ShadowOFT
 *         nor a relayed wQQQx price exists anywhere yet — not even on a clean mainnet fork —
 *         because the cash-mainnet-asset-listing bundles that create them have not executed.
 *         `_rehearseQqqxRails()` stands both up on THIS fork, using the real factory/salt/sink, so
 *         `addReserve`'s live-price read below succeeds exactly as it will once the real rails
 *         land. It is fork-only: never called from a broadcast script, and its writes never
 *         become calldata in the bundle below.
 *
 *         EXECUTION ORDER: after DeployQqqxProdFeeds (the feeds must exist and price), and before
 *         the Operating Safe OP bundle (which registers the resulting reserve id on the
 *         LendGateway).
 *
 * Usage:
 *   forge script scripts/qqqx/ListQqqxSummerLend3CP.s.sol --rpc-url $OPTIMISM_RPC
 */
contract ListQqqxSummerLend3CP is GnosisHelpers, Test, QqqxFeedDeployer {
    string constant OUTPUT_PATH = "./output/ListQqqxSummerLend3CP-10.json";

    function run() public {
        require(block.chainid == 10, "must be Optimism");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        _rehearseQqqxRails(); // fork-only: iwQQQx + a relayed sink price must exist to price
        (, address iwqqqxFeed) = _deployFeeds(true);

        ISpokeLike spoke = ISpokeLike(C.CASH_SPOKE);
        IHubLike hub = IHubLike(C.CASH_HUB);
        require(_reserveIdOf(spoke, C.IWQQQX) == type(uint256).max, "iwQQQx already listed");

        // Ids are assigned sequentially from the live counters, in bundle call order
        uint256 assetId = hub.getAssetCount();
        uint256 reserveId = spoke.getReserveCount();

        _writeBundle(iwqqqxFeed, assetId);
        console.log("Written: %s", OUTPUT_PATH);

        executeGnosisTransactionBundle(OUTPUT_PATH);
        _assertPostState(spoke, hub, iwqqqxFeed, assetId, reserveId);

        console.log("Simulation passed.");
        console.log("  iwQQQx assetId %s, reserveId %s", assetId, reserveId);
        console.log("  iwQQQx / USD: %s (8 dec)", IAaveOracleLike(C.AAVE_ORACLE).getReservePrice(reserveId));
    }

    function _writeBundle(address iwqqqxFeed, uint256 assetId) internal {
        // Collateral-only house style: flat 0% curve, no borrow use case
        bytes memory irData = abi.encode(InterestRateDataLike({ optimalUsageRatio: 9900, baseDrawnRate: 0, rateGrowthBeforeOptimal: 0, rateGrowthAfterOptimal: 0 }));

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(C.LEND_OWNER_SAFE));

        txs = _append(txs, C.HUB_CONFIGURATOR, abi.encodeCall(IHubConfiguratorLike.addAsset, (C.CASH_HUB, C.IWQQQX, C.TREASURY_SPOKE, 0, C.IR_STRATEGY, irData)), false);
        txs = _append(txs, C.HUB_CONFIGURATOR, abi.encodeCall(IHubConfiguratorLike.addSpoke, (C.CASH_HUB, C.CASH_SPOKE, assetId, _spokeConfig())), false);
        txs = _append(txs, C.SPOKE_CONFIGURATOR, abi.encodeCall(ISpokeConfiguratorLike.addReserve, (C.CASH_SPOKE, C.CASH_HUB, assetId, iwqqqxFeed, _reserveConfig(), _dynamicConfig())), true);

        vm.createDir("./output", true);
        vm.writeFile(OUTPUT_PATH, txs);
    }

    function _assertPostState(ISpokeLike spoke, IHubLike hub, address iwqqqxFeed, uint256 assetId, uint256 reserveId) internal view {
        assertEq(hub.getAssetCount(), assetId + 1, "asset count");
        assertEq(spoke.getReserveCount(), reserveId + 1, "reserve count");
        assertEq(spoke.getReserveId(C.CASH_HUB, assetId), reserveId, "iwQQQx reserve id");

        ReserveLike memory reserve = spoke.getReserve(reserveId);
        assertEq(reserve.underlying, C.IWQQQX, "iwQQQx: underlying");
        assertEq(reserve.hub, C.CASH_HUB, "iwQQQx: hub");
        assertEq(uint256(reserve.assetId), assetId, "iwQQQx: assetId");
        assertEq(uint256(reserve.decimals), 18, "iwQQQx: decimals");

        ReserveConfigLike memory config = spoke.getReserveConfig(reserveId);
        assertEq(uint256(config.collateralRisk), C.LEND_COLLATERAL_RISK, "iwQQQx: collateralRisk");
        assertFalse(config.paused, "iwQQQx: paused");
        assertFalse(config.frozen, "iwQQQx: frozen");
        assertFalse(config.borrowable, "iwQQQx: borrowable");
        assertTrue(config.receiveSharesEnabled, "iwQQQx: receiveShares");

        DynamicReserveConfigLike memory dynamicConfig = spoke.getDynamicReserveConfig(reserveId, reserve.dynamicConfigKey);
        assertEq(uint256(dynamicConfig.collateralFactor), C.LEND_IWQQQX_COLLATERAL_FACTOR, "iwQQQx: collateralFactor");
        assertEq(uint256(dynamicConfig.maxLiquidationBonus), C.LEND_MAX_LIQUIDATION_BONUS, "iwQQQx: maxLiquidationBonus");
        assertEq(uint256(dynamicConfig.liquidationFee), C.LEND_LIQUIDATION_FEE, "iwQQQx: liquidationFee");

        assertEq(IAaveOracleLike(C.AAVE_ORACLE).getReserveSource(reserveId), iwqqqxFeed, "iwQQQx: price source");
        assertGt(IAaveOracleLike(C.AAVE_ORACLE).getReservePrice(reserveId), 0, "iwQQQx: live price");

        SpokeConfigLike memory spokeConfig = hub.getSpokeConfig(assetId, C.CASH_SPOKE);
        assertEq(uint256(spokeConfig.addCap), C.LEND_IWQQQX_ADD_CAP, "iwQQQx: addCap");
        assertEq(uint256(spokeConfig.drawCap), 0, "iwQQQx: drawCap");
        assertEq(uint256(spokeConfig.riskPremiumThreshold), 0, "iwQQQx: riskPremiumThreshold");
        assertTrue(spokeConfig.active, "iwQQQx: active");
        assertFalse(spokeConfig.halted, "iwQQQx: halted");
    }

    function _spokeConfig() internal pure returns (SpokeConfigLike memory) {
        return SpokeConfigLike({ addCap: C.LEND_IWQQQX_ADD_CAP, drawCap: 0, riskPremiumThreshold: 0, active: true, halted: false });
    }

    function _reserveConfig() internal pure returns (ReserveConfigLike memory) {
        return ReserveConfigLike({ collateralRisk: C.LEND_COLLATERAL_RISK, paused: false, frozen: false, borrowable: false, receiveSharesEnabled: true });
    }

    function _dynamicConfig() internal pure returns (DynamicReserveConfigLike memory) {
        return DynamicReserveConfigLike({ collateralFactor: C.LEND_IWQQQX_COLLATERAL_FACTOR, maxLiquidationBonus: C.LEND_MAX_LIQUIDATION_BONUS, liquidationFee: C.LEND_LIQUIDATION_FEE });
    }

    function _reserveIdOf(ISpokeLike spoke, address token) internal view returns (uint256) {
        uint256 count = spoke.getReserveCount();
        for (uint256 i; i < count; ++i) {
            if (spoke.getReserve(i).underlying == token) return i;
        }
        return type(uint256).max;
    }

    function _append(string memory txs, address to, bytes memory data, bool isLast) internal pure returns (string memory) {
        return string.concat(txs, _getGnosisTransaction(addressToHex(to), iToHex(data), "0", isLast));
    }
}
