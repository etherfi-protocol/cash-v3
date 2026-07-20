// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Test } from "forge-std/Test.sol";

import { AccessManagerEnumerable } from "aave-v4/access/AccessManagerEnumerable.sol";
import { IAccessManager } from "aave-v4/dependencies/openzeppelin/IAccessManager.sol";
import { TransparentUpgradeableProxy } from "aave-v4/dependencies/openzeppelin/TransparentUpgradeableProxy.sol";
import { AssetInterestRateStrategy } from "aave-v4/hub/AssetInterestRateStrategy.sol";
import { HubInstance } from "aave-v4/hub/instances/HubInstance.sol";
import { IAssetInterestRateStrategy } from "aave-v4/hub/interfaces/IAssetInterestRateStrategy.sol";
import { IHub } from "aave-v4/hub/interfaces/IHub.sol";
import { Roles } from "aave-v4/libraries/types/Roles.sol";
import { AaveOracle } from "aave-v4/spoke/AaveOracle.sol";
import { TreasurySpokeInstance } from "aave-v4/spoke/instances/TreasurySpokeInstance.sol";
import { IAaveOracle } from "aave-v4/spoke/interfaces/IAaveOracle.sol";
import { ISpoke } from "aave-v4/spoke/interfaces/ISpoke.sol";
import { ITreasurySpoke } from "aave-v4/spoke/interfaces/ITreasurySpoke.sol";

import { EtherFiSpokeInstance } from "../../../../../../src/aave-v4/EtherFiSpokeInstance.sol";

/// @dev Minimal init interface shared by the hub/spoke/treasury proxy implementations
interface IProxyInit {
    function initialize(address authorityOrOwner) external;
}

/**
 * @title AaveV4Fixture
 * @notice Deploys a real, self-owned Aave v4 instance inside a Foundry test (works on any fork), so the
 *         LendGateway can be exercised against genuine Aave v4 code rather than a mock. The spoke is the
 *         gated EtherFiSpokeInstance (borrow restricted to ether.fi safes), matching the planned whitelabel
 *         instance. This test contract holds every admin role, so it can list reserves, set collateral
 *         factors, and activate position managers freely. Mirrors aave-v4 v0.5.11 `tests/Base.t.sol`
 *         deployFixtures/setUpRoles.
 * @dev SpokeInstance links the external LiquidationLogic library. forge can't resolve that aave-rooted
 *      `src/` import to an artifact, so foundry.toml `[profile.lend]` libraries pins it to a fixed address and
 *      `_deployAaveV4` etches the library code there before deploying the spoke.
 */
abstract contract AaveV4Fixture is Test {
    /// @notice Admin of the Aave instance (holds AccessManager ADMIN + all granted roles)
    address internal aaveAdmin = makeAddr("aaveAdmin");

    IAccessManager internal accessManager;
    IHub internal hub;
    ISpoke internal spoke;
    IAaveOracle internal oracle;
    AssetInterestRateStrategy internal irStrategy;
    ITreasurySpoke internal treasurySpoke;

    /// @notice Fixed link address for LiquidationLogic (see foundry.toml `[profile.lend]` libraries)
    address internal constant LIQUIDATION_LOGIC = 0x0000000000000000000000000000000000000a01;

    /// @notice Deploys and wires a full Aave v4 instance (access manager, hub, spoke, oracle, treasury).
    ///         `etherFiDataProvider` feeds the gated spoke's isEtherFiSafe borrow check.
    function _deployAaveV4(address etherFiDataProvider) internal {
        // Put LiquidationLogic's runtime code at the address SpokeInstance was linked against. Read it
        // straight from the compiled artifact (the library has no link deps), avoiding a getDeployedCode
        // re-resolution pass that noisily mis-resolves aave-v4's `src/`-rooted imports.
        bytes memory liquidationLogicCode = vm.parseJsonBytes(vm.readFile("out/LiquidationLogic.sol/LiquidationLogic.json"), ".deployedBytecode.object");
        vm.etch(LIQUIDATION_LOGIC, liquidationLogicCode);

        vm.startPrank(aaveAdmin);

        accessManager = IAccessManager(address(new AccessManagerEnumerable(aaveAdmin)));

        // Hub (proxy over HubInstance), then its interest-rate strategy
        address hubImpl = address(new HubInstance());
        hub = IHub(_proxify(hubImpl, abi.encodeCall(IProxyInit.initialize, (address(accessManager)))));
        irStrategy = new AssetInterestRateStrategy(address(hub));

        // Oracle (8-decimal USD) + Spoke (proxy over SpokeInstance); the oracle deployer wires the spoke
        oracle = IAaveOracle(address(new AaveOracle(8)));
        address spokeImpl = address(new EtherFiSpokeInstance(address(oracle), type(uint16).max, etherFiDataProvider));
        spoke = ISpoke(_proxify(spokeImpl, abi.encodeCall(IProxyInit.initialize, (address(accessManager)))));
        oracle.setSpoke(address(spoke));

        // Treasury spoke (fee receiver for hub assets)
        address treasuryImpl = address(new TreasurySpokeInstance());
        treasurySpoke = ITreasurySpoke(_proxify(treasuryImpl, abi.encodeCall(IProxyInit.initialize, (aaveAdmin))));

        vm.stopPrank();

        _grantAaveRoles();
    }

    /// @dev Grants this admin the hub/spoke roles and maps the functions we call to those roles
    function _grantAaveRoles() private {
        vm.startPrank(aaveAdmin);

        accessManager.grantRole(Roles.HUB_ADMIN_ROLE, aaveAdmin, 0);
        accessManager.grantRole(Roles.SPOKE_ADMIN_ROLE, aaveAdmin, 0);

        bytes4[] memory spokeSelectors = new bytes4[](5);
        spokeSelectors[0] = ISpoke.addReserve.selector;
        spokeSelectors[1] = ISpoke.updatePositionManager.selector;
        spokeSelectors[2] = ISpoke.updateLiquidationConfig.selector;
        spokeSelectors[3] = ISpoke.updateDynamicReserveConfig.selector;
        spokeSelectors[4] = ISpoke.updateReserveConfig.selector;
        accessManager.setTargetFunctionRole(address(spoke), spokeSelectors, Roles.SPOKE_ADMIN_ROLE);

        bytes4[] memory hubSelectors = new bytes4[](4);
        hubSelectors[0] = IHub.addAsset.selector;
        hubSelectors[1] = IHub.updateAssetConfig.selector;
        hubSelectors[2] = IHub.addSpoke.selector;
        hubSelectors[3] = IHub.updateSpokeConfig.selector;
        accessManager.setTargetFunctionRole(address(hub), hubSelectors, Roles.HUB_ADMIN_ROLE);

        // A permissive liquidation config, so borrows/withdrawals are governed by collateral factors alone
        spoke.updateLiquidationConfig(ISpoke.LiquidationConfig({ targetHealthFactor: 1.05e18, healthFactorForMaxBonus: 0.7e18, liquidationBonusFactor: 2000 }));

        vm.stopPrank();
    }

    /**
     * @notice Lists `token` as an Aave reserve with the given LTV and price source, returning its reserveId
     * @param token The underlying asset
     * @param priceSource An IPriceFeed price source for the reserve (8-decimal USD)
     * @param collateralFactorBps The reserve's LTV in BPS (e.g. 80_00 == 80%)
     * @param borrowable Whether the reserve can be borrowed
     */
    function _addAaveReserve(address token, address priceSource, uint16 collateralFactorBps, bool borrowable) internal returns (uint256 reserveId) {
        vm.startPrank(aaveAdmin);

        bytes memory irData = abi.encode(IAssetInterestRateStrategy.InterestRateData({ optimalUsageRatio: 9000, baseDrawnRate: 500, rateGrowthBeforeOptimal: 500, rateGrowthAfterOptimal: 500 }));

        uint256 assetId = hub.addAsset(token, IERC20Metadata(token).decimals(), address(treasurySpoke), address(irStrategy), irData);
        hub.updateAssetConfig(assetId, IHub.AssetConfig({ feeReceiver: address(treasurySpoke), liquidityFee: 1000, irStrategy: address(irStrategy), reinvestmentController: address(0) }), new bytes(0));

        reserveId = spoke.addReserve(address(hub), assetId, priceSource, ISpoke.ReserveConfig({ paused: false, frozen: false, borrowable: borrowable, receiveSharesEnabled: true, collateralRisk: 0 }), ISpoke.DynamicReserveConfig({ collateralFactor: collateralFactorBps, maxLiquidationBonus: 10_500, liquidationFee: 1000 }));

        hub.addSpoke(assetId, address(spoke), IHub.SpokeConfig({ addCap: type(uint40).max, drawCap: type(uint40).max, riskPremiumThreshold: 100_000, active: true, halted: false }));

        vm.stopPrank();
    }

    /// @notice Seeds the reserve with borrowable liquidity from an independent supplier
    function _seedAaveLiquidity(uint256 reserveId, address token, uint256 amount) internal {
        address lp = makeAddr("aaveLiquidityProvider");
        deal(token, lp, amount);
        vm.startPrank(lp);
        IERC20(token).approve(address(spoke), amount);
        spoke.supply(reserveId, amount, lp);
        vm.stopPrank();
    }

    /// @notice Activates `positionManager` globally on the spoke (governance action)
    function _activateAavePositionManager(address positionManager) internal {
        vm.prank(aaveAdmin);
        spoke.updatePositionManager(positionManager, true);
    }

    /// @notice Flips a listed reserve's borrowable flag, preserving its other config (models a governance
    ///         change or freeze that blocks new borrows without clearing existing debt)
    function _setAaveReserveBorrowable(uint256 reserveId, bool borrowable) internal {
        ISpoke.ReserveConfig memory cfg = spoke.getReserveConfig(reserveId);
        cfg.borrowable = borrowable;
        vm.prank(aaveAdmin);
        spoke.updateReserveConfig(reserveId, cfg);
    }

    /// @notice Flips a listed reserve's frozen flag, preserving its other config (Aave blocks new supply and
    ///         borrows on a frozen reserve while leaving existing positions withdrawable/repayable)
    function _setAaveReserveFrozen(uint256 reserveId, bool frozen) internal {
        ISpoke.ReserveConfig memory cfg = spoke.getReserveConfig(reserveId);
        cfg.frozen = frozen;
        vm.prank(aaveAdmin);
        spoke.updateReserveConfig(reserveId, cfg);
    }

    /// @notice Flips a listed reserve's paused flag, preserving its other config (Aave blocks every op on a
    ///         paused reserve)
    function _setAaveReservePaused(uint256 reserveId, bool paused) internal {
        ISpoke.ReserveConfig memory cfg = spoke.getReserveConfig(reserveId);
        cfg.paused = paused;
        vm.prank(aaveAdmin);
        spoke.updateReserveConfig(reserveId, cfg);
    }

    /// @notice Sets a listed reserve's per-spoke supply/borrow caps, in whole tokens (type(uint40).max is the
    ///         uncapped sentinel), preserving the spoke's other config (active, halted, riskPremiumThreshold)
    function _setAaveSpokeCaps(uint256 reserveId, uint40 addCap, uint40 drawCap) internal {
        uint256 assetId = spoke.getReserve(reserveId).assetId;
        IHub.SpokeConfig memory cfg = hub.getSpokeConfig(assetId, address(spoke));
        cfg.addCap = addCap;
        cfg.drawCap = drawCap;
        vm.prank(aaveAdmin);
        hub.updateSpokeConfig(assetId, address(spoke), cfg);
    }

    /// @notice Halts (or resumes) a listed reserve's spoke on the Hub, preserving its other config. A halted
    ///         spoke rejects new supplies and borrows.
    function _setAaveSpokeHalted(uint256 reserveId, bool halted) internal {
        uint256 assetId = spoke.getReserve(reserveId).assetId;
        IHub.SpokeConfig memory cfg = hub.getSpokeConfig(assetId, address(spoke));
        cfg.halted = halted;
        vm.prank(aaveAdmin);
        hub.updateSpokeConfig(assetId, address(spoke), cfg);
    }

    /// @notice Updates a listed reserve's collateral factor (BPS), preserving its other dynamic config
    function _setAaveReserveCollateralFactor(uint256 reserveId, uint16 collateralFactorBps) internal {
        uint32 key = spoke.getReserve(reserveId).dynamicConfigKey;
        ISpoke.DynamicReserveConfig memory cfg = spoke.getDynamicReserveConfig(reserveId, key);
        cfg.collateralFactor = collateralFactorBps;
        vm.prank(aaveAdmin);
        spoke.updateDynamicReserveConfig(reserveId, key, cfg);
    }

    function _proxify(address impl, bytes memory initData) private returns (address) {
        return address(new TransparentUpgradeableProxy(impl, aaveAdmin, initData));
    }
}
