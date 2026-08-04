// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { AddSummerLendCollateral } from "./AddSummerLendCollateral.s.sol";

/**
 * @title SupportWspyxCollateral
 * @notice Supports iwSPYx (the OP ShadowOFT of mainnet wSPYx) as collateral on both lend backends,
 *         priced by the OracleSinkPriceFeed deployed by DeployWspyxOracleSinkFeed (relayed
 *         wSPYx -> SPYx rate x local SPY/USD 24/5 Chainlink leg):
 *           1. Aave v4 TEST instance: collateral-only reserve, collateralFactor 73%,
 *              maxLiquidationBonus 7.5% (10_750 bps of collateral per unit of debt repaid);
 *           2. LendGateway: registers the new reserveId so gateway accounting sees the asset;
 *           3. DebtManager: 73% LTV / 78% liquidation threshold / 7.5% liquidation bonus
 *              (100e18 scale). The cash PriceProvider must already price iwSPYx
 *              (ConfigureWspyxOracleOptimism in cash-mainnet-asset-listing did on dev).
 *
 *         Idempotent via the parent's _list (an already-listed reserve just gets its price source
 *         refreshed); the DebtManager leg falls back to setCollateralTokenConfig when iwSPYx is
 *         already a collateral token.
 *
 * Usage (simulate by dropping --broadcast; the broadcast wallet must hold the instance admin,
 * LEND_GATEWAY_ADMIN_ROLE and DEBT_MANAGER_ADMIN_ROLE roles):
 *   source .env && ENV=dev FOUNDRY_PROFILE=aave-deploy forge script \
 *     scripts/aave-v4/SupportWspyxCollateral.s.sol:SupportWspyxCollateral \
 *     --rpc-url $OPTIMISM_RPC --broadcast -vvvv
 */
contract SupportWspyxCollateral is AddSummerLendCollateral {
    /// @dev iwSPYx ShadowOFT on Optimism (cash-mainnet-asset-listing deployments/dev/10)
    address constant IWSPYX = 0xc83305D859EAc5E34B6aa00b4a45bDC13b2F3869;

    uint16 constant COLLATERAL_FACTOR_BPS = 73_00;
    uint32 constant MAX_LIQUIDATION_BONUS_BPS = 10_750; // collateral paid out per unit of debt: 100% + 7.5%

    // DebtManager scale: 100e18 == 100%
    uint80 constant DM_LTV = 73e18;
    uint80 constant DM_LIQUIDATION_THRESHOLD = 78e18;
    uint96 constant DM_LIQUIDATION_BONUS = 7.5e18;

    function run() public override {
        require(block.chainid == 10, "Must run on Optimism (10)");
        require(isEqualString(vm.envOr("FOUNDRY_PROFILE", string("default")), "aave-deploy"), "Run with FOUNDRY_PROFILE=aave-deploy");
        require(isEqualString(getEnv(), "dev"), "dev-only: addresses are the dev deployments");

        _loadInstance();

        string memory deployments = readDeploymentFile();
        IDebtManager debtManager = IDebtManager(stdJson.readAddress(deployments, ".addresses.DebtManager"));
        string memory cashLendJson = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/cash-lend.json"));
        LendGateway gateway = LendGateway(stdJson.readAddress(cashLendJson, ".lendGateway"));

        // The current "iwSPYx / USD" OracleSinkPriceFeed, kept fresh by RefreshSummerLendOracles
        address iwspyxUsdFeed = stdJson.readAddress(vm.readFile(jsonPath), ".details.iwSPYx.oracle");
        _requireLivePrice(iwspyxUsdFeed, "iwSPYx / USD");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // 1. Aave v4: collateral-only reserve on the OracleSink feed
        _list(IWSPYX, iwspyxUsdFeed, COLLATERAL_FACTOR_BPS, MAX_LIQUIDATION_BONUS_BPS);
        uint256 reserveId = _reserveIdOf(IWSPYX);

        // 2. LendGateway: mirror the reserve into the gateway registry (no-op when unchanged)
        gateway.setReserveId(IWSPYX, reserveId);

        // 3. DebtManager: 73% LTV / 78% LT / 7.5% LB on the 100e18 scale
        IDebtManager.CollateralTokenConfig memory config = IDebtManager.CollateralTokenConfig({ ltv: DM_LTV, liquidationThreshold: DM_LIQUIDATION_THRESHOLD, liquidationBonus: DM_LIQUIDATION_BONUS });
        if (debtManager.isCollateralToken(IWSPYX)) debtManager.setCollateralTokenConfig(IWSPYX, config);
        else debtManager.supportCollateralToken(IWSPYX, config);

        vm.stopBroadcast();

        _recordReserveIds(vm.readFile(jsonPath));

        console.log("iwSPYx reserveId:", reserveId);
        console.log("gateway reserve registered:", address(gateway));
        IDebtManager.CollateralTokenConfig memory recorded = debtManager.collateralTokenConfig(IWSPYX);
        console.log("DebtManager ltv/lt/lb (1e18 %):", recorded.ltv / 1e18, recorded.liquidationThreshold / 1e18);
        console.log("  liquidation bonus (1e16 %):", recorded.liquidationBonus / 1e16);
    }
}
