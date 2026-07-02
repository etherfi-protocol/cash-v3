// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IAccessManager } from "aave-v4/dependencies/openzeppelin/IAccessManager.sol";
import { TransparentUpgradeableProxy } from "aave-v4/dependencies/openzeppelin/TransparentUpgradeableProxy.sol";
import { AccessManagerEnumerable } from "aave-v4/access/AccessManagerEnumerable.sol";
import { AssetInterestRateStrategy } from "aave-v4/hub/AssetInterestRateStrategy.sol";
import { IAssetInterestRateStrategy } from "aave-v4/hub/interfaces/IAssetInterestRateStrategy.sol";
import { IHub } from "aave-v4/hub/interfaces/IHub.sol";
import { HubInstance } from "aave-v4/hub/instances/HubInstance.sol";
import { AaveOracle } from "aave-v4/spoke/AaveOracle.sol";
import { IAaveOracle } from "aave-v4/spoke/interfaces/IAaveOracle.sol";
import { ISpoke } from "aave-v4/spoke/interfaces/ISpoke.sol";
import { ITreasurySpoke } from "aave-v4/spoke/interfaces/ITreasurySpoke.sol";
import { SpokeInstance } from "aave-v4/spoke/instances/SpokeInstance.sol";
import { TreasurySpokeInstance } from "aave-v4/spoke/instances/TreasurySpokeInstance.sol";
import { Roles } from "aave-v4/libraries/types/Roles.sol";

/// @dev Minimal init interface shared by the hub/spoke/treasury proxy implementations
interface IProxyInit {
    function initialize(address authorityOrOwner) external;
}

/**
 * @title AaveV4Fixture
 * @notice Deploys a real, self-owned Aave v4 instance inside a Foundry test (works on any fork), so the
 *         Gateway can be exercised against genuine Aave v4 code rather than a mock. This test contract
 *         holds every admin role, so it can list reserves, set collateral factors, and activate position
 *         managers freely. Mirrors aave-v4 v0.5.11 `tests/Base.t.sol` deployFixtures/setUpRoles.
 * @dev The Hub/Spoke instances are compiled via_ir (foundry.toml compilation_restrictions) and their
 *      LiquidationLogic library is linked by dynamic_test_linking, so a plain `new` suffices.
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

    /// @notice Fixed link address for LiquidationLogic (see foundry.toml [profile.aave] libraries)
    address internal constant LIQUIDATION_LOGIC = 0x0000000000000000000000000000000000000a01;

    /// @notice Deploys and wires a full Aave v4 instance (access manager, hub, spoke, oracle, treasury)
    function _deployAaveV4() internal {
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
        address spokeImpl = address(new SpokeInstance(address(oracle), type(uint16).max));
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

        bytes4[] memory spokeSelectors = new bytes4[](3);
        spokeSelectors[0] = ISpoke.addReserve.selector;
        spokeSelectors[1] = ISpoke.updatePositionManager.selector;
        spokeSelectors[2] = ISpoke.updateLiquidationConfig.selector;
        accessManager.setTargetFunctionRole(address(spoke), spokeSelectors, Roles.SPOKE_ADMIN_ROLE);

        bytes4[] memory hubSelectors = new bytes4[](3);
        hubSelectors[0] = IHub.addAsset.selector;
        hubSelectors[1] = IHub.updateAssetConfig.selector;
        hubSelectors[2] = IHub.addSpoke.selector;
        accessManager.setTargetFunctionRole(address(hub), hubSelectors, Roles.HUB_ADMIN_ROLE);

        // A permissive liquidation config, so borrows/withdrawals are governed by collateral factors alone
        spoke.updateLiquidationConfig(ISpoke.LiquidationConfig({ targetHealthFactor: 1.05e18, healthFactorForMaxBonus: 0.7e18, liquidationBonusFactor: 20_00 }));

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

        bytes memory irData = abi.encode(IAssetInterestRateStrategy.InterestRateData({ optimalUsageRatio: 90_00, baseDrawnRate: 5_00, rateGrowthBeforeOptimal: 5_00, rateGrowthAfterOptimal: 5_00 }));

        uint256 assetId = hub.addAsset(token, IERC20Metadata(token).decimals(), address(treasurySpoke), address(irStrategy), irData);
        hub.updateAssetConfig(assetId, IHub.AssetConfig({ feeReceiver: address(treasurySpoke), liquidityFee: 10_00, irStrategy: address(irStrategy), reinvestmentController: address(0) }), new bytes(0));

        reserveId = spoke.addReserve(
            address(hub),
            assetId,
            priceSource,
            ISpoke.ReserveConfig({ paused: false, frozen: false, borrowable: borrowable, receiveSharesEnabled: true, collateralRisk: 0 }),
            ISpoke.DynamicReserveConfig({ collateralFactor: collateralFactorBps, maxLiquidationBonus: 105_00, liquidationFee: 10_00 })
        );

        hub.addSpoke(assetId, address(spoke), IHub.SpokeConfig({ addCap: type(uint40).max, drawCap: type(uint40).max, riskPremiumThreshold: 1000_00, active: true, halted: false }));

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

    function _proxify(address impl, bytes memory initData) private returns (address) {
        return address(new TransparentUpgradeableProxy(impl, aaveAdmin, initData));
    }
}
