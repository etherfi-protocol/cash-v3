// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { WspyxPaxgFeedDeployer } from "./DeployWspyxPaxgProdFeeds.s.sol";
import {
    DynamicReserveConfigLike,
    IAaveOracleLike,
    IHubConfiguratorLike,
    IHubLike,
    ISpokeConfiguratorLike,
    ISpokeLike,
    InterestRateDataLike,
    ReserveConfigLike,
    ReserveLike,
    SpokeConfigLike,
    WspyxPaxgProd as C
} from "./WspyxPaxgProdConfig.sol";

/**
 * @title ListWspyxPaxgSummerLend3CP
 * @notice Generates the LEND OWNER SAFE (0x082B…E844) bundle that lists iwSPYx and iPAXG as
 *         collateral-only reserves on the prod Summer Lend instance on Optimism. The Owner Safe
 *         holds the configurator domain-admin role (400), so every call goes through the
 *         Hub/Spoke configurators — the same path as the CAPO reserve-source batch.
 *
 *         Six calls, mirroring the launch payload's collateral-only house style (flat 0% curve,
 *         0% liquidity fee, 10% liquidation fee, risk premium 0, receiveShares on):
 *           1-2. HubConfigurator.addAsset(iwSPYx / iPAXG)   — flat IR curve, treasury fee receiver
 *           3-4. HubConfigurator.addSpoke(Cash Spoke)       — addCap 2000 / 300, drawCap 0, active
 *           5-6. SpokeConfigurator.addReserve               — iwSPYx CF 78% / iPAXG CF 80%,
 *                max liquidation bonus 10%, on the DeployWspyxPaxgProdFeeds price feeds
 *
 *         Asset and reserve ids are consumed from the live counters (sequential), then the whole
 *         bundle is fork-simulated and the post-state asserted before the JSON is trusted.
 *
 *         EXECUTION ORDER: after DeployWspyxPaxgProdFeeds (the feeds must exist and price), and
 *         before the Operating Safe OP bundle (which registers the resulting reserve ids on the
 *         LendGateway).
 *
 * Usage:
 *   forge script scripts/wspyx-paxg/ListWspyxPaxgSummerLend3CP.s.sol --rpc-url $OPTIMISM_RPC
 */
contract ListWspyxPaxgSummerLend3CP is GnosisHelpers, Test, WspyxPaxgFeedDeployer {
    string constant OUTPUT_PATH = "./output/ListWspyxPaxgSummerLend3CP-10.json";

    function run() public {
        require(block.chainid == 10, "must be Optimism");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        (address iwspyxFeed, address paxgFeed) = _feeds();

        ISpokeLike spoke = ISpokeLike(C.CASH_SPOKE);
        IHubLike hub = IHubLike(C.CASH_HUB);
        require(_reserveIdOf(spoke, C.IWSPYX) == type(uint256).max, "iwSPYx already listed");
        require(_reserveIdOf(spoke, C.IPAXG) == type(uint256).max, "iPAXG already listed");

        // Ids are assigned sequentially from the live counters, in bundle call order
        uint256 iwspyxAssetId = hub.getAssetCount();
        uint256 paxgAssetId = iwspyxAssetId + 1;
        uint256 iwspyxReserveId = spoke.getReserveCount();
        uint256 paxgReserveId = iwspyxReserveId + 1;

        _writeBundle(iwspyxFeed, paxgFeed, iwspyxAssetId, paxgAssetId);
        console.log("Written: %s", OUTPUT_PATH);

        executeGnosisTransactionBundle(OUTPUT_PATH);
        _assertPostState(spoke, hub, iwspyxFeed, paxgFeed, iwspyxAssetId, paxgAssetId, iwspyxReserveId, paxgReserveId);

        console.log("Simulation passed.");
        console.log("  iwSPYx assetId %s, reserveId %s", iwspyxAssetId, iwspyxReserveId);
        console.log("  iPAXG  assetId %s, reserveId %s", paxgAssetId, paxgReserveId);
        console.log("  iwSPYx / USD: %s (8 dec)", IAaveOracleLike(C.AAVE_ORACLE).getReservePrice(iwspyxReserveId));
        console.log("  iPAXG  / USD: %s (8 dec)", IAaveOracleLike(C.AAVE_ORACLE).getReservePrice(paxgReserveId));
    }

    function _writeBundle(address iwspyxFeed, address paxgFeed, uint256 iwspyxAssetId, uint256 paxgAssetId) internal {
        // Collateral-only house style: flat 0% curve, no borrow use case
        bytes memory irData = abi.encode(InterestRateDataLike({ optimalUsageRatio: 99_00, baseDrawnRate: 0, rateGrowthBeforeOptimal: 0, rateGrowthAfterOptimal: 0 }));

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(C.LEND_OWNER_SAFE));

        txs = _append(txs, C.HUB_CONFIGURATOR, abi.encodeCall(IHubConfiguratorLike.addAsset, (C.CASH_HUB, C.IWSPYX, C.TREASURY_SPOKE, 0, C.IR_STRATEGY, irData)), false);
        txs = _append(txs, C.HUB_CONFIGURATOR, abi.encodeCall(IHubConfiguratorLike.addAsset, (C.CASH_HUB, C.IPAXG, C.TREASURY_SPOKE, 0, C.IR_STRATEGY, irData)), false);

        txs = _append(txs, C.HUB_CONFIGURATOR, abi.encodeCall(IHubConfiguratorLike.addSpoke, (C.CASH_HUB, C.CASH_SPOKE, iwspyxAssetId, _spokeConfig(C.LEND_IWSPYX_ADD_CAP))), false);
        txs = _append(txs, C.HUB_CONFIGURATOR, abi.encodeCall(IHubConfiguratorLike.addSpoke, (C.CASH_HUB, C.CASH_SPOKE, paxgAssetId, _spokeConfig(C.LEND_IPAXG_ADD_CAP))), false);

        txs = _append(txs, C.SPOKE_CONFIGURATOR, abi.encodeCall(ISpokeConfiguratorLike.addReserve, (C.CASH_SPOKE, C.CASH_HUB, iwspyxAssetId, iwspyxFeed, _reserveConfig(), _dynamicConfig(C.LEND_IWSPYX_COLLATERAL_FACTOR))), false);
        txs = _append(txs, C.SPOKE_CONFIGURATOR, abi.encodeCall(ISpokeConfiguratorLike.addReserve, (C.CASH_SPOKE, C.CASH_HUB, paxgAssetId, paxgFeed, _reserveConfig(), _dynamicConfig(C.LEND_IPAXG_COLLATERAL_FACTOR))), true);

        vm.createDir("./output", true);
        vm.writeFile(OUTPUT_PATH, txs);
    }

    function _assertPostState(ISpokeLike spoke, IHubLike hub, address iwspyxFeed, address paxgFeed, uint256 iwspyxAssetId, uint256 paxgAssetId, uint256 iwspyxReserveId, uint256 paxgReserveId) internal view {
        assertEq(hub.getAssetCount(), paxgAssetId + 1, "asset count");
        assertEq(spoke.getReserveCount(), paxgReserveId + 1, "reserve count");
        assertEq(spoke.getReserveId(C.CASH_HUB, iwspyxAssetId), iwspyxReserveId, "iwSPYx reserve id");
        assertEq(spoke.getReserveId(C.CASH_HUB, paxgAssetId), paxgReserveId, "iPAXG reserve id");

        _assertReserve(spoke, iwspyxReserveId, C.IWSPYX, iwspyxAssetId, iwspyxFeed, C.LEND_IWSPYX_COLLATERAL_FACTOR, "iwSPYx");
        _assertReserve(spoke, paxgReserveId, C.IPAXG, paxgAssetId, paxgFeed, C.LEND_IPAXG_COLLATERAL_FACTOR, "iPAXG");

        _assertSpokeConfig(hub, iwspyxAssetId, C.LEND_IWSPYX_ADD_CAP, "iwSPYx");
        _assertSpokeConfig(hub, paxgAssetId, C.LEND_IPAXG_ADD_CAP, "iPAXG");
    }

    function _assertReserve(ISpokeLike spoke, uint256 reserveId, address underlying, uint256 assetId, address feed, uint16 collateralFactor, string memory label) internal view {
        ReserveLike memory reserve = spoke.getReserve(reserveId);
        assertEq(reserve.underlying, underlying, string.concat(label, ": underlying"));
        assertEq(reserve.hub, C.CASH_HUB, string.concat(label, ": hub"));
        assertEq(uint256(reserve.assetId), assetId, string.concat(label, ": assetId"));
        assertEq(uint256(reserve.decimals), 18, string.concat(label, ": decimals"));

        ReserveConfigLike memory config = spoke.getReserveConfig(reserveId);
        assertEq(uint256(config.collateralRisk), C.LEND_COLLATERAL_RISK, string.concat(label, ": collateralRisk"));
        assertFalse(config.paused, string.concat(label, ": paused"));
        assertFalse(config.frozen, string.concat(label, ": frozen"));
        assertFalse(config.borrowable, string.concat(label, ": borrowable"));
        assertTrue(config.receiveSharesEnabled, string.concat(label, ": receiveShares"));

        DynamicReserveConfigLike memory dynamicConfig = spoke.getDynamicReserveConfig(reserveId, reserve.dynamicConfigKey);
        assertEq(uint256(dynamicConfig.collateralFactor), collateralFactor, string.concat(label, ": collateralFactor"));
        assertEq(uint256(dynamicConfig.maxLiquidationBonus), C.LEND_MAX_LIQUIDATION_BONUS, string.concat(label, ": maxLiquidationBonus"));
        assertEq(uint256(dynamicConfig.liquidationFee), C.LEND_LIQUIDATION_FEE, string.concat(label, ": liquidationFee"));

        assertEq(IAaveOracleLike(C.AAVE_ORACLE).getReserveSource(reserveId), feed, string.concat(label, ": price source"));
        assertGt(IAaveOracleLike(C.AAVE_ORACLE).getReservePrice(reserveId), 0, string.concat(label, ": live price"));
    }

    function _assertSpokeConfig(IHubLike hub, uint256 assetId, uint40 addCap, string memory label) internal view {
        SpokeConfigLike memory config = hub.getSpokeConfig(assetId, C.CASH_SPOKE);
        assertEq(uint256(config.addCap), addCap, string.concat(label, ": addCap"));
        assertEq(uint256(config.drawCap), 0, string.concat(label, ": drawCap"));
        assertEq(uint256(config.riskPremiumThreshold), 0, string.concat(label, ": riskPremiumThreshold"));
        assertTrue(config.active, string.concat(label, ": active"));
        assertFalse(config.halted, string.concat(label, ": halted"));
    }

    function _spokeConfig(uint40 addCap) internal pure returns (SpokeConfigLike memory) {
        return SpokeConfigLike({ addCap: addCap, drawCap: 0, riskPremiumThreshold: 0, active: true, halted: false });
    }

    function _reserveConfig() internal pure returns (ReserveConfigLike memory) {
        return ReserveConfigLike({ collateralRisk: C.LEND_COLLATERAL_RISK, paused: false, frozen: false, borrowable: false, receiveSharesEnabled: true });
    }

    function _dynamicConfig(uint16 collateralFactor) internal pure returns (DynamicReserveConfigLike memory) {
        return DynamicReserveConfigLike({ collateralFactor: collateralFactor, maxLiquidationBonus: C.LEND_MAX_LIQUIDATION_BONUS, liquidationFee: C.LEND_LIQUIDATION_FEE });
    }

    /// @dev The DeployWspyxPaxgProdFeeds feeds at their CREATE3-deterministic addresses. Live
    ///      deployments are reused as-is; before the real broadcast the missing ones are
    ///      rehearsal-deployed on the fork through the pranked EtherFiDeployer, so the bundle
    ///      references the exact addresses the broadcast will produce.
    function _feeds() internal returns (address iwspyxFeed, address paxgFeed) {
        (, iwspyxFeed, paxgFeed) = _deployFeeds(true);
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
