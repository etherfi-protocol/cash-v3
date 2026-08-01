// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IAccessManager } from "aave-v4/dependencies/openzeppelin/IAccessManager.sol";
import { IAssetInterestRateStrategy } from "aave-v4/hub/interfaces/IAssetInterestRateStrategy.sol";
import { IHub } from "aave-v4/hub/interfaces/IHub.sol";
import { ISpoke } from "aave-v4/spoke/interfaces/ISpoke.sol";

import { Utils } from "../utils/Utils.sol";
import { AaveV4DevRoles } from "./AaveV4DevRoles.sol";

/**
 * @title SyncDevMarketConfigWithProd
 * @notice Aligns the dev Aave v4 test instance's market config (spoke/hub from
 *         deployments/<env>/10/aave-v4-test.json) with the live prod whitelabel instance on
 *         OP Mainnet: per-reserve collateral factor / liquidation bonus / liquidation fee,
 *         borrowable flags (WETH becomes borrowable next to USDC), hub liquidity fees, interest
 *         rate curves, spoke add/draw caps and risk premium threshold, and the spoke liquidation
 *         config. The dev-only reserves (iwSPYx and the legacy liquidRESERVE OFT) are left
 *         untouched, as are the dev fee receiver, oracle sources, and irStrategy wiring.
 * @dev Values below were read from the live prod hub/spoke/irStrategy at OP block 154956068
 *      (2026-07-31) and cross-checked against the fork's scripts/etherfi/LAUNCH_SPEC.md — they
 *      matched exactly. Caps are whole-token (uint40). Idempotent: every setter writes absolute
 *      values, so the script can be re-run after a partial broadcast.
 *
 * Usage (simulate by dropping --broadcast; the sender must hold the instance admin roles):
 *   source .env && ENV=dev FOUNDRY_PROFILE=aave-deploy forge script \
 *     scripts/aave-v4/SyncDevMarketConfigWithProd.s.sol:SyncDevMarketConfigWithProd \
 *     --rpc-url $OPTIMISM_RPC --account dev-admin \
 *     --sender <dev admin address> --broadcast -vvvv
 */
contract SyncDevMarketConfigWithProd is Utils {
    struct ProdReserveParams {
        address underlying;
        uint16 collateralFactor; // BPS
        uint32 maxLiquidationBonus; // BPS, 100_00 = no bonus
        uint16 liquidationFee; // BPS
        bool borrowable;
        uint16 liquidityFee; // BPS
        uint16 optimalUsageRatio; // BPS
        uint32 baseDrawnRate; // BPS
        uint32 rateGrowthBeforeOptimal; // BPS
        uint32 rateGrowthAfterOptimal; // BPS
        uint40 addCap; // whole tokens
        uint40 drawCap; // whole tokens
    }

    // Prod spoke liquidation config
    uint128 constant TARGET_HEALTH_FACTOR = 1.24e18;
    uint64 constant HEALTH_FACTOR_FOR_MAX_BONUS = 0.9e18;
    uint16 constant LIQUIDATION_BONUS_FACTOR = 0;
    // Prod spoke risk premium threshold (dev was deployed with the no-threshold sentinel)
    uint24 constant RISK_PREMIUM_THRESHOLD = 0;

    IHub hub;
    ISpoke spoke;
    IAccessManager accessManager;

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (10)");
        require(isEqualString(vm.envOr("FOUNDRY_PROFILE", string("default")), "aave-deploy"), "Run with FOUNDRY_PROFILE=aave-deploy (library linking)");

        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/aave-v4-test.json"));
        hub = IHub(stdJson.readAddress(json, ".hub"));
        spoke = ISpoke(stdJson.readAddress(json, ".spoke"));
        accessManager = IAccessManager(stdJson.readAddress(json, ".accessManager"));

        vm.startBroadcast();

        // Selectors not mapped at instance deploy
        bytes4[] memory hubSelectors = new bytes4[](2);
        hubSelectors[0] = IHub.setInterestRateData.selector;
        hubSelectors[1] = IHub.updateSpokeConfig.selector;
        accessManager.setTargetFunctionRole(address(hub), hubSelectors, AaveV4DevRoles.HUB_ADMIN_ROLE);
        bytes4[] memory spokeSelectors = new bytes4[](1);
        spokeSelectors[0] = ISpoke.updateReserveConfig.selector;
        accessManager.setTargetFunctionRole(address(spoke), spokeSelectors, AaveV4DevRoles.SPOKE_ADMIN_ROLE);

        spoke.updateLiquidationConfig(ISpoke.LiquidationConfig({ targetHealthFactor: TARGET_HEALTH_FACTOR, healthFactorForMaxBonus: HEALTH_FACTOR_FOR_MAX_BONUS, liquidationBonusFactor: LIQUIDATION_BONUS_FACTOR }));

        ProdReserveParams[19] memory params = _prodParams();
        for (uint256 i; i < params.length; ++i) {
            _sync(params[i]);
        }

        vm.stopBroadcast();
    }

    function _sync(ProdReserveParams memory p) internal {
        uint256 reserveId = _reserveIdOf(p.underlying);
        ISpoke.Reserve memory reserve = spoke.getReserve(reserveId);
        uint256 assetId = reserve.assetId;

        spoke.updateDynamicReserveConfig(reserveId, reserve.dynamicConfigKey, ISpoke.DynamicReserveConfig({ collateralFactor: p.collateralFactor, maxLiquidationBonus: p.maxLiquidationBonus, liquidationFee: p.liquidationFee }));

        // Patch only borrowable; keep the reserve's live pause/freeze/shares/risk state
        ISpoke.ReserveConfig memory reserveConfig = spoke.getReserveConfig(reserveId);
        reserveConfig.borrowable = p.borrowable;
        spoke.updateReserveConfig(reserveId, reserveConfig);

        // Patch only the liquidity fee; the fee receiver and irStrategy stay the dev ones
        IHub.AssetConfig memory assetConfig = hub.getAssetConfig(assetId);
        assetConfig.liquidityFee = p.liquidityFee;
        hub.updateAssetConfig(assetId, assetConfig, new bytes(0));

        hub.setInterestRateData(assetId, abi.encode(IAssetInterestRateStrategy.InterestRateData({ optimalUsageRatio: p.optimalUsageRatio, baseDrawnRate: p.baseDrawnRate, rateGrowthBeforeOptimal: p.rateGrowthBeforeOptimal, rateGrowthAfterOptimal: p.rateGrowthAfterOptimal })));

        hub.updateSpokeConfig(assetId, address(spoke), IHub.SpokeConfig({ addCap: p.addCap, drawCap: p.drawCap, riskPremiumThreshold: RISK_PREMIUM_THRESHOLD, active: true, halted: false }));

        console.log("synced:", IERC20Metadata(p.underlying).symbol(), reserveId);
    }

    function _reserveIdOf(address token) internal view returns (uint256) {
        uint256 count = spoke.getReserveCount();
        for (uint256 i; i < count; ++i) {
            if (spoke.getReserve(i).underlying == token) return i;
        }
        revert("reserve not listed on dev");
    }

    /// @dev Live prod values per reserve (prod reserve order); see @dev above for provenance
    function _prodParams() internal pure returns (ProdReserveParams[19] memory) {
        return [
            // USDC
            ProdReserveParams(0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85, 9500, 10_100, 1000, true, 500, 9200, 0, 400, 1000, 10_000_000, 7_000_000),
            // WETH
            ProdReserveParams(0x4200000000000000000000000000000000000006, 7500, 10_350, 1000, true, 700, 9200, 0, 235, 1400, 1000, 100),
            // USDT
            ProdReserveParams(0x94b008aA00579c1307B0EF2c499aD98a8ce58e58, 9500, 10_100, 1000, false, 0, 9900, 0, 0, 0, 10_000_000, 0),
            // EURC
            ProdReserveParams(0xDCB612005417Dc906fF72c87DF732e5a90D49e11, 9500, 10_100, 1000, false, 0, 9900, 0, 0, 0, 5_000_000, 0),
            // frxUSD
            ProdReserveParams(0x80Eede496655FB9047dd39d9f418d5483ED600df, 9500, 10_100, 1000, false, 0, 9900, 0, 0, 0, 5_000_000, 0),
            // weETH
            ProdReserveParams(0x5A7fACB970D094B6C7FF1df0eA68D99E6e73CBFF, 7500, 10_350, 1000, false, 0, 9900, 0, 0, 0, 1000, 0),
            // eBTC
            ProdReserveParams(0x657e8C867D8B37dCC18fA4Caead9C45EB088C642, 7200, 10_500, 1000, false, 0, 9900, 0, 0, 0, 200, 0),
            // eUSD
            ProdReserveParams(0x939778D83b46B456224A33Fb59630B11DEC56663, 9000, 10_200, 1000, false, 0, 9900, 0, 0, 0, 1_000_000, 0),
            // ETHFI
            ProdReserveParams(0xe0080d2F853ecDdbd81A643dC10DA075Df26fD3f, 3000, 10_500, 1000, false, 0, 9900, 0, 0, 0, 2_000_000, 0),
            // sETHFI
            ProdReserveParams(0x86B5780b606940Eb59A062aA85a07959518c0161, 3000, 10_500, 1000, false, 0, 9900, 0, 0, 0, 2_000_000, 0),
            // OP
            ProdReserveParams(0x4200000000000000000000000000000000000042, 3000, 10_500, 1000, false, 0, 9900, 0, 0, 0, 1_000_000, 0),
            // WHYPE
            ProdReserveParams(0xd83E3d560bA6F05094d9D8B3EB8aaEA571D1864E, 6500, 10_400, 1000, false, 0, 9900, 0, 0, 0, 100_000, 0),
            // beHYPE
            ProdReserveParams(0xA519AfBc91986c0e7501d7e34968FEE51CD901aC, 6000, 10_500, 1000, false, 0, 9900, 0, 0, 0, 100_000, 0),
            // liquidETH
            ProdReserveParams(0xf0bb20865277aBd641a307eCe5Ee04E79073416C, 7000, 10_500, 1000, false, 0, 9900, 0, 0, 0, 1000, 0),
            // liquidBTC
            ProdReserveParams(0x5f46d540b6eD704C3c8789105F30E075AA900726, 7000, 10_500, 1000, false, 0, 9900, 0, 0, 0, 100, 0),
            // liquidUSD
            ProdReserveParams(0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C, 8000, 10_200, 1000, false, 0, 9900, 0, 0, 0, 5_000_000, 0),
            // liquidRESERVE (Midas)
            ProdReserveParams(0xca5921DF65E2e1b0B98Ae91c0187BA80D4124898, 8000, 10_200, 1000, false, 0, 9900, 0, 0, 0, 1_000_000, 0),
            // weEUR
            ProdReserveParams(0xcC476B1a49bcDf5192561e87b6Fb8ea78aa28C13, 8000, 10_200, 1000, false, 0, 9900, 0, 0, 0, 1_000_000, 0),
            // liquidRWA
            ProdReserveParams(0x17bC8Ffd82b8a36e737Ca1141C025089589B915e, 8000, 10_200, 1000, false, 0, 9900, 0, 0, 0, 1_000_000, 0)
        ];
    }
}
