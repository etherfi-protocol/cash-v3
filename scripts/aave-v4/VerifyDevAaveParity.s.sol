// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IAssetInterestRateStrategy } from "aave-v4/hub/interfaces/IAssetInterestRateStrategy.sol";
import { IHub } from "aave-v4/hub/interfaces/IHub.sol";
import { ISpoke } from "aave-v4/spoke/interfaces/ISpoke.sol";

import { Utils } from "../utils/Utils.sol";
import { EtherFiSpokeInstanceDev } from "./EtherFiSpokeInstanceDev.sol";

/**
 * @title VerifyDevAaveParity
 * @notice Read-only parity check between the dev Aave v4 test instance
 *         (deployments/<env>/10/aave-v4-test.json) and the live prod whitelabel instance on
 *         OP Mainnet. For every prod reserve (matched to dev by underlying) it compares the
 *         dynamic reserve config, borrowable flag, hub liquidity fee, interest rate data, and
 *         spoke caps / risk premium threshold, plus the spoke-level liquidation config and the
 *         borrow gate (dev data provider baked into the dev spoke impl, non-safe borrow reverts).
 *         Dev-only reserves (iwSPYx and the legacy liquidRESERVE OFT) are reported and ignored.
 *         Reverts if any parameter differs, so it doubles as a CI-style gate after config drift.
 *
 * Usage:
 *   source .env && ENV=dev FOUNDRY_PROFILE=aave-deploy forge script \
 *     scripts/aave-v4/VerifyDevAaveParity.s.sol:VerifyDevAaveParity --rpc-url $OPTIMISM_RPC -vvv
 */
contract VerifyDevAaveParity is Utils {
    // Prod whitelabel instance (etherfi-protocol/aave-v4 deployments/optimism/10.json)
    ISpoke constant PROD_SPOKE = ISpoke(0xdffcC3536D932eb51Df51a7F5FA407c4270d5308);
    IHub constant PROD_HUB = IHub(0x66753c4e3fC84f1eD0e3C267C927284E9d90C572);
    IAssetInterestRateStrategy constant PROD_IR = IAssetInterestRateStrategy(0x51d07C362f9c4716F96EbEB63DB985EF9D2aCd7C);
    address constant DEV_ETHERFI_DATA_PROVIDER = 0x4a9c44c97BBf6079db37C4769AebE425bBcDD09a;

    IHub devHub;
    ISpoke devSpoke;
    IAssetInterestRateStrategy devIr;
    uint256 mismatches;

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (10)");

        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/aave-v4-test.json"));
        devHub = IHub(stdJson.readAddress(json, ".hub"));
        devSpoke = ISpoke(stdJson.readAddress(json, ".spoke"));
        devIr = IAssetInterestRateStrategy(stdJson.readAddress(json, ".irStrategy"));

        _checkBorrowGate();
        _checkLiquidationConfig();

        uint256 prodCount = PROD_SPOKE.getReserveCount();
        bool[] memory devMatched = new bool[](devSpoke.getReserveCount());
        for (uint256 i; i < prodCount; ++i) {
            address underlying = PROD_SPOKE.getReserve(i).underlying;
            (bool found, uint256 devId) = _devReserveIdOf(underlying);
            if (!found) {
                _flag(string.concat("missing dev reserve for ", IERC20Metadata(underlying).symbol()));
                continue;
            }
            devMatched[devId] = true;
            _compareReserve(IERC20Metadata(underlying).symbol(), i, devId);
        }

        for (uint256 i; i < devMatched.length; ++i) {
            if (!devMatched[i]) {
                console.log("dev-only reserve (ignored):", IERC20Metadata(devSpoke.getReserve(i).underlying).symbol(), i);
            }
        }

        require(mismatches == 0, "dev/prod parity check failed (see logs)");
        console.log("parity OK: dev matches prod on all shared reserves");
    }

    function _checkBorrowGate() internal {
        require(EtherFiSpokeInstanceDev(address(devSpoke)).ETHERFI_DATA_PROVIDER() == DEV_ETHERFI_DATA_PROVIDER, "dev spoke is not the gated EtherFiSpokeInstanceDev build");
        // This script contract is not a Cash Safe, so the gate must reject it as position owner
        // before any position-manager or health checks run
        try EtherFiSpokeInstanceDev(address(devSpoke)).borrow(0, 1, address(this)) {
            _flag("borrow gate did not revert for a non-safe position owner");
        } catch (bytes memory reason) {
            if (bytes4(reason) != EtherFiSpokeInstanceDev.OnlyEtherFiSafe.selector) _flag("borrow reverted, but not with OnlyEtherFiSafe");
        }
        console.log("borrow gate: active, dev data provider baked in");
    }

    function _checkLiquidationConfig() internal {
        ISpoke.LiquidationConfig memory dev = devSpoke.getLiquidationConfig();
        ISpoke.LiquidationConfig memory prod = PROD_SPOKE.getLiquidationConfig();
        if (dev.targetHealthFactor != prod.targetHealthFactor || dev.healthFactorForMaxBonus != prod.healthFactorForMaxBonus || dev.liquidationBonusFactor != prod.liquidationBonusFactor) {
            _flag("liquidation config differs");
        }
    }

    function _compareReserve(string memory symbol, uint256 prodId, uint256 devId) internal {
        ISpoke.Reserve memory prodReserve = PROD_SPOKE.getReserve(prodId);
        ISpoke.Reserve memory devReserve = devSpoke.getReserve(devId);

        ISpoke.DynamicReserveConfig memory prodDyn = PROD_SPOKE.getDynamicReserveConfig(prodId, prodReserve.dynamicConfigKey);
        ISpoke.DynamicReserveConfig memory devDyn = devSpoke.getDynamicReserveConfig(devId, devReserve.dynamicConfigKey);
        if (devDyn.collateralFactor != prodDyn.collateralFactor) _flag(string.concat(symbol, ": collateralFactor"));
        if (devDyn.maxLiquidationBonus != prodDyn.maxLiquidationBonus) _flag(string.concat(symbol, ": maxLiquidationBonus"));
        if (devDyn.liquidationFee != prodDyn.liquidationFee) _flag(string.concat(symbol, ": liquidationFee"));

        if (devSpoke.getReserveConfig(devId).borrowable != PROD_SPOKE.getReserveConfig(prodId).borrowable) _flag(string.concat(symbol, ": borrowable"));

        if (devHub.getAssetConfig(devReserve.assetId).liquidityFee != PROD_HUB.getAssetConfig(prodReserve.assetId).liquidityFee) _flag(string.concat(symbol, ": liquidityFee"));

        IAssetInterestRateStrategy.InterestRateData memory prodRate = PROD_IR.getInterestRateData(prodReserve.assetId);
        IAssetInterestRateStrategy.InterestRateData memory devRate = devIr.getInterestRateData(devReserve.assetId);
        if (devRate.optimalUsageRatio != prodRate.optimalUsageRatio || devRate.baseDrawnRate != prodRate.baseDrawnRate || devRate.rateGrowthBeforeOptimal != prodRate.rateGrowthBeforeOptimal || devRate.rateGrowthAfterOptimal != prodRate.rateGrowthAfterOptimal) {
            _flag(string.concat(symbol, ": interest rate data"));
        }

        IHub.SpokeConfig memory prodSpokeCfg = PROD_HUB.getSpokeConfig(prodReserve.assetId, address(PROD_SPOKE));
        IHub.SpokeConfig memory devSpokeCfg = devHub.getSpokeConfig(devReserve.assetId, address(devSpoke));
        if (devSpokeCfg.addCap != prodSpokeCfg.addCap) _flag(string.concat(symbol, ": addCap"));
        if (devSpokeCfg.drawCap != prodSpokeCfg.drawCap) _flag(string.concat(symbol, ": drawCap"));
        if (devSpokeCfg.riskPremiumThreshold != prodSpokeCfg.riskPremiumThreshold) _flag(string.concat(symbol, ": riskPremiumThreshold"));
        if (devSpokeCfg.active != prodSpokeCfg.active || devSpokeCfg.halted != prodSpokeCfg.halted) _flag(string.concat(symbol, ": active/halted"));
    }

    function _devReserveIdOf(address token) internal view returns (bool, uint256) {
        uint256 count = devSpoke.getReserveCount();
        for (uint256 i; i < count; ++i) {
            if (devSpoke.getReserve(i).underlying == token) return (true, i);
        }
        return (false, 0);
    }

    function _flag(string memory what) internal {
        ++mismatches;
        console.log("MISMATCH:", what);
    }
}
