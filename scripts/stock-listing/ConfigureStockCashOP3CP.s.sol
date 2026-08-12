// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { StockFeedDeployer } from "./DeployStockProdFeeds.s.sol";
import { StockLendAssets } from "./StockLendAssets.sol";
import { ILendGatewayLike, ISpokeLike, LendRails, StockLendAsset } from "./StockLendConfig.sol";

/**
 * @title ConfigureStockCashOP3CPBase
 * @notice Generates the OPERATING SAFE (0xA6cf…AAC4) Optimism bundle that finishes a 4626-wrapped
 *         xStock's collateral rollout on the cash side:
 *
 *           1. DebtManager.supportCollateralToken(iToken) — asset.ltv / liquidationThreshold /
 *              liquidationBonus
 *           2. LendGateway.setReserveId(iToken, reserveId) — mirrors the new Summer Lend reserve
 *              into the gateway registry
 *
 *         Deliberately NO PriceProviderV2 call here, unlike a repoint bundle (e.g. PR #273's PAXG
 *         retirement): for an asset whose relay leg is permanent, there is no retirement path the
 *         way PAXG had, so the iToken keeps reading the OracleSink through the config the
 *         cash-mainnet-asset-listing Optimism bundle writes. This bundle only ever reads that
 *         price; it never writes it.
 *
 *         EXECUTION ORDER: after the Lend Owner Safe bundle (List*SummerLend3CP), whose reserve id
 *         tx 2 registers. If the reserve is not yet listed on the fork, the simulation replays the
 *         Lend Owner Safe bundle first, so both JSONs can be generated and rehearsed in one
 *         sitting.
 *
 *         NOTE: tx 1 reads the live price (sink rate x <STOCK>/USD); the base feed is a 24/5
 *         market feed, so simulate and execute while it is fresh.
 */
abstract contract ConfigureStockCashOP3CPBase is GnosisHelpers, Test, StockFeedDeployer {
    function _asset() internal pure virtual returns (StockLendAsset memory);
    function _outputPath() internal pure virtual returns (string memory);
    function _lendBundlePath() internal pure virtual returns (string memory);

    function run() public {
        StockLendAsset memory asset = _asset();
        string memory outputPath = _outputPath();

        require(block.chainid == 10, "must be Optimism");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        string memory deployments = readDeploymentFile();
        PriceProviderV2 pp = PriceProviderV2(stdJson.readAddress(deployments, ".addresses.PriceProvider"));
        IDebtManager debtManager = IDebtManager(stdJson.readAddress(deployments, ".addresses.DebtManager"));
        ILendGatewayLike gateway = ILendGatewayLike(stdJson.readAddress(vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/cash-lend.json")), ".lendGateway"));

        // Fork-only: the iToken ShadowOFT + a relayed sink price must exist before anything below
        // can read a price. Never called from a broadcast path; nothing it writes is bundle calldata.
        _rehearseStockRails(asset);
        require(!debtManager.isCollateralToken(asset.iToken), "already a DebtManager collateral");

        // The Summer Lend reserve id tx 2 registers; live if the Lend Owner Safe bundle has
        // executed, otherwise replay it on the fork and take the id it assigns
        uint256 reserveId = _reserveId(asset);

        // Pre-state: DebtManager.supportCollateralToken reads this same price. On a fork where
        // cash-mainnet-asset-listing's Optimism bundle (the OTHER repo) has not executed,
        // PriceProviderV2 holds no entry for this iToken and pp.price reverts — handled below.
        uint256 priceBefore = _priceOrZero(pp, asset.iToken);
        if (priceBefore == 0) {
            console.log("[REHEARSAL] PriceProviderV2 has no entry for this iToken (cash-mainnet-asset-listing Optimism bundle has not executed on this fork).");
            console.log("[REHEARSAL] Registering that bundle's exact base-entry config here so DebtManager.supportCollateralToken can read a live price. This write is NOT part of this bundle.");
            _rehearseCashPriceConfig(pp, asset);
            priceBefore = pp.price(asset.iToken);
        }

        _writeBundle(asset, outputPath, debtManager, gateway, reserveId);
        console.log("Written: %s", outputPath);

        executeGnosisTransactionBundle(outputPath);
        _assertPostState(asset, pp, debtManager, gateway, reserveId, priceBefore);

        console.log("Simulation passed.");
        console.log("  price: %s (6 dec)", pp.price(asset.iToken));
        console.log("  gateway reserve id: %s", reserveId);
    }

    function _writeBundle(StockLendAsset memory asset, string memory outputPath, IDebtManager debtManager, ILendGatewayLike gateway, uint256 reserveId) internal {
        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(LendRails.OPERATING_SAFE));

        txs = _append(txs, address(debtManager), abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, asset.iToken, IDebtManager.CollateralTokenConfig({ ltv: asset.ltv, liquidationThreshold: asset.liquidationThreshold, liquidationBonus: asset.liquidationBonus })), false);
        txs = _append(txs, address(gateway), abi.encodeCall(ILendGatewayLike.setReserveId, (asset.iToken, reserveId)), true);

        vm.createDir("./output", true);
        vm.writeFile(outputPath, txs);
    }

    function _assertPostState(StockLendAsset memory asset, PriceProviderV2 pp, IDebtManager debtManager, ILendGatewayLike gateway, uint256 reserveId, uint256 priceBefore) internal view {
        assertTrue(debtManager.isCollateralToken(asset.iToken), "not a collateral token");
        IDebtManager.CollateralTokenConfig memory config = debtManager.collateralTokenConfig(asset.iToken);
        assertEq(uint256(config.ltv), asset.ltv, "ltv");
        assertEq(uint256(config.liquidationThreshold), asset.liquidationThreshold, "liquidationThreshold");
        assertEq(uint256(config.liquidationBonus), asset.liquidationBonus, "liquidationBonus");

        assertEq(gateway.reserveIdOf(asset.iToken), reserveId, "gateway reserve id");

        // This bundle never touches PriceProviderV2 -- the price it reads before and after must
        // be identical
        uint256 priceAfter = pp.price(asset.iToken);
        assertGt(priceAfter, 0, "price not live");
        if (priceBefore != 0) assertEq(priceAfter, priceBefore, "price changed");
    }

    /// @dev The Summer Lend reserve id for this asset; replays the Lend Owner Safe bundle on the
    ///      fork when it is not yet listed live.
    function _reserveId(StockLendAsset memory asset) internal returns (uint256 reserveId) {
        ISpokeLike spoke = ISpokeLike(LendRails.CASH_SPOKE);
        reserveId = _reserveIdOf(spoke, asset.iToken);
        if (reserveId != type(uint256).max) return reserveId;

        string memory lendBundlePath = _lendBundlePath();
        require(vm.exists(lendBundlePath), "reserve not listed; generate the Lend Owner Safe bundle first");
        console.log("Reserve not yet listed live; replaying the Lend Owner Safe bundle on the fork");
        // The bundle's addReserve call reads the feeds, so rehearsal-deploy any not yet broadcast
        _deployFeeds(true, asset);
        executeGnosisTransactionBundle(lendBundlePath);

        reserveId = _reserveIdOf(spoke, asset.iToken);
        require(reserveId != type(uint256).max, "lend bundle did not list the reserve");
    }

    /// @dev try/catch around pp.price(iToken). Reverts (returns 0) when the cash-mainnet-asset-
    ///      listing Optimism bundle -- a different repo's PR -- has not yet written the
    ///      PriceProviderV2 entry for this iToken. That is a real prerequisite this bundle cannot
    ///      satisfy itself.
    function _priceOrZero(PriceProviderV2 pp, address token) internal view returns (uint256) {
        try pp.price(token) returns (uint256 p) {
            return p;
        } catch {
            return 0;
        }
    }

    /// @dev Fork-only. Reproduces cash-mainnet-asset-listing's PriceProviderV2.setTokenConfig call
    ///      byte-for-byte (stock base entry FIRST, then the iToken -- setTokenConfig validates a
    ///      dependent entry's baseAsset against configs stored earlier in the SAME call, so the
    ///      order is load-bearing) by pranking the Operating Safe through the real setTokenConfig.
    ///      This is the other repo's write to make on mainnet; this function only stands it up on
    ///      THIS fork so DebtManager.supportCollateralToken has a live price to read. It is never
    ///      folded into this bundle -- the other repo owns shipping this config.
    function _rehearseCashPriceConfig(PriceProviderV2 pp, StockLendAsset memory asset) internal {
        address[] memory tokens = new address[](2);
        tokens[0] = asset.stock; // base entry: an arbitrary address KEY for <STOCK>/USD
        tokens[1] = asset.iToken;

        PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](2);
        configs[0] = PriceProviderV2.Config({ oracle: asset.usdAggregator, priceFunctionCalldata: "", isChainlinkType: true, oraclePriceDecimals: 8, maxStaleness: asset.cashBaseFeedMaxStaleness, dataType: PriceProviderV2.ReturnType.Int256, isStableToken: false, baseAsset: address(0) });
        configs[1] = PriceProviderV2.Config({ oracle: LendRails.ORACLE_SINK, priceFunctionCalldata: abi.encodeWithSignature("price(address)", asset.wrapper), isChainlinkType: false, oraclePriceDecimals: 6, maxStaleness: 0, dataType: PriceProviderV2.ReturnType.Uint256, isStableToken: false, baseAsset: asset.stock });

        vm.prank(LendRails.OPERATING_SAFE);
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

/**
 * @title ConfigureQqqxCashOP3CP
 * @notice iwQQQx's Configure*CashOP3CP. See ConfigureStockCashOP3CPBase for the shared mechanics
 *         and StockLendAssets.wqqqx() for this asset's parameters and rollout-specific notes.
 *
 * Usage (after ListQqqxSummerLend3CP has been generated):
 *   forge script scripts/stock-listing/ConfigureStockCashOP3CP.s.sol:ConfigureQqqxCashOP3CP --rpc-url $OPTIMISM_RPC
 */
contract ConfigureQqqxCashOP3CP is ConfigureStockCashOP3CPBase {
    function _asset() internal pure override returns (StockLendAsset memory) {
        return StockLendAssets.wqqqx();
    }

    function _outputPath() internal pure override returns (string memory) {
        return "./output/ConfigureQqqxCashOP3CP-10.json";
    }

    function _lendBundlePath() internal pure override returns (string memory) {
        return "./output/ListQqqxSummerLend3CP-10.json";
    }
}
