// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { StargateModule } from "../../src/modules/stargate/StargateModule.sol";

import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/// @dev cash-mainnet-asset-listing's ShadowOFTFactory admin surface. cash-v3 has no ShadowOFT code of
///      its own (destination-chain iTOKENs are minted by that repo's beacon factory), so this is a
///      minimal local mirror, not an import - this bundle takes no cross-repo dependency.
interface IShadowOFTFactory {
    function SHADOW_OFT_FACTORY_ADMIN_ROLE() external view returns (bytes32);
    function deployShadowOFT(bytes32 salt, string calldata name, string calldata symbol, uint8 decimals, address delegate) external returns (address);
    function isShadowOFT(address account) external view returns (bool);
    function getDeterministicAddress(bytes32 salt) external view returns (address);
}

/// @dev Full surface this script needs off a deployed ShadowOFT: LayerZero OApp wiring plus the
///      ERC-20 metadata, which is the only readback proving the right asset landed under each salt
///      (a ShadowOFT has no on-chain binding to its underlying).
interface IShadowOFTOApp {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function owner() external view returns (address);
    function setPeer(uint32 eid, bytes32 peer) external;
    function peers(uint32 eid) external view returns (bytes32);
}

/// @dev Pairwise (both-direction) OFT rate limiter admin surface; cash-v3 has no OFT bridges of its
///      own on this chain, so this is a minimal local mirror of the setters/getters, not an import.
interface IPairwiseRateLimiter {
    struct RateLimitConfig {
        uint32 peerEid;
        uint256 limit;
        uint256 window;
    }

    struct RateLimit {
        uint256 amountInFlight;
        uint256 lastUpdated;
        uint256 limit;
        uint256 window;
    }

    function setOutboundRateLimits(RateLimitConfig[] calldata rateLimitConfigs) external;
    function setInboundRateLimits(RateLimitConfig[] calldata rateLimitConfigs) external;
    function outboundRateLimit(uint32 peerEid) external view returns (RateLimit memory);
    function inboundRateLimit(uint32 peerEid) external view returns (RateLimit memory);
}

/// @dev cash-mainnet-asset-listing OracleSink admin + price surface, keyed by the MAINNET underlying,
///      never the iTOKEN. cash-v3's own {IOracleSink} is the read-only Chainlink-shaped slice
///      {OracleSinkPriceFeed} consumes; this is the separate admin surface that slice doesn't need.
interface IOracleSinkAdmin {
    function ORACLE_SINK_ADMIN_ROLE() external view returns (bytes32);
    function setMaxStaleness(address token, uint64 maxStaleness_) external;
    function maxStaleness(address token) external view returns (uint64);
    function price(address token) external view returns (uint256);
}

/// @title ListFastTrackAssetsOptimism
/// @notice 3CP 622 - the WHOLE Optimism-side prod bundle for the wSPYx + PAXG fast-track listing
///         (COR-1206), executed by the OperatingSafe in a single Safe transaction (multisend).
///         Deploys iwSPYx/iPAXG via the live {ShadowOFTFactory}, wires their pairwise rate limits +
///         LayerZero peers to each Ethereum OFT adapter, sets the {OracleSink} staleness windows,
///         then wires both iTOKENs into cash's own PriceProviderV2, the CashModule cross-chain
///         withdraw whitelist, and StargateModule. DebtManager collateral support is deliberately NOT
///         here - borrowing against these assets ships with the separate Lend 3CP.
///
///         *** EXECUTION ORDER (operational instruction, not a code gate) ***
///         Runs SECOND, after 3CP 621 (Ethereum: OFT adapter deploys + TopUp config) has executed,
///         and only after the off-chain keeper has relayed both assets' prices from mainnet
///         PriceProvider to this chain's OracleSink over LayerZero and both prices have been
///         confirmed fresh (OracleSink.getPrice(canonical) for wSPYx and PAXG). NOTE: with the
///         DebtManager leg removed, no transaction in this bundle actually READS a price -
///         PriceProviderV2.setTokenConfig validates config shape only - so the relay is no longer a
///         hard precondition for this bundle to execute. It remains required before users can be
///         valued or borrow. Every signer signs both 3CPs up front; ordering is operational, not a
///         generation-time gate in either script.
///
///         Deliberately contains NO Aave/Lend calls: the Aave instance uses a different Safe and its
///         spoke/configurator/AccessManager get their own 3CP later.
///
/// @dev A multisend runs sequentially, so the deploy txs (1-2) land before anything touching the
///      resulting ShadowOFT addresses (3-10), which land before the cash-protocol wiring (11-13) that
///      needs the sink staleness windows already set (9-10) to read a non-stale price. The iTOKENs do
///      not exist yet when this bundle is generated, and a CALL to a codeless address returns success,
///      so every ShadowOFT-side check below (rate limits, peers, metadata) is a POST-simulation
///      assertion reading real state back off the deployed contracts, not a pre-build guess.
///
///      CREATE3 salts key off the mainnet underlying (keccak256(abi.encode("EtherFiOFT", underlying))),
///      matching the Ethereum-side OFTAdapterFactory salt convention, so both scripts derive the same
///      salt independently. Delegate is the OperatingSafe itself, so it is the iTOKEN's OApp owner
///      immediately with no EOA handoff step. Rate limit sizing (1000 wSPYx/hr, 300 PAXG/hr) is kept
///      in sync with the identical constants on the Ethereum-side adapters, set pairwise (outbound +
///      inbound, same limit/window) so a transfer that clears the source side can never strand on the
///      destination.
///
///      Run: source .env && ENV=mainnet forge script scripts/gnosis-txs/ListFastTrackAssetsOptimism.s.sol:ListFastTrackAssetsOptimism --rpc-url optimism -vvv
///      A fork run needs nothing seeded: the bundle deploys the iTOKENs itself in txs 1-2 and sets
///      staleness at txs 9-10, and no tx reads a price. SIMULATE_MISSING_RAILS remains only to seed a
///      sink price so the post-state assertions can check the composed USD values.
contract ListFastTrackAssetsOptimism is Utils, GnosisHelpers, Test {
    address constant cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    uint32 constant ETH_EID = 30_101;

    address constant IWSPYX = 0xc1e636Aae7d6B46229FC2C362d562610519e8D7c;
    address constant IPAXG = 0x41a7f2bb9789199654c206f09392674c1Af6676c;
    address constant WSPYX_MAINNET = 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540;
    address constant PAXG_MAINNET = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;
    /// @dev Mainnet SPYx, used purely as an address KEY on PriceProviderV2 for the SPY/USD base entry
    ///      (V2 base assets are keyed by an arbitrary address; see PriceProviderV2 NatSpec).
    address constant SPYX_MAINNET = 0x90A2a4c76b5D8c0bc892A69EA28Aa775a8f2dD48;
    /// @dev Chainlink SPY/USD (24/5) aggregator on Optimism, 8 decimals.
    address constant SPY_USD_FEED = 0x5F77134CfAA7DB2906649Ca21C50dA54daE9291d;
    /// @dev cash-mainnet-asset-listing OracleSink (prod infra OP) - relays mainnet PriceProvider
    ///      prices over LayerZero, keyed by the MAINNET token address.
    address constant ORACLE_SINK = 0x7cb68ddc781153d9417E08bAf6A64e801e398d42;
    address constant SHADOW_OFT_FACTORY = 0xBD17E3ec1d5c49abe59F64F4bCe1D663fD28d983;

    /// @dev Prod Ethereum OFT adapters, CREATE3-predicted at OFTAdapterFactory 0x6d1e7e56...
    ///      (confirmed address book; deployed by the sibling 3CP 621 Ethereum bundle). Hardcoded: no
    ///      manifest in this repo tracks a chain-1 deployment.
    address constant WSPYX_ADAPTER_ETH = 0xB3b3412E3D367D26B6f37ddf74eECb7de8827318;
    address constant PAXG_ADAPTER_ETH = 0xB20A9C1fCE74EC335F5DbF30720E3b628bdE49f9;

    bytes32 constant WSPYX_SALT = 0x1814057c4bb638f431a2a2377e3f118194c09ddb8fda14c36388fc7f0b2f92a2;
    bytes32 constant PAXG_SALT = 0x106983519c65f117fffaddcbacad0f94e838caf53717dfcd5dd6883de6aaf27c;

    /// @dev ERC-20 metadata, matching ListWspyxOptimism/ListPaxgOptimism (dev listing scripts) exactly.
    string constant WSPYX_NAME = "EtherFi Wrapped SP500 xStock";
    string constant WSPYX_SYMBOL = "iwSPYx";
    string constant PAXG_NAME = "EtherFi PAXG";
    string constant PAXG_SYMBOL = "iPAXG";
    /// @dev Mirrors both mainnet underlyings' decimals() (18).
    uint8 constant SHADOW_DECIMALS = 18;

    /// @dev Throughput caps, matched pairwise with the Ethereum-side adapter limits so neither
    ///      direction can strand a transfer the other side would have allowed through.
    uint256 constant WSPYX_RATE_LIMIT_TOKENS = 1000;
    uint256 constant PAXG_RATE_LIMIT_TOKENS = 300;
    uint256 constant RATE_WINDOW = 1 hours;

    /// @dev 24/5 feed: must survive the Friday-close -> Sunday reopen gap (~65h) with buffer.
    uint24 constant SPY_USD_MAX_STALENESS = 78 hours;

    uint64 constant WSPYX_MAX_STALENESS = 7 days;
    uint64 constant PAXG_MAX_STALENESS = 2 days;

    /// @dev Seeded OracleSink rate for simulation only. _verify() reads the sink's live rate directly
    ///      rather than these, so it holds against a real relay price too.
    uint256 constant WSPYX_SEED_RATE_6DP = 1e6;
    uint256 constant PAXG_SEED_PRICE_6DP = 4036e6;


    address priceProvider;
    address cashModule;
    address stargateModule;

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (chain ID 10)");
        require(isEqualString(getEnv(), "mainnet"), "ENV must be mainnet");

        string memory deployments = readDeploymentFile();
        address roleRegistry = stdJson.readAddress(deployments, ".addresses.RoleRegistry");
        priceProvider = stdJson.readAddress(deployments, ".addresses.PriceProvider");
        cashModule = stdJson.readAddress(deployments, ".addresses.CashModule");
        stargateModule = stdJson.readAddress(deployments, ".addresses.StargateModule");

        require(
            RoleRegistry(roleRegistry).hasRole(IShadowOFTFactory(SHADOW_OFT_FACTORY).SHADOW_OFT_FACTORY_ADMIN_ROLE(), cashControllerSafe),
            "OperatingSafe does not hold SHADOW_OFT_FACTORY_ADMIN_ROLE; this bundle would revert"
        );
        require(
            RoleRegistry(roleRegistry).hasRole(IOracleSinkAdmin(ORACLE_SINK).ORACLE_SINK_ADMIN_ROLE(), cashControllerSafe),
            "OperatingSafe does not hold ORACLE_SINK_ADMIN_ROLE; this bundle would revert"
        );

        // CREATE3 address depends only on (factory, salt); prove the predicted address matches the
        // address book and is not already deployed BEFORE building the bundle, so a wrong
        // salt/factory or a stale re-run is caught here rather than after the Safe has signed.
        require(keccak256(abi.encode("EtherFiOFT", WSPYX_MAINNET)) == WSPYX_SALT, "wSPYx salt derivation mismatch");
        require(keccak256(abi.encode("EtherFiOFT", PAXG_MAINNET)) == PAXG_SALT, "PAXG salt derivation mismatch");
        require(IShadowOFTFactory(SHADOW_OFT_FACTORY).getDeterministicAddress(WSPYX_SALT) == IWSPYX, "iwSPYx CREATE3 prediction does not match address book");
        require(IShadowOFTFactory(SHADOW_OFT_FACTORY).getDeterministicAddress(PAXG_SALT) == IPAXG, "iPAXG CREATE3 prediction does not match address book");
        require(!IShadowOFTFactory(SHADOW_OFT_FACTORY).isShadowOFT(IWSPYX), "iwSPYx already listed");
        require(!IShadowOFTFactory(SHADOW_OFT_FACTORY).isShadowOFT(IPAXG), "iPAXG already listed");

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(cashControllerSafe));

        // 1-2. Deploy iwSPYx then iPAXG via the live ShadowOFTFactory.
        txs = string(abi.encodePacked(txs, _deployShadowTx(WSPYX_SALT, WSPYX_NAME, WSPYX_SYMBOL)));
        txs = string(abi.encodePacked(txs, _deployShadowTx(PAXG_SALT, PAXG_NAME, PAXG_SYMBOL)));

        // 3-6. Outbound + inbound pairwise rate limits, peerEid = ETH_EID.
        txs = string(abi.encodePacked(txs, _rateLimitTxs(IWSPYX, WSPYX_RATE_LIMIT_TOKENS)));
        txs = string(abi.encodePacked(txs, _rateLimitTxs(IPAXG, PAXG_RATE_LIMIT_TOKENS)));

        // 7-8. LayerZero peer -> each asset's Ethereum OFT adapter.
        txs = string(abi.encodePacked(txs, _peerTx(IWSPYX, WSPYX_ADAPTER_ETH)));
        txs = string(abi.encodePacked(txs, _peerTx(IPAXG, PAXG_ADAPTER_ETH)));

        // 9-10. OracleSink staleness windows, keyed by the MAINNET underlying, never the iTOKEN - a
        // wrong key here leaves IOracleSinkAdmin.price reverting for the token everyone actually
        // queries. Must precede tx 11-13: OracleSink.price reverts PriceStale while maxStaleness is 0.
        string memory setWspyxStaleness = iToHex(abi.encodeCall(IOracleSinkAdmin.setMaxStaleness, (WSPYX_MAINNET, WSPYX_MAX_STALENESS)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(ORACLE_SINK), setWspyxStaleness, "0", false)));
        string memory setPaxgStaleness = iToHex(abi.encodeCall(IOracleSinkAdmin.setMaxStaleness, (PAXG_MAINNET, PAXG_MAX_STALENESS)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(ORACLE_SINK), setPaxgStaleness, "0", false)));

        // 11. PriceProviderV2. The SPY/USD base entry must precede iwSPYx in this array:
        // setTokenConfig validates a dependent entry's baseAsset against configs already stored
        // earlier in the SAME call. iPAXG has no base (the sink already relays a full USD price).
        {
            address[] memory tokens = new address[](3);
            tokens[0] = SPYX_MAINNET;
            tokens[1] = IWSPYX;
            tokens[2] = IPAXG;

            PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](3);
            configs[0] = PriceProviderV2.Config({ oracle: SPY_USD_FEED, priceFunctionCalldata: "", isChainlinkType: true, oraclePriceDecimals: 8, maxStaleness: SPY_USD_MAX_STALENESS, dataType: PriceProviderV2.ReturnType.Int256, isStableToken: false, baseAsset: address(0) });
            configs[1] = PriceProviderV2.Config({ oracle: ORACLE_SINK, priceFunctionCalldata: abi.encodeWithSignature("price(address)", WSPYX_MAINNET), isChainlinkType: false, oraclePriceDecimals: 6, maxStaleness: 0, dataType: PriceProviderV2.ReturnType.Uint256, isStableToken: false, baseAsset: SPYX_MAINNET });
            configs[2] = PriceProviderV2.Config({ oracle: ORACLE_SINK, priceFunctionCalldata: abi.encodeWithSignature("price(address)", PAXG_MAINNET), isChainlinkType: false, oraclePriceDecimals: 6, maxStaleness: 0, dataType: PriceProviderV2.ReturnType.Uint256, isStableToken: false, baseAsset: address(0) });

            string memory data = iToHex(abi.encodeWithSelector(PriceProviderV2.setTokenConfig.selector, tokens, configs));
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(priceProvider), data, "0", false)));
        }

        // 12. CashModule: whitelist both iTOKENs for cross-chain withdraw.
        {
            address[] memory assets = new address[](2);
            assets[0] = IWSPYX;
            assets[1] = IPAXG;
            bool[] memory shouldWhitelist = new bool[](2);
            shouldWhitelist[0] = true;
            shouldWhitelist[1] = true;

            string memory data = iToHex(abi.encodeWithSelector(ICashModule.configureWithdrawAssets.selector, assets, shouldWhitelist));
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), data, "0", false)));
        }

        // 13. StargateModule last: _setAssetConfigs calls IStargate(pool).token() and reverts loudly
        // if the iTOKEN has no code yet. Keeping it last means the whole atomic bundle - not just
        // this call - only lands once both iTOKENs are actually live, which is the desired gate.
        {
            address[] memory assets = new address[](2);
            assets[0] = IWSPYX;
            assets[1] = IPAXG;
            StargateModule.AssetConfig[] memory assetConfigs = new StargateModule.AssetConfig[](2);
            assetConfigs[0] = StargateModule.AssetConfig({ isOFT: true, pool: IWSPYX });
            assetConfigs[1] = StargateModule.AssetConfig({ isOFT: true, pool: IPAXG });

            string memory data = iToHex(abi.encodeWithSelector(StargateModule.setAssetConfig.selector, assets, assetConfigs));
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(stargateModule), data, "0", true)));
        }

        vm.createDir("./output", true);
        string memory path = "./output/ListFastTrackAssetsOptimism-10.json";
        vm.writeFile(path, txs);
        console.log("Bundle written to:", path);

        // Opt-in only, and no longer load-bearing for execution: no tx in this bundle reads a price.
        // Seeds a sink price on the fork so the post-state assertions can verify the composed USD
        // values rather than skipping them.
        if (vm.envOr("SIMULATE_MISSING_RAILS", false)) {
            _seedOracleSinkPriceForSimulation();
        }

        executeGnosisTransactionBundle(path);
        console.log("Simulation OK");

        _verify();
    }

    function _deployShadowTx(bytes32 salt, string memory name, string memory symbol) internal pure returns (string memory) {
        string memory data = iToHex(abi.encodeCall(IShadowOFTFactory.deployShadowOFT, (salt, name, symbol, SHADOW_DECIMALS, cashControllerSafe)));
        return _getGnosisTransaction(addressToHex(SHADOW_OFT_FACTORY), data, "0", false);
    }

    /// @dev Sets both directions of the pathway to the SAME limit/window, so a transfer that clears
    ///      the source side can never strand on the destination (docs/runbook.md sizing rule).
    function _rateLimitTxs(address shadowOFT, uint256 limitTokens) internal pure returns (string memory) {
        IPairwiseRateLimiter.RateLimitConfig[] memory cfg = new IPairwiseRateLimiter.RateLimitConfig[](1);
        cfg[0] = IPairwiseRateLimiter.RateLimitConfig({ peerEid: ETH_EID, limit: limitTokens * (10 ** SHADOW_DECIMALS), window: RATE_WINDOW });
        string memory outboundData = iToHex(abi.encodeCall(IPairwiseRateLimiter.setOutboundRateLimits, (cfg)));
        string memory txs = _getGnosisTransaction(addressToHex(shadowOFT), outboundData, "0", false);
        string memory inboundData = iToHex(abi.encodeCall(IPairwiseRateLimiter.setInboundRateLimits, (cfg)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(shadowOFT), inboundData, "0", false)));
        return txs;
    }

    function _peerTx(address shadowOFT, address ethAdapter) internal pure returns (string memory) {
        bytes32 peer = bytes32(uint256(uint160(ethAdapter)));
        string memory data = iToHex(abi.encodeCall(IShadowOFTOApp.setPeer, (ETH_EID, peer)));
        return _getGnosisTransaction(addressToHex(shadowOFT), data, "0", false);
    }

    /// @dev OracleSink price delivery is a separate off-chain LayerZero relay this bundle does not
    ///      send (out of scope - see file header). Seeded on the fork purely so the post-state
    ///      assertions can check the composed USD values. Staleness is NOT seeded: this bundle sets it
    ///      for real at txs 9-10.
    function _seedOracleSinkPriceForSimulation() internal {
        _pokeOracleSinkPrice(WSPYX_MAINNET, WSPYX_SEED_RATE_6DP);
        _pokeOracleSinkPrice(PAXG_MAINNET, PAXG_SEED_PRICE_6DP);
    }

    function _verify() internal view {
        require(IWSPYX.code.length > 0, "iwSPYx has no code after simulation");
        require(IPAXG.code.length > 0, "iPAXG has no code after simulation");
        require(IShadowOFTFactory(SHADOW_OFT_FACTORY).isShadowOFT(IWSPYX), "iwSPYx not registered as a ShadowOFT after simulation");
        require(IShadowOFTFactory(SHADOW_OFT_FACTORY).isShadowOFT(IPAXG), "iPAXG not registered as a ShadowOFT after simulation");

        // initialize() is initializer-gated with no setter, so this is the only chance to catch a
        // copy-paste swap of the two name/symbol pairs or a wrong decimals before it is permanent.
        _requireShadowMetadata(IWSPYX, WSPYX_NAME, WSPYX_SYMBOL);
        _requireShadowMetadata(IPAXG, PAXG_NAME, PAXG_SYMBOL);

        _assertRateLimits(IWSPYX, WSPYX_RATE_LIMIT_TOKENS);
        _assertRateLimits(IPAXG, PAXG_RATE_LIMIT_TOKENS);
        require(IShadowOFTOApp(IWSPYX).peers(ETH_EID) == bytes32(uint256(uint160(WSPYX_ADAPTER_ETH))), "iwSPYx peer not wired");
        require(IShadowOFTOApp(IPAXG).peers(ETH_EID) == bytes32(uint256(uint160(PAXG_ADAPTER_ETH))), "iPAXG peer not wired");
        require(IOracleSinkAdmin(ORACLE_SINK).maxStaleness(WSPYX_MAINNET) == WSPYX_MAX_STALENESS, "wSPYx staleness not set");
        require(IOracleSinkAdmin(ORACLE_SINK).maxStaleness(PAXG_MAINNET) == PAXG_MAX_STALENESS, "PAXG staleness not set");
        console.log("  [OK] ShadowOFT deploy + rate limits + peers + oracle staleness");

        // SPY/USD base entry checked directly, not just through its downstream effect on
        // iwSPYx's price(): a wrong maxStaleness here can still pass a same-day fork sim (the live
        // feed answer happens to be fresh enough) and only revert PriceStale once the real gap opens.
        PriceProviderV2.Config memory spyCfg = PriceProviderV2(priceProvider).tokenConfig(SPYX_MAINNET);
        require(spyCfg.oracle == SPY_USD_FEED && spyCfg.baseAsset == address(0), "SPY/USD base config mismatch");
        require(spyCfg.isChainlinkType && spyCfg.oraclePriceDecimals == 8 && spyCfg.maxStaleness == SPY_USD_MAX_STALENESS && spyCfg.dataType == PriceProviderV2.ReturnType.Int256, "SPY/USD base config fields mismatch");

        PriceProviderV2.Config memory wspyxCfg = PriceProviderV2(priceProvider).tokenConfig(IWSPYX);
        require(wspyxCfg.oracle == ORACLE_SINK && wspyxCfg.baseAsset == SPYX_MAINNET, "iwSPYx price config mismatch");
        require(keccak256(wspyxCfg.priceFunctionCalldata) == keccak256(abi.encodeWithSignature("price(address)", WSPYX_MAINNET)), "iwSPYx price calldata mismatch");
        require(!wspyxCfg.isChainlinkType && wspyxCfg.oraclePriceDecimals == 6 && wspyxCfg.dataType == PriceProviderV2.ReturnType.Uint256 && !wspyxCfg.isStableToken, "iwSPYx price config fields mismatch");

        PriceProviderV2.Config memory paxgCfg = PriceProviderV2(priceProvider).tokenConfig(IPAXG);
        require(paxgCfg.oracle == ORACLE_SINK && paxgCfg.baseAsset == address(0), "iPAXG price config mismatch");
        require(keccak256(paxgCfg.priceFunctionCalldata) == keccak256(abi.encodeWithSignature("price(address)", PAXG_MAINNET)), "iPAXG price calldata mismatch");
        require(!paxgCfg.isChainlinkType && paxgCfg.oraclePriceDecimals == 6 && paxgCfg.dataType == PriceProviderV2.ReturnType.Uint256 && !paxgCfg.isStableToken, "iPAXG price config fields mismatch");
        console.log("  [OK] PriceProviderV2 token configs set");

        // Reads the sink's current rate directly (seeded on the fork, live in a real run) so this
        // holds either way, then recomposes it via PriceProviderV2's baseAsset formula:
        // rawPrice * basePrice / 10**oraclePriceDecimals(SPY feed).
        uint256 wspyxRate = IOracleSinkAdmin(ORACLE_SINK).price(WSPYX_MAINNET);
        (, int256 spyUsdAnswer, , , ) = IAggregatorV3(SPY_USD_FEED).latestRoundData();
        uint256 expectedWspyxPrice = (wspyxRate * uint256(spyUsdAnswer)) / 1e8;
        uint256 wspyxPrice = PriceProviderV2(priceProvider).price(IWSPYX);
        require(wspyxPrice == expectedWspyxPrice, "iwSPYx price did not match expected");
        console.log("  [OK] iwSPYx price =", wspyxPrice);

        uint256 expectedPaxgPrice = IOracleSinkAdmin(ORACLE_SINK).price(PAXG_MAINNET);
        uint256 paxgPrice = PriceProviderV2(priceProvider).price(IPAXG);
        require(paxgPrice == expectedPaxgPrice, "iPAXG price did not match expected");
        console.log("  [OK] iPAXG price =", paxgPrice);

        address[] memory whitelisted = ICashModule(cashModule).getWhitelistedWithdrawAssets();
        require(_contains(whitelisted, IWSPYX) && _contains(whitelisted, IPAXG), "withdraw whitelist missing iTOKENs");
        console.log("  [OK] CashModule withdraw whitelist set");

        StargateModule.AssetConfig memory wspyxStg = StargateModule(payable(stargateModule)).getAssetConfig(IWSPYX);
        require(wspyxStg.isOFT && wspyxStg.pool == IWSPYX, "wSPYx stargate config mismatch");
        StargateModule.AssetConfig memory paxgStg = StargateModule(payable(stargateModule)).getAssetConfig(IPAXG);
        require(paxgStg.isOFT && paxgStg.pool == IPAXG, "PAXG stargate config mismatch");
        console.log("  [OK] StargateModule asset config set");
    }

    function _requireShadowMetadata(address shadowOFT, string memory name, string memory symbol) internal view {
        IShadowOFTOApp token = IShadowOFTOApp(shadowOFT);
        require(isEqualString(token.name(), name), "iTOKEN name mismatch");
        require(isEqualString(token.symbol(), symbol), "iTOKEN symbol mismatch");
        require(token.decimals() == SHADOW_DECIMALS, "iTOKEN decimals mismatch");
        require(token.owner() == cashControllerSafe, "iTOKEN owner is not the OperatingSafe");
    }

    function _assertRateLimits(address shadowOFT, uint256 limitTokens) internal view {
        uint256 expected = limitTokens * (10 ** SHADOW_DECIMALS);
        IPairwiseRateLimiter.RateLimit memory out = IPairwiseRateLimiter(shadowOFT).outboundRateLimit(ETH_EID);
        IPairwiseRateLimiter.RateLimit memory in_ = IPairwiseRateLimiter(shadowOFT).inboundRateLimit(ETH_EID);
        require(out.limit == expected && out.window == RATE_WINDOW, "outbound rate limit not set");
        require(in_.limit == expected && in_.window == RATE_WINDOW, "inbound rate limit not set");
    }

    function _contains(address[] memory arr, address target) internal pure returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == target) return true;
        }
        return false;
    }

    /// @dev Writes a fresh OracleSink PricePoint directly into its ERC-7201 storage slot, standing in
    ///      for the LayerZero-delivered relay message this bundle does not send. Layout per
    ///      cash-mainnet-asset-listing's OracleSink: `latest` mapping at the storage root, each
    ///      PricePoint packed as {uint256 price}{uint64 updatedAt | uint64 srcUpdatedAt}.
    function _pokeOracleSinkPrice(address token, uint256 price6dp) internal {
        bytes32 base = 0x3e8ab8ffffa6cdbcb3cadbd9bce96c661061ed9516d20cf2ac88617c984e9200;
        bytes32 priceSlot = keccak256(abi.encode(token, base));
        vm.store(ORACLE_SINK, priceSlot, bytes32(price6dp));
        uint256 ts = block.timestamp;
        vm.store(ORACLE_SINK, bytes32(uint256(priceSlot) + 1), bytes32(ts | (ts << 64)));
    }
}
