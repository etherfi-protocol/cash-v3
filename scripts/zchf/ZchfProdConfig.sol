// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ZchfProdConfig
 * @notice Shared address table and parameters for the prod ZCHF (Frankencoin, CHF stablecoin)
 *         collateral rollout on Summer Lend. Same price setup as PAXG in 3CPs 621/622: the mainnet
 *         Chainlink CHF / USD price is relayed PriceRelay (ETH) -> OracleSink (OP) and read on OP by
 *         an immutable OracleSinkPriceFeed. Unlike PAXG there is no OFT leg — ZCHF is a native OP
 *         token — and unlike the launch stables there is no 1 USD snap (CHF is not USD).
 *
 *         Execution order:
 *           1. ConfigureZchfRelayEthereum3CP — Operating Safe (ETH): RelayPriceProvider source
 *              for ZCHF (CHF / USD, 26h) + PriceRelay.subscribe(ZCHF)
 *           2. ConfigureZchfSinkOP3CP        — Operating Safe (OP): OracleSink.setMaxStaleness
 *              (ZCHF, 7 days); a zero window serves no price
 *           3. relay keeper pokes (asset-agnostic, 2h full poke): the sink holds a ZCHF price
 *           4. DeployZchfProdFeed             — EOA (registered EtherFiDeployer deployer):
 *              immutable Aave v4 "ZCHF / USD" feed on OP at the CREATE3 address below
 *           5. aave-v4 scripts/etherfi/zchf   — Timelock Safe: hub + spoke reserve listing through
 *              the EtherFiTimelock (generated in the aave-v4 repo, not here)
 *
 *         Address provenance: relay / sink / provider from 3CP 621/622 (WspyxPaxgProdConfig);
 *         tokens and aggregator verified on-chain 2026-09-17 (ZCHF: symbol/decimals on both
 *         chains; CHF / USD: decimals()/description()/latestRoundData()).
 */
library ZchfProd {
    // ---------------------------------------------------------------- Safes
    /// @dev Cash operating safe (ETH + OP): PRICE_PROVIDER_ADMIN_ROLE + PRICE_RELAY_ADMIN_ROLE on
    ///      the Ethereum RoleRegistry, ORACLE_SINK_ADMIN_ROLE on the Optimism RoleRegistry
    address internal constant OPERATING_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    // ---------------------------------------------------------------- tokens
    /// @dev ZCHF on Optimism — the Summer Lend underlying (AaveV4EtherfiCashAssets.ZCHF_UNDERLYING)
    address internal constant ZCHF_OP = 0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553;
    /// @dev ZCHF on Ethereum — the RelayPriceProvider / PriceRelay / OracleSink price KEY (the relay
    ///      ships mainnet token addresses), never bridged
    address internal constant ZCHF_MAINNET = 0xB58E61C3098d85632Df34EecfB899A1Ed80921cB;

    // ---------------------------------------------------------------- ETH relay stack (3CP 621)
    address internal constant PRICE_RELAY = 0xc4D666B44daa8D6d12b84875384e08BaE52aFE19;
    /// @dev The PriceProviderV2 instance the PriceRelay reads its sources from
    address internal constant RELAY_PRICE_PROVIDER = 0x12224C84783c66885cF838fcb189918d23B17f66;
    /// @dev Chainlink CHF / USD aggregator proxy on Ethereum, 8 decimals, 24h heartbeat / 0.15% deviation
    address internal constant CHF_USD_AGGREGATOR = 0x449d117117838fFA61263B61dA6301AA2a88B13A;
    /// @dev 24h heartbeat + 2h buffer — the bound PAXG / USD had on the relay in 3CP 621
    uint24 internal constant CHF_USD_RELAY_MAX_STALENESS = 26 hours;

    // ---------------------------------------------------------------- OP sink (3CP 622)
    /// @dev Prod OracleSink on Optimism, keyed by MAINNET token addresses, 6 decimals
    address internal constant ORACLE_SINK = 0x7cb68ddc781153d9417E08bAf6A64e801e398d42;
    /// @dev Fixed sink window (LendRails.ORACLE_SINK_MAX_STALENESS); the Aave feed bounds tighter
    uint64 internal constant ORACLE_SINK_MAX_STALENESS = 7 days;

    // ---------------------------------------------------------------- Aave v4 feed (OP)
    uint8 internal constant FEED_DECIMALS = 8;
    /// @dev Max age of the relay's source-chain read. The keeper full-pokes every 2h; 7 days = the bound of
    ///      EVERY live cash-v3 Summer Lend feed on OP (iwSPYx / iwQQQx / iwTBLLx / PAXG / SPY / QQQ / TBLL all
    ///      read rateMaxStaleness 604800, verified 2026-09-23) and of the OracleSink windows. The feed is
    ///      immutable, so a different bound means a fresh salt + address.
    uint256 internal constant ZCHF_RATE_MAX_STALENESS = 7 days;
    /// @dev CHF is not USD: no 1 USD snap
    bool internal constant ZCHF_IS_STABLE_TOKEN = false;
    string internal constant FEED_DESCRIPTION = "ZCHF / USD";
    /// @dev ADDRESS-AFFECTING: the CREATE3 salt of the feed (EtherFiDeployer). Changing it moves the
    ///      feed and the aave-v4 ZCHF_ORACLE pin with it.
    string internal constant FEED_SALT = "ZchfUsdFeed";
    /// @dev The address FEED_SALT resolves to through the prod EtherFiDeployer — pinned in aave-v4 as
    ///      AaveV4EtherfiCashAssets.ZCHF_ORACLE; DeployZchfProdFeed asserts the deployment lands here
    address internal constant EXPECTED_FEED = 0x7445E49137F073B836eB93Fd2929820d730b948C;
    /// @dev Fork-only rehearsal seed for a sink with no ZCHF entry yet (CHF / USD 1.213481, 6 decimals)
    uint256 internal constant SEED_PRICE_6DP = 1_213_481;
}

// ------------------------------------------------------------------ minimal external interfaces
// Local mirrors of the cash-mainnet-asset-listing surfaces the generators call (that repo is not a
// dependency here); signatures verified against the executed 3CP 621/622 calldata.

interface IPriceRelayLike {
    function subscribe(address token) external;
    function subscribedTokens() external view returns (address[] memory);
    function PRICE_RELAY_ADMIN_ROLE() external view returns (bytes32);
    function roleRegistry() external view returns (address);
}

interface IOracleSinkAdminLike {
    function setMaxStaleness(address token, uint64 maxStaleness_) external;
    function maxStaleness(address token) external view returns (uint64);
    function latestRoundData(address token) external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
    function ORACLE_SINK_ADMIN_ROLE() external view returns (bytes32);
    function roleRegistry() external view returns (address);
}

interface IRoleRegistryLike {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IRoleRegistryAwareLike {
    function roleRegistry() external view returns (address);
}
