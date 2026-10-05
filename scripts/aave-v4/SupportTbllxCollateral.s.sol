// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { AddSummerLendCollateral } from "./AddSummerLendCollateral.s.sol";

/**
 * @title SupportTbllxCollateral
 * @notice Supports iwTBLLx as collateral on both lend backends on the DEV stack — the counterpart of
 *         the prod pair `ListTbllxSummerLend3CP` (3CP-642) + `ConfigureTbllxCashOP3CP` (3CP-643),
 *         collapsed into one EOA broadcast because the dev instance is admin-key driven rather than
 *         Safe driven.
 *
 *         DEV REUSES THE PROD RAILS WHOLESALE — the prod iwTBLLx ShadowOFT and the prod, immutable
 *         Aave v4 iwTBLLx/USD feed, which reads the prod OracleSink. Nothing iwTBLLx-shaped is
 *         deployed or configured on a dev-only address by this rollout, which is what makes it three
 *         config calls instead of a parallel set of rails. Consequences worth knowing:
 *           - dev inherits the PROD keeper cadence. The prod feed's rate leg is a 3-day window
 *             backed by a keeper on a <= 3-day poke schedule, so dev gets prod's freshness instead
 *             of the ad-hoc 7-day dev-sink window the iwSPYx dev feed had to settle for.
 *           - the OracleSink freshness window for wTBLLx is set by the prod Optimism bundle
 *             (3CP-641, `OracleSink.setMaxStaleness`) and is neither needed nor settable here.
 *           - the feed is immutable and admin-less, so `RefreshSummerLendOracles` deliberately
 *             leaves this reserve's price source alone.
 *
 *         Three legs:
 *           1. Aave v4 TEST instance: collateral-only reserve on the prod feed, collateralFactor
 *              80%, maxLiquidationBonus 10% (11_000 bps of collateral per unit of debt repaid);
 *           2. LendGateway: registers the new reserveId so gateway accounting sees the asset — also
 *              what makes `TopUpDest.supplyTopUpToLend` stop no-opping for iwTBLLx top-ups;
 *           3. DebtManager: 70% LTV / 80% liquidation threshold / 10% liquidation bonus
 *              (100e18 scale).
 *
 *         Risk config is the prod sign-off of 2026-08-12 reproduced verbatim (LTV 70 / LT 80 /
 *         bonus 10, CF 80%) so dev rehearses the numbers prod runs. Two deviations, both inherited
 *         from the dev instance's house style rather than chosen here: the parent's `_list` gives
 *         every dev reserve an uncapped addCap/drawCap (prod caps adds at 20,000 whole tokens) and a
 *         10% liquidationFee, which already matches prod.
 *
 *         Idempotent via the parent's `_list` (an already-listed reserve just gets its price source
 *         refreshed); the DebtManager leg falls back to setCollateralTokenConfig when iwTBLLx is
 *         already a collateral token.
 *
 *         RUN ConfigureDevTbllxCashOP FIRST: leg 3 reads price(iwTBLLx) through the dev cash
 *         PriceProviderV2, and that entry is written by ConfigureDevTbllxCashOP. Leg 1 additionally
 *         needs the prod feed to be pricing, which needs the prod rails live (3CP-640/641 executed
 *         and the relay keeper poked at least once) — the `_requireLivePrice` below fails loudly,
 *         before any broadcast, if it is not.
 *
 * Usage (simulate by dropping --broadcast; the broadcast wallet must hold the instance admin,
 * LEND_GATEWAY_ADMIN_ROLE and DEBT_MANAGER_ADMIN_ROLE roles):
 *   source .env && ENV=dev FOUNDRY_PROFILE=aave-deploy forge script \
 *     scripts/aave-v4/SupportTbllxCollateral.s.sol:SupportTbllxCollateral \
 *     --rpc-url $OPTIMISM_RPC --broadcast -vvvv
 */
contract SupportTbllxCollateral is AddSummerLendCollateral {
    /// @dev PROD iwTBLLx ShadowOFT on Optimism — StockLendAssets.wtbllx().iToken, deployed by the
    ///      cash-mainnet-asset-listing Optimism bundle (3CP-641). Dev points at the prod token.
    address constant IWTBLLX = 0x5F8b2D2b97aD4d63188f44965778F6004D5bc387;
    /// @dev PROD iwTBLLx/USD Aave v4 feed on Optimism — the `iwTBLLx` entry of
    ///      deployments/mainnet/10/summer-lend-feeds.json, deployed by DeployTbllxProdFeeds.
    ///      Immutable and admin-less: relayed wTBLLx -> TBLLx rate from the prod OracleSink,
    ///      composed on the local Chainlink TBLL/USD 24/5 leg (0x1A74F66b…).
    address constant IWTBLLX_USD_FEED = 0x1cee92F999D536320aFb740b2ea5318C45d9C93B;

    uint16 constant COLLATERAL_FACTOR_BPS = 80_00;
    uint32 constant MAX_LIQUIDATION_BONUS_BPS = 11_000; // collateral paid out per unit of debt: 100% + 10%

    // DebtManager scale: 100e18 == 100%
    uint80 constant DM_LTV = 70e18;
    uint80 constant DM_LIQUIDATION_THRESHOLD = 80e18;
    uint96 constant DM_LIQUIDATION_BONUS = 10e18;

    function run() public override {
        require(block.chainid == 10, "Must run on Optimism (10)");
        require(isEqualString(vm.envOr("FOUNDRY_PROFILE", string("default")), "aave-deploy"), "Run with FOUNDRY_PROFILE=aave-deploy");
        require(isEqualString(getEnv(), "dev"), "dev-only: the lend instance and cash addresses are the dev deployments");

        _loadInstance();

        require(IWTBLLX.code.length > 0, "prod iwTBLLx ShadowOFT has no code: the prod Optimism listing bundle has not executed");
        _requireLivePrice(IWTBLLX_USD_FEED, "iwTBLLx / USD (prod feed)");

        string memory deployments = readDeploymentFile();
        IDebtManager debtManager = IDebtManager(stdJson.readAddress(deployments, ".addresses.DebtManager"));
        string memory cashLendJson = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/cash-lend.json"));
        LendGateway gateway = LendGateway(stdJson.readAddress(cashLendJson, ".lendGateway"));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // 1. Aave v4: collateral-only reserve on the prod immutable feed
        _list(IWTBLLX, IWTBLLX_USD_FEED, COLLATERAL_FACTOR_BPS, MAX_LIQUIDATION_BONUS_BPS);
        uint256 reserveId = _reserveIdOf(IWTBLLX);

        // 2. LendGateway: mirror the reserve into the gateway registry (no-op when unchanged)
        gateway.setReserveId(IWTBLLX, reserveId);

        // 3. DebtManager: 70% LTV / 80% LT / 10% LB on the 100e18 scale
        IDebtManager.CollateralTokenConfig memory config = IDebtManager.CollateralTokenConfig({ ltv: DM_LTV, liquidationThreshold: DM_LIQUIDATION_THRESHOLD, liquidationBonus: DM_LIQUIDATION_BONUS });
        if (debtManager.isCollateralToken(IWTBLLX)) debtManager.setCollateralTokenConfig(IWTBLLX, config);
        else debtManager.supportCollateralToken(IWTBLLX, config);

        vm.stopBroadcast();

        _recordReserveIds(vm.readFile(jsonPath));

        console.log("iwTBLLx reserveId:", reserveId);
        console.log("  price source (prod feed):", IWTBLLX_USD_FEED);
        console.log("gateway reserve registered:", address(gateway));
        IDebtManager.CollateralTokenConfig memory recorded = debtManager.collateralTokenConfig(IWTBLLX);
        console.log("DebtManager ltv/lt (1e18 %):", recorded.ltv / 1e18, recorded.liquidationThreshold / 1e18);
        console.log("  liquidation bonus (1e16 %):", recorded.liquidationBonus / 1e16);
    }
}
