// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { WspyxPaxgProd } from "../wspyx-paxg/WspyxPaxgProdConfig.sol";
import { ZchfProd } from "../zchf/ZchfProdConfig.sol";

/**
 * @title ZchfUsdt0PaxgyProdConfig
 * @notice Shared address table and parameters for the CASH side of the ZCHF + USDT0 + PAXGy collateral
 *         rollout on Optimism: PriceProviderV2 sources, DebtManager collateral configs and LendGateway
 *         reserve ids. The Summer Lend reserves themselves are listed by the aave-v4 timelock script
 *         (aave-v4 scripts/etherfi/listings, EtherFiTimelock), whose pins are mirrored here only so
 *         the bundle can be rehearsed on a fork before that listing has executed.
 *
 *         Rollout, in execution order (see README.md):
 *           1. [done] ConfigureZchfRelayEthereum3CP  — Operating Safe (ETH): ZCHF relay source + subscription
 *           2. [done] ConfigureZchfSinkOP3CP         — Operating Safe (OP): ZCHF sink window
 *           3. DeployZchfProdFeed                     — EOA: immutable "ZCHF / USD" Aave feed on OP
 *           4. aave-v4 EtherfiCashCollateralListings  — Timelock Safe: schedule, 24h, execute (all assets)
 *           5. ConfigureZchfUsdt0PaxgyCashOP3CP       — Operating Safe (OP): this bundle
 *
 *         PAXGy is PENDING (token / oracle not identified, 2026-09-23): every PAXGY_* pin is address(0)
 *         and the bundle skips the asset until they are filled in (here AND in aave-v4).
 *
 *         Address provenance: tokens verified on-chain 2026-09-23 (USDT0 symbol "USD₮0", 6 decimals);
 *         Chainlink USDT / USD is the live PriceProviderV2 source of USDT; the OracleSink `price(address)`
 *         path is the live PriceProviderV2 config of iwSPYx / iwTBLLx; Summer Lend pins from the aave-v4
 *         address book (AaveV4EtherfiCash.sol) and the live AaveOracle (USDT reserve source).
 */
library ZchfUsdt0PaxgyProd {
    // ---------------------------------------------------------------- Safes / admins
    /// @dev Cash operating safe (OP): PRICE_PROVIDER_ADMIN_ROLE, DEBT_MANAGER_ADMIN_ROLE and
    ///      LEND_GATEWAY_ADMIN_ROLE on the Optimism RoleRegistry (verified 2026-09-23)
    address internal constant OPERATING_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    /// @dev EtherFiTimelock of the Summer Lend instance (aave-v4 AaveV4EtherfiCash.TIMELOCK): the only
    ///      holder of the configurator domain-admin roles since the migration; pranked on forks to
    ///      rehearse the aave-v4 listing before it has executed
    address internal constant LEND_TIMELOCK = 0xbaCa0cD6B69Eef3257e2D122b22ddEE8AeE5e283;

    // ---------------------------------------------------------------- tokens (OP)
    address internal constant ZCHF = ZchfProd.ZCHF_OP;
    /// @dev The OracleSink / relay price KEY of ZCHF (mainnet address; the relay ships mainnet keys)
    address internal constant ZCHF_MAINNET = ZchfProd.ZCHF_MAINNET;
    /// @dev Tether omnichain USDT (LayerZero OFT) on Optimism — NOT the legacy bridged USDT 0x94b0…8e58
    address internal constant USDT0 = 0x01bFF41798a0BcF287b996046Ca68b395DbC1071;
    /// @dev ether.fi shadow OFT of PAXGy on Optimism ("EtherFi PAXGy" / iPAXGy, 18 decimals; cash-mainnet-asset-listing),
    ///      VERIFIED 2026-09-23: Operating Safe owner, LayerZero peer of the mainnet OFT adapter
    ///      0x3108f4C4C1fA0dD25523222258cd51c4C9D3b40C (token 0x6c6494Fd9962eB98B94ffA48F6679058F820700e = PAXGy)
    address internal constant PAXGY = 0x5168E0cDeb3f308F47fDF0D9A2E250A2135C3cF5;
    uint8 internal constant ZCHF_DECIMALS = 18;
    uint8 internal constant USDT0_DECIMALS = 6;
    uint8 internal constant PAXGY_DECIMALS = 18;

    // ---------------------------------------------------------------- PriceProviderV2 sources (OP)
    /// @dev Prod OracleSink (3CP 622), 6 decimals, keyed by MAINNET token addresses; its `price(address)`
    ///      enforces the sink window, hence maxStaleness 0 on the provider (the live iwSPYx pattern)
    address internal constant ORACLE_SINK = ZchfProd.ORACLE_SINK;
    bytes4 internal constant ORACLE_SINK_PRICE_SELECTOR = bytes4(keccak256("price(address)"));
    uint8 internal constant ORACLE_SINK_DECIMALS = 6;
    /// @dev Chainlink USDT / USD aggregator on Optimism, 8 decimals — the live USDT source
    address internal constant USDT_USD_AGGREGATOR = 0xECef79E109e997bCA29c1c0897ec9d7b03647F5E;
    /// @dev 7 days, the OP practice for this rollout. NOTE: the LIVE USDT PriceProviderV2 entry reads 2 days
    ///      (USDC / EURC too, iPAXG 3 days, liquidRWA 7 days); this is a cash-side bound, not a Summer Lend one
    uint24 internal constant USDT_USD_MAX_STALENESS = 7 days;
    /// @dev Chainlink "PAXGy / Gold Exchange Rate" on Optimism (proxy; aggregator 0x2806…4Bd6): XAU (troy oz)
    ///      per PAXGy, 18 decimals, 24h heartbeat / 0.5% deviation (Chainlink feed directory, 2026-09-23).
    ///      PAXGy / USD = this rate x XAU / USD. Ethereum twin: 0xaaA69F0bC7E355581a83002B597Fe5c6C134ae08.
    address internal constant PAXGY_XAU_RATE_FEED = 0xDD12d3De4964eC93F81752c8F2552f053124B180;
    /// @dev 7 days, the bound of every live cash-v3 Summer Lend feed on OP (verified 2026-09-23); the feed
    ///      heartbeats every 24h. Used by the Summer Lend feed AND the PriceProviderV2 entry.
    uint24 internal constant PAXGY_XAU_MAX_STALENESS = 7 days;
    /// @dev Chainlink XAU / USD aggregator proxy on Optimism, 8 decimals, 20 min heartbeat / 0.2% deviation
    address internal constant XAU_USD_AGGREGATOR = 0x8F7bFb42Bf7421c2b34AAD619be4654bFa7B3B8B;
    /// @dev 7 days, the OP practice (the live PAXG / USD Summer Lend leg reads 7 days too); the feed heartbeats
    ///      every 20 min. Used by the Summer Lend leg AND the PriceProviderV2 XAU base entry.
    uint24 internal constant XAU_USD_MAX_STALENESS = 7 days;
    /// @dev The PriceProviderV2 pseudo-token that carries XAU / USD as the base asset of PAXGy (the way SPYx
    ///      carries SPY / USD for iwSPYx): Chainlink Denominations.XAU = address(959). Not a token.
    address internal constant XAU_DENOMINATION = address(959);

    // ---------------------------------------------------------------- DebtManager configs (100e18 = 100%) — PROPOSED
    /// @dev ZCHF: LT at the Summer Lend CF (85%), LTV 5 points under it, bonus at the lend max bonus
    uint80 internal constant DM_ZCHF_LTV = 80e18;
    uint80 internal constant DM_ZCHF_LIQ_THRESHOLD = 85e18;
    uint96 internal constant DM_ZCHF_LIQ_BONUS = 7.5e18;
    /// @dev USDT0: mirrors the live USDT config (90 / 95 / 1)
    uint80 internal constant DM_USDT0_LTV = 90e18;
    uint80 internal constant DM_USDT0_LIQ_THRESHOLD = 95e18;
    uint96 internal constant DM_USDT0_LIQ_BONUS = 1e18;
    /// @dev PAXGy: placeholder, mirrors the live iPAXG config (75 / 80 / 6)
    uint80 internal constant DM_PAXGY_LTV = 75e18;
    uint80 internal constant DM_PAXGY_LIQ_THRESHOLD = 80e18;
    uint96 internal constant DM_PAXGY_LIQ_BONUS = 6e18;

    // ---------------------------------------------------------------- Summer Lend (aave-v4 pins, fork rehearsal only)
    address internal constant HUB_CONFIGURATOR = WspyxPaxgProd.HUB_CONFIGURATOR;
    address internal constant SPOKE_CONFIGURATOR = WspyxPaxgProd.SPOKE_CONFIGURATOR;
    address internal constant CASH_HUB = WspyxPaxgProd.CASH_HUB;
    address internal constant CASH_SPOKE = WspyxPaxgProd.CASH_SPOKE;
    address internal constant TREASURY_SPOKE = WspyxPaxgProd.TREASURY_SPOKE;
    address internal constant IR_STRATEGY = WspyxPaxgProd.IR_STRATEGY;
    address internal constant AAVE_ORACLE = WspyxPaxgProd.AAVE_ORACLE;
    /// @dev aave-v4 AaveV4EtherfiCashAssets.<ASSET>_ORACLE: ZCHF = the DeployZchfProdFeed CREATE3 address,
    ///      USDT0 = the live "Capped USDT / USD" CAPO adapter the USDT reserve reads (no new feed)
    address internal constant LEND_ZCHF_FEED = ZchfProd.EXPECTED_FEED;
    address internal constant LEND_USDT0_FEED = 0x7579977643ee68946DB95d9Cb5fF582674619025;
    /// @dev PAXGy: the composed "PAXGy / USD" ChainlinkPriceFeed of DeployZchfUsdt0PaxgyProdFeeds (CREATE3,
    ///      predicted; the deploy asserts it) — pinned in aave-v4 as AaveV4EtherfiCashAssets.PAXGY_ORACLE
    address internal constant LEND_PAXGY_FEED = 0x9B92A2D4468ff3Df8A6Be50Ad043E8a5165459c2;
    /// @dev The "XAU / USD" ChainlinkPriceFeed leg the PAXGy feed composes on (same deploy, salt "XauUsdFeed")
    address internal constant LEND_XAU_FEED = 0xf66C01179bA7326C95a5d3324Bc364f34CA7c7Af;
    /// @dev aave-v4 AaveV4EtherfiCashCaps / AaveV4EtherfiCashCollateral (PROPOSED there too)
    /// @dev ZCHF and PAXGy are LISTED CLOSED (add cap 0; the risk curator raises it), per aave-v4 Caps
    uint40 internal constant LEND_ZCHF_ADD_CAP = 0;
    uint16 internal constant LEND_ZCHF_COLLATERAL_FACTOR = 85_00;
    uint32 internal constant LEND_ZCHF_MAX_LIQUIDATION_BONUS = 107_50;
    /// @dev USDT0 is listed BORROWABLE (draw cap pinned to 0; the risk curator raises it) with the live USDC curve
    uint40 internal constant LEND_USDT0_ADD_CAP = 5_000_000;
    uint256 internal constant LEND_USDT0_LIQUIDITY_FEE = 30_00;
    uint16 internal constant LEND_USDT0_OPTIMAL_USAGE_RATIO = 85_00;
    uint32 internal constant LEND_USDT0_BASE_DRAWN_RATE = 3_00;
    uint32 internal constant LEND_USDT0_RATE_GROWTH_BEFORE_OPTIMAL = 1_25;
    uint32 internal constant LEND_USDT0_RATE_GROWTH_AFTER_OPTIMAL = 10_00;
    uint16 internal constant LEND_USDT0_COLLATERAL_FACTOR = 90_00;
    uint32 internal constant LEND_USDT0_MAX_LIQUIDATION_BONUS = 105_00;
    uint40 internal constant LEND_PAXGY_ADD_CAP = 0;
    uint16 internal constant LEND_PAXGY_COLLATERAL_FACTOR = 80_00;
    uint32 internal constant LEND_PAXGY_MAX_LIQUIDATION_BONUS = 110_00;
    uint16 internal constant LEND_LIQUIDATION_FEE = 10_00;
    uint16 internal constant LEND_COLLATERAL_ONLY_OPTIMAL_USAGE_RATIO = 99_00;
}
