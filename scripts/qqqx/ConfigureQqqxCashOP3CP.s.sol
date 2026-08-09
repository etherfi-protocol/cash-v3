// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { QqqxFeedDeployer } from "./DeployQqqxProdFeeds.s.sol";
import { ILendGatewayLike, ISpokeLike, QqqxProd as C } from "./QqqxProdConfig.sol";

/**
 * @title ConfigureQqqxCashOP3CP
 * @notice Generates the OPERATING SAFE (0xA6cf…AAC4) Optimism bundle that finishes the iwQQQx
 *         collateral rollout on the cash side:
 *
 *           1. DebtManager.supportCollateralToken(iwQQQx) — 73% LTV / 78% LT / 7.5% bonus
 *           2. LendGateway.setReserveId(iwQQQx, reserveId) — mirrors the new Summer Lend reserve
 *              into the gateway registry
 *
 *         Deliberately NO PriceProviderV2 call here, unlike the iPAXG repoint bundle this
 *         mirrors: the wQQQx relay leg is permanent — there is no retirement path for this asset
 *         the way PR #273 retired PAXG's — so iwQQQx keeps reading the OracleSink through the
 *         config the cash-mainnet-asset-listing Optimism bundle writes. This bundle only ever
 *         reads that price; it never writes it.
 *
 *         EXECUTION ORDER: after the Lend Owner Safe bundle (ListQqqxSummerLend3CP), whose
 *         reserve id tx 2 registers. If the reserve is not yet listed on the fork, the simulation
 *         replays the Lend Owner Safe bundle first, so both JSONs can be generated and rehearsed
 *         in one sitting.
 *
 *         NOTE: tx 1 reads the live iwQQQx price (sink rate x QQQ/USD); QQQ/USD is a 24/5 feed, so
 *         simulate and execute while it is fresh (within 3 days of the last market close).
 *
 * Usage (after ListQqqxSummerLend3CP has been generated):
 *   forge script scripts/qqqx/ConfigureQqqxCashOP3CP.s.sol --rpc-url $OPTIMISM_RPC
 */
contract ConfigureQqqxCashOP3CP is GnosisHelpers, Test, QqqxFeedDeployer {
    string constant OUTPUT_PATH = "./output/ConfigureQqqxCashOP3CP-10.json";
    string constant LEND_BUNDLE_PATH = "./output/ListQqqxSummerLend3CP-10.json";

    /// @dev cash-mainnet-asset-listing Task A3's PriceProviderV2 QQQ/USD base-entry staleness.
    ///      Deliberately NOT QqqxProd.QQQ_USD_MAX_STALENESS (that constant is Repo B's own Aave
    ///      feed leg, 3 days) — this is the OTHER repo's parameter, reproduced verbatim only so a
    ///      fork rehearsal can stand in for a bundle this repo does not own or ship.
    uint24 constant REPO_A_QQQ_USD_MAX_STALENESS = 78 hours;

    function run() public {
        require(block.chainid == 10, "must be Optimism");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        string memory deployments = readDeploymentFile();
        PriceProviderV2 pp = PriceProviderV2(stdJson.readAddress(deployments, ".addresses.PriceProvider"));
        IDebtManager debtManager = IDebtManager(stdJson.readAddress(deployments, ".addresses.DebtManager"));
        ILendGatewayLike gateway = ILendGatewayLike(stdJson.readAddress(vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/cash-lend.json")), ".lendGateway"));

        // Fork-only: the iwQQQx ShadowOFT + a relayed sink price must exist before anything below
        // can read a price. Never called from a broadcast path; nothing it writes is bundle calldata.
        _rehearseQqqxRails();
        require(!debtManager.isCollateralToken(C.IWQQQX), "iwQQQx already a DebtManager collateral");

        // The Summer Lend reserve id tx 2 registers; live if the Lend Owner Safe bundle has
        // executed, otherwise replay it on the fork and take the id it assigns
        uint256 reserveId = _reserveId();

        // Pre-state: DebtManager.supportCollateralToken reads this same price. On a fork where
        // cash-mainnet-asset-listing's Optimism bundle (the OTHER repo) has not executed,
        // PriceProviderV2 holds no iwQQQx entry and pp.price reverts — handled below.
        uint256 priceBefore = _priceOrZero(pp);
        if (priceBefore == 0) {
            console.log("[REHEARSAL] PriceProviderV2 has no iwQQQx entry (cash-mainnet-asset-listing Optimism bundle has not executed on this fork).");
            console.log("[REHEARSAL] Registering that bundle's exact Task A3 config here so DebtManager.supportCollateralToken can read a live price. This write is NOT part of ConfigureQqqxCashOP3CP's own bundle.");
            _rehearseCashPriceConfig(pp);
            priceBefore = pp.price(C.IWQQQX);
        }

        _writeBundle(debtManager, gateway, reserveId);
        console.log("Written: %s", OUTPUT_PATH);

        executeGnosisTransactionBundle(OUTPUT_PATH);
        _assertPostState(pp, debtManager, gateway, reserveId, priceBefore);

        console.log("Simulation passed.");
        console.log("  iwQQQx / USD: %s (6 dec)", pp.price(C.IWQQQX));
        console.log("  gateway reserve id: %s", reserveId);
    }

    function _writeBundle(IDebtManager debtManager, ILendGatewayLike gateway, uint256 reserveId) internal {
        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(C.OPERATING_SAFE));

        txs = _append(txs, address(debtManager), abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, C.IWQQQX, IDebtManager.CollateralTokenConfig({ ltv: C.DM_IWQQQX_LTV, liquidationThreshold: C.DM_IWQQQX_LIQ_THRESHOLD, liquidationBonus: C.DM_IWQQQX_LIQ_BONUS })), false);
        txs = _append(txs, address(gateway), abi.encodeCall(ILendGatewayLike.setReserveId, (C.IWQQQX, reserveId)), true);

        vm.createDir("./output", true);
        vm.writeFile(OUTPUT_PATH, txs);
    }

    function _assertPostState(PriceProviderV2 pp, IDebtManager debtManager, ILendGatewayLike gateway, uint256 reserveId, uint256 priceBefore) internal view {
        assertTrue(debtManager.isCollateralToken(C.IWQQQX), "iwQQQx: not a collateral token");
        IDebtManager.CollateralTokenConfig memory config = debtManager.collateralTokenConfig(C.IWQQQX);
        assertEq(uint256(config.ltv), C.DM_IWQQQX_LTV, "iwQQQx: ltv");
        assertEq(uint256(config.liquidationThreshold), C.DM_IWQQQX_LIQ_THRESHOLD, "iwQQQx: liquidationThreshold");
        assertEq(uint256(config.liquidationBonus), C.DM_IWQQQX_LIQ_BONUS, "iwQQQx: liquidationBonus");

        assertEq(gateway.reserveIdOf(C.IWQQQX), reserveId, "gateway iwQQQx reserve id");

        // This bundle never touches PriceProviderV2 -- the price it reads before and after must
        // be identical
        uint256 priceAfter = pp.price(C.IWQQQX);
        assertGt(priceAfter, 0, "iwQQQx: price not live");
        if (priceBefore != 0) assertEq(priceAfter, priceBefore, "iwQQQx price changed");
    }

    /// @dev The Summer Lend reserve id for iwQQQx; replays the Lend Owner Safe bundle on the fork
    ///      when it is not yet listed live.
    function _reserveId() internal returns (uint256 reserveId) {
        ISpokeLike spoke = ISpokeLike(C.CASH_SPOKE);
        reserveId = _reserveIdOf(spoke, C.IWQQQX);
        if (reserveId != type(uint256).max) return reserveId;

        require(vm.exists(LEND_BUNDLE_PATH), "reserve not listed; generate ListQqqxSummerLend3CP first");
        console.log("Reserve not yet listed live; replaying the Lend Owner Safe bundle on the fork");
        // The bundle's addReserve call reads the feeds, so rehearsal-deploy any not yet broadcast
        _deployFeeds(true);
        executeGnosisTransactionBundle(LEND_BUNDLE_PATH);

        reserveId = _reserveIdOf(spoke, C.IWQQQX);
        require(reserveId != type(uint256).max, "lend bundle did not list the reserve");
    }

    /// @dev try/catch around pp.price(iwQQQx). Reverts (returns 0) when the cash-mainnet-asset-
    ///      listing Optimism bundle -- a different repo's PR -- has not yet written the iwQQQx
    ///      PriceProviderV2 entry. That is a real prerequisite this bundle cannot satisfy itself.
    function _priceOrZero(PriceProviderV2 pp) internal view returns (uint256) {
        try pp.price(C.IWQQQX) returns (uint256 p) {
            return p;
        } catch {
            return 0;
        }
    }

    /// @dev Fork-only. Reproduces cash-mainnet-asset-listing Task A3's PriceProviderV2.setTokenConfig
    ///      call byte-for-byte (QQQx base entry FIRST, then iwQQQx -- setTokenConfig validates a
    ///      dependent entry's baseAsset against configs stored earlier in the SAME call, so the
    ///      order is load-bearing) by pranking the Operating Safe through the real setTokenConfig.
    ///      This is the other repo's write to make on mainnet; this function only stands it up on
    ///      THIS fork so DebtManager.supportCollateralToken has a live price to read. It is never
    ///      folded into ConfigureQqqxCashOP3CP's own bundle -- Repo A owns shipping this config.
    function _rehearseCashPriceConfig(PriceProviderV2 pp) internal {
        address[] memory tokens = new address[](2);
        tokens[0] = C.QQQX_MAINNET; // base entry: an arbitrary address KEY for QQQ/USD
        tokens[1] = C.IWQQQX;

        PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](2);
        configs[0] = PriceProviderV2.Config({ oracle: C.QQQ_USD_AGGREGATOR, priceFunctionCalldata: "", isChainlinkType: true, oraclePriceDecimals: 8, maxStaleness: REPO_A_QQQ_USD_MAX_STALENESS, dataType: PriceProviderV2.ReturnType.Int256, isStableToken: false, baseAsset: address(0) });
        configs[1] = PriceProviderV2.Config({ oracle: C.ORACLE_SINK, priceFunctionCalldata: abi.encodeWithSignature("price(address)", C.WQQQX_MAINNET), isChainlinkType: false, oraclePriceDecimals: 6, maxStaleness: 0, dataType: PriceProviderV2.ReturnType.Uint256, isStableToken: false, baseAsset: C.QQQX_MAINNET });

        vm.prank(C.OPERATING_SAFE);
        pp.setTokenConfig(tokens, configs);
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
