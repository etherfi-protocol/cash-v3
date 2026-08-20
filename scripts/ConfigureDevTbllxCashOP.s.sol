// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { IAggregatorV3 } from "../src/interfaces/IAggregatorV3.sol";
import { ICashModule } from "../src/interfaces/ICashModule.sol";
import { IRoleRegistry } from "../src/interfaces/IRoleRegistry.sol";
import { PriceProviderV2 } from "../src/oracle/PriceProviderV2.sol";
import { StargateModule } from "../src/modules/stargate/StargateModule.sol";
import { Utils } from "./utils/Utils.sol";

/// @dev The prod OracleSink's USD-quoted read surface, used only for the composition cross-check.
interface IOracleSinkPrice {
    function price(address token) external view returns (uint256);
}

/**
 * @title ConfigureDevTbllxCashOP
 * @notice Optimism (dev) cash-side config for iwTBLLx, reusing the PROD token and the PROD
 *         OracleSink rather than standing up dev rails. The dev counterpart of txs 7-9 of the prod
 *         Optimism listing bundle (3CP-641) — the txs that make the cash stack understand the asset;
 *         txs 1-5 of that bundle (ShadowOFT deploy, rate limits, peer, enforced options) and tx 6
 *         (`OracleSink.setMaxStaleness`) are prod-side infra that dev shares as-is and neither needs
 *         nor is able to repeat.
 *
 *           1. PriceProviderV2.setTokenConfig — the TBLL/USD base entry plus iwTBLLx composed over
 *              it. Byte-identical in shape to the prod entries, pointing at the same Chainlink 24/5
 *              aggregator and the same prod OracleSink, so dev and prod price iwTBLLx identically.
 *           2. CashModule.configureWithdrawAssets — whitelist iwTBLLx as a withdrawable collateral
 *              asset.
 *           3. StargateModule.setAssetConfig — register iwTBLLx for Stargate-hop-free bridging.
 *
 *         ARRAY ORDER IN LEG 1 IS LOAD-BEARING: `_setTokenConfig` validates a dependent entry's
 *         `baseAsset` against configs written earlier in the SAME call, so TBLLx must be index 0 and
 *         iwTBLLx index 1.
 *
 *         Run BEFORE scripts/aave-v4/SupportTbllxCollateral.s.sol, whose DebtManager leg reads
 *         price(iwTBLLx) through the entry written here.
 *
 *         PREREQUISITE: the prod rails must be live — the prod iwTBLLx ShadowOFT deployed (3CP-641)
 *         and, for the composed price to actually resolve, `OracleSink.setMaxStaleness(wTBLLx, …)`
 *         executed and the relay keeper poked at least once. The config writes themselves do not
 *         need a delivered rate; the post-state price cross-check below is skipped, loudly, until
 *         one lands.
 *
 * Usage (simulate by dropping --broadcast; the broadcast wallet must hold PRICE_PROVIDER_ADMIN_ROLE,
 * CASH_MODULE_CONTROLLER_ROLE and STARGATE_MODULE_ADMIN_ROLE on the dev RoleRegistry):
 *   source .env && ENV=dev forge script \
 *     scripts/ConfigureDevTbllxCashOP.s.sol:ConfigureDevTbllxCashOP \
 *     --rpc-url $OPTIMISM_RPC --broadcast -vvvv
 */
contract ConfigureDevTbllxCashOP is Utils {
    /// @dev Mainnet TBLLx — a PriceProviderV2 price KEY only, never bridged. 1 TBLLx tracks 1 TBLL
    ///      share, so its mainnet address is the natural name for the "TBLL / USD" base entry.
    address constant TBLLX_MAINNET = 0x4cbf89ED7Bb30b8a860fa86d3c96E9c72931299b;
    /// @dev Mainnet wTBLLx — the OracleSink price key (the relay ships mainnet token addresses).
    address constant WTBLLX_MAINNET = 0x461b25b99606Fe169D6F0dD6816650eF6536403E;
    /// @dev PROD iwTBLLx ShadowOFT on Optimism (StockLendAssets.wtbllx().iToken).
    address constant IWTBLLX = 0x5F8b2D2b97aD4d63188f44965778F6004D5bc387;
    /// @dev PROD OracleSink on Optimism — holds the relayed wTBLLx -> TBLLx 4626 rate, 6 decimals.
    address constant PROD_ORACLE_SINK = 0x7cb68ddc781153d9417E08bAf6A64e801e398d42;
    /// @dev Chainlink TBLL/USD (24/5) proxy on Optimism, 8 decimals — the same aggregator prod reads.
    address constant TBLL_USD_FEED = 0x6D94824F8c4F5a168913669B9bD9071fAb39BFD2;

    /// @dev Mirrors the prod base-entry staleness for this asset (StockLendAssets.wtbllx()
    ///      cashBaseFeedMaxStaleness). 24/5 feed: must span the Friday-close -> Sunday-reopen gap,
    ///      sized against QQQ/USD's measured 57.66h worst case plus a Friday-holiday allowance.
    uint24 constant TBLL_USD_MAX_STALENESS = 78 hours;

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (10)");
        require(isEqualString(getEnv(), "dev"), "dev-only: the cash addresses are the dev deployments");
        require(IWTBLLX.code.length > 0, "prod iwTBLLx ShadowOFT has no code: the prod Optimism listing bundle has not executed");

        string memory deployments = readDeploymentFile();
        PriceProviderV2 priceProvider = PriceProviderV2(stdJson.readAddress(deployments, ".addresses.PriceProvider"));
        ICashModule cashModule = ICashModule(stdJson.readAddress(deployments, ".addresses.CashModule"));
        StargateModule stargateModule = StargateModule(payable(stdJson.readAddress(deployments, ".addresses.StargateModule")));
        IRoleRegistry roleRegistry = IRoleRegistry(stdJson.readAddress(deployments, ".addresses.RoleRegistry"));

        address sender = vm.addr(vm.envUint("PRIVATE_KEY"));
        require(roleRegistry.hasRole(priceProvider.ADMIN_TIMELOCK_ROLE(), sender), "sender lacks PRICE_PROVIDER_ADMIN_ROLE");
        require(roleRegistry.hasRole(cashModule.ADMIN_TIMELOCK_ROLE(), sender), "sender lacks CASH_MODULE_CONTROLLER_ROLE");
        require(roleRegistry.hasRole(stargateModule.ADMIN_TIMELOCK_ROLE(), sender), "sender lacks STARGATE_MODULE_ADMIN_ROLE");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // 1. TBLL/USD base entry + iwTBLLx composed over it. Base MUST be index 0 — see natspec.
        {
            (address[] memory tokens, PriceProviderV2.Config[] memory configs) = _priceConfigs();
            priceProvider.setTokenConfig(tokens, configs);
        }

        // 2. iwTBLLx as a withdrawable collateral asset
        {
            address[] memory assets = new address[](1);
            assets[0] = IWTBLLX;
            bool[] memory whitelist = new bool[](1);
            whitelist[0] = true;
            cashModule.configureWithdrawAssets(assets, whitelist);
        }

        // 3. iwTBLLx for Stargate-hop-free bridging (it is an OFT, so it is its own "pool")
        {
            address[] memory assets = new address[](1);
            assets[0] = IWTBLLX;
            StargateModule.AssetConfig[] memory configs = new StargateModule.AssetConfig[](1);
            configs[0] = StargateModule.AssetConfig({ isOFT: true, pool: IWTBLLX });
            stargateModule.setAssetConfig(assets, configs);
        }

        vm.stopBroadcast();

        _verify(priceProvider, cashModule, stargateModule);
    }

    function _priceConfigs() internal pure returns (address[] memory tokens, PriceProviderV2.Config[] memory configs) {
        tokens = new address[](2);
        tokens[0] = TBLLX_MAINNET;
        tokens[1] = IWTBLLX;

        configs = new PriceProviderV2.Config[](2);
        // TBLL/USD base: the local Chainlink 24/5 aggregator, USD-denominated (baseAsset == 0).
        configs[0] = PriceProviderV2.Config({ oracle: TBLL_USD_FEED, priceFunctionCalldata: "", isChainlinkType: true, oraclePriceDecimals: 8, maxStaleness: TBLL_USD_MAX_STALENESS, dataType: PriceProviderV2.ReturnType.Int256, isStableToken: false, baseAsset: address(0) });
        // iwTBLLx = relayed wTBLLx -> TBLLx rate (6 decimals, from the prod sink) x the TBLL/USD
        // base. The sink enforces its own staleness inside price(), so maxStaleness here is unused.
        configs[1] = PriceProviderV2.Config({ oracle: PROD_ORACLE_SINK, priceFunctionCalldata: abi.encodeWithSignature("price(address)", WTBLLX_MAINNET), isChainlinkType: false, oraclePriceDecimals: 6, maxStaleness: 0, dataType: PriceProviderV2.ReturnType.Uint256, isStableToken: false, baseAsset: TBLLX_MAINNET });
    }

    function _verify(PriceProviderV2 priceProvider, ICashModule cashModule, StargateModule stargateModule) internal view {
        (address[] memory tokens, PriceProviderV2.Config[] memory expected) = _priceConfigs();
        _assertTokenConfig(priceProvider.tokenConfig(tokens[0]), expected[0], "TBLL/USD base config");
        _assertTokenConfig(priceProvider.tokenConfig(tokens[1]), expected[1], "iwTBLLx config");

        require(_contains(cashModule.getWhitelistedWithdrawAssets(), IWTBLLX), "iwTBLLx missing from whitelisted withdraw assets");

        StargateModule.AssetConfig memory stargateConfig = stargateModule.getAssetConfig(IWTBLLX);
        require(stargateConfig.isOFT, "stargate isOFT mismatch");
        require(stargateConfig.pool == IWTBLLX, "stargate pool mismatch");

        // Gated on a relayed rate being present on the prod sink. Recomputed independently rather
        // than re-read from the contract under test, so it can catch a wiring mistake instead of
        // restating one: PriceProviderV2 composes rawPrice * basePrice / 1e8 for the 6-decimal sink
        // and 8-decimal Chainlink inputs here.
        try priceProvider.price(IWTBLLX) returns (uint256 composedUsd) {
            uint256 sinkRate = IOracleSinkPrice(PROD_ORACLE_SINK).price(WTBLLX_MAINNET);
            (, int256 usdAnswer,,,) = IAggregatorV3(TBLL_USD_FEED).latestRoundData();
            require(composedUsd == sinkRate * uint256(usdAnswer) / 1e8, "composed iwTBLLx price mismatch");
            console.log("price(iwTBLLx) [USD-6]:", composedUsd);
        } catch {
            console.log("[SKIP] no relayed wTBLLx rate on the prod sink yet; composed-USD check skipped");
        }

        console.log("iwTBLLx cash config done on dev:", IWTBLLX);
    }

    function _assertTokenConfig(PriceProviderV2.Config memory actual, PriceProviderV2.Config memory expected, string memory label) internal pure {
        require(actual.oracle == expected.oracle, string.concat(label, ": oracle mismatch"));
        require(keccak256(actual.priceFunctionCalldata) == keccak256(expected.priceFunctionCalldata), string.concat(label, ": priceFunctionCalldata mismatch"));
        require(actual.isChainlinkType == expected.isChainlinkType, string.concat(label, ": isChainlinkType mismatch"));
        require(actual.oraclePriceDecimals == expected.oraclePriceDecimals, string.concat(label, ": oraclePriceDecimals mismatch"));
        require(actual.maxStaleness == expected.maxStaleness, string.concat(label, ": maxStaleness mismatch"));
        require(actual.dataType == expected.dataType, string.concat(label, ": dataType mismatch"));
        require(actual.isStableToken == expected.isStableToken, string.concat(label, ": isStableToken mismatch"));
        require(actual.baseAsset == expected.baseAsset, string.concat(label, ": baseAsset mismatch"));
    }

    function _contains(address[] memory arr, address needle) internal pure returns (bool) {
        for (uint256 i; i < arr.length; ++i) {
            if (arr[i] == needle) return true;
        }
        return false;
    }
}
