// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { AccessManagerEnumerable } from "aave-v4/access/AccessManagerEnumerable.sol";
import { IAccessManager } from "aave-v4/dependencies/openzeppelin/IAccessManager.sol";
import { TransparentUpgradeableProxy } from "aave-v4/dependencies/openzeppelin/TransparentUpgradeableProxy.sol";
import { AssetInterestRateStrategy } from "aave-v4/hub/AssetInterestRateStrategy.sol";
import { HubInstance } from "aave-v4/hub/instances/HubInstance.sol";
import { IAssetInterestRateStrategy } from "aave-v4/hub/interfaces/IAssetInterestRateStrategy.sol";
import { IHub } from "aave-v4/hub/interfaces/IHub.sol";
import { Roles } from "aave-v4/libraries/types/Roles.sol";
import { AaveOracle } from "aave-v4/spoke/AaveOracle.sol";
import { SpokeInstance } from "aave-v4/spoke/instances/SpokeInstance.sol";
import { TreasurySpokeInstance } from "aave-v4/spoke/instances/TreasurySpokeInstance.sol";
import { IAaveOracle } from "aave-v4/spoke/interfaces/IAaveOracle.sol";
import { ISpoke } from "aave-v4/spoke/interfaces/ISpoke.sol";
import { ITreasurySpoke } from "aave-v4/spoke/interfaces/ITreasurySpoke.sol";

import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { ChainlinkPriceFeed } from "../../src/oracle/ChainlinkPriceFeed.sol";
import { ChainConfig, Utils } from "../utils/Utils.sol";

/// @dev Minimal init interface shared by the hub/spoke/treasury proxy implementations
interface IProxyInit {
    function initialize(address authorityOrOwner) external;
}

/**
 * @title DeployAaveV4TestInstance
 * @notice Deploys a self-owned Aave v4 TEST instance (access manager, hub, spoke, oracle, treasury spoke)
 *         on Optimism, lists weETH (collateral-only) and USDC (borrowable) reserves priced by the live
 *         Chainlink feeds, and records the addresses under deployments/<env>/10/aave-v4-test.json.
 *         The broadcast wallet becomes the instance admin (holds AccessManager ADMIN + hub/spoke roles).
 *
 *         This is the on-chain counterpart of test/safe/modules/cash/lend/helpers/AaveV4Fixture.sol
 *         (which mirrors aave-v4 v0.5.11 tests/Base.t.sol) — a dev/test deployment to integrate against
 *         until the official Aave-operated OP instance is live. NOT for production use (BUSL: test use only).
 *
 * @dev SpokeInstance links the external LiquidationLogic library via an aave-rooted `src/` import that
 *      forge can't resolve to an artifact, so auto-linking is unavailable (and the lend test profile's
 *      0x...0A01 pin only works under vm.etch). The `aave-deploy` profile therefore pins the library to
 *      its deterministic CREATE2 address (Nick's factory + fixed salt + current aave-v4 bytecode), and
 *      this script deploys the library there (idempotent) before the spoke. If the aave-v4 bytecode or
 *      compiler settings change, the recomputed address won't match the pin and the script reverts —
 *      recompute the address and update foundry.toml. The script refuses to run under any other profile.
 *
 * Usage (simulate by dropping --broadcast):
 *   source .env && ENV=dev FOUNDRY_PROFILE=aave-deploy forge script \
 *     scripts/aave-v4/DeployAaveV4TestInstance.s.sol:DeployAaveV4TestInstance \
 *     --rpc-url $OPTIMISM_RPC --broadcast -vvvv
 *
 * Optional env:
 *   POSITION_MANAGER  address to activate as a global position manager on the spoke (e.g. a LendGateway)
 *   SEED_USDC         USDC amount (6 decimals) to supply from the deployer as initial borrowable liquidity
 */
contract DeployAaveV4TestInstance is Utils {
    // --- LiquidationLogic deterministic deployment (see @dev above) ---
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant LIQUIDATION_LOGIC_SALT = keccak256("ether.fi/aave-v4-test/LiquidationLogic");
    /// @dev Must match the pin in foundry.toml [profile.aave-deploy] libraries
    address constant LIQUIDATION_LOGIC = 0x49dEE75906621Ea28D7332bb26E0da6f2d15E838;

    // --- reserve policy (mirrors the lend test fixture) ---
    uint16 constant WEETH_COLLATERAL_FACTOR_BPS = 55_00; // 55% LTV
    uint16 constant USDC_COLLATERAL_FACTOR_BPS = 90_00; // 90% LTV

    // Chainlink staleness bounds for the composite weETH/USD feed: the weETH/WETH exchange-rate feed
    // has a 24h heartbeat, ETH/USD updates far more often; 2 days keeps a quiet dev instance usable.
    uint256 constant RATE_FEED_MAX_STALENESS = 1 days;

    IAccessManager accessManager;
    IHub hub;
    ISpoke spoke;
    IAaveOracle oracle;
    AssetInterestRateStrategy irStrategy;
    ITreasurySpoke treasurySpoke;
    ChainlinkPriceFeed weethUsdFeed;

    uint256 weethReserveId;
    uint256 usdcReserveId;

    address admin;

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (10)");
        require(isEqualString(vm.envOr("FOUNDRY_PROFILE", string("default")), "aave-deploy"), "Run with FOUNDRY_PROFILE=aave-deploy (library linking)");

        ChainConfig memory cfg = getChainConfig(vm.toString(block.chainid));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        admin = vm.addr(deployerPrivateKey);
        console.log("Deployer / Aave admin:", admin);

        vm.startBroadcast(deployerPrivateKey);

        _ensureLiquidationLogic();
        _deployCore();
        _grantRoles();

        // A permissive liquidation config, so borrows/withdrawals are governed by collateral factors alone
        spoke.updateLiquidationConfig(ISpoke.LiquidationConfig({ targetHealthFactor: 1.05e18, healthFactorForMaxBonus: 0.7e18, liquidationBonusFactor: 2000 }));

        // weETH priced via weETH/WETH exchange rate x ETH/USD (8-decimal USD), USDC via its direct feed
        weethUsdFeed = new ChainlinkPriceFeed(IAggregatorV3(cfg.weEthWethOracle), IAaveV4PriceFeed(cfg.ethUsdcOracle), 8, RATE_FEED_MAX_STALENESS, false, "weETH / USD");
        weethReserveId = _addReserve(cfg.weETH, address(weethUsdFeed), WEETH_COLLATERAL_FACTOR_BPS, false);
        usdcReserveId = _addReserve(cfg.usdc, cfg.usdcUsdOracle, USDC_COLLATERAL_FACTOR_BPS, true);

        address positionManager = vm.envOr("POSITION_MANAGER", address(0));
        if (positionManager != address(0)) {
            spoke.updatePositionManager(positionManager, true);
            console.log("Activated position manager:", positionManager);
        }

        uint256 seedUsdc = vm.envOr("SEED_USDC", uint256(0));
        if (seedUsdc > 0) {
            IERC20(cfg.usdc).approve(address(spoke), seedUsdc);
            spoke.supply(usdcReserveId, seedUsdc, admin);
            console.log("Seeded USDC liquidity:", seedUsdc);
        }

        vm.stopBroadcast();

        _logAndRecord();
    }

    /// @dev Deploys LiquidationLogic to its pinned CREATE2 address (no-op if already there). Reads the
    ///      creation bytecode straight from the compiled artifact — the same direct-read workaround the
    ///      lend fixture uses, since forge can't resolve the aave-rooted import — and reverts loudly if
    ///      the recomputed CREATE2 address no longer matches the foundry.toml pin the spoke was linked to.
    function _ensureLiquidationLogic() internal {
        bytes memory initCode = vm.parseJsonBytes(vm.readFile("out/LiquidationLogic.sol/LiquidationLogic.json"), ".bytecode.object");
        address expected = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), NICKS_FACTORY, LIQUIDATION_LOGIC_SALT, keccak256(initCode))))));
        require(expected == LIQUIDATION_LOGIC, "LiquidationLogic bytecode drifted from the foundry.toml pin; recompute the CREATE2 address and update both");

        if (LIQUIDATION_LOGIC.code.length == 0) {
            (bool success,) = NICKS_FACTORY.call(abi.encodePacked(LIQUIDATION_LOGIC_SALT, initCode));
            require(success && LIQUIDATION_LOGIC.code.length > 0, "LiquidationLogic CREATE2 deployment failed");
            console.log("Deployed LiquidationLogic:", LIQUIDATION_LOGIC);
        } else {
            console.log("LiquidationLogic already deployed:", LIQUIDATION_LOGIC);
        }
    }

    /// @dev Deploys access manager, hub (proxy), IR strategy, oracle, spoke (proxy) and treasury spoke (proxy)
    function _deployCore() internal {
        accessManager = IAccessManager(address(new AccessManagerEnumerable(admin)));

        address hubImpl = address(new HubInstance());
        hub = IHub(_proxify(hubImpl, abi.encodeCall(IProxyInit.initialize, (address(accessManager)))));
        irStrategy = new AssetInterestRateStrategy(address(hub));

        // Oracle (8-decimal USD) + Spoke; the oracle deployer wires the spoke
        oracle = IAaveOracle(address(new AaveOracle(8)));
        address spokeImpl = address(new SpokeInstance(address(oracle), type(uint16).max));
        spoke = ISpoke(_proxify(spokeImpl, abi.encodeCall(IProxyInit.initialize, (address(accessManager)))));
        oracle.setSpoke(address(spoke));

        address treasuryImpl = address(new TreasurySpokeInstance());
        treasurySpoke = ITreasurySpoke(_proxify(treasuryImpl, abi.encodeCall(IProxyInit.initialize, (admin))));
    }

    /// @dev Grants the admin the hub/spoke roles and maps the admin functions we call to those roles
    function _grantRoles() internal {
        accessManager.grantRole(Roles.HUB_ADMIN_ROLE, admin, 0);
        accessManager.grantRole(Roles.SPOKE_ADMIN_ROLE, admin, 0);

        bytes4[] memory spokeSelectors = new bytes4[](4);
        spokeSelectors[0] = ISpoke.addReserve.selector;
        spokeSelectors[1] = ISpoke.updatePositionManager.selector;
        spokeSelectors[2] = ISpoke.updateLiquidationConfig.selector;
        spokeSelectors[3] = ISpoke.updateDynamicReserveConfig.selector;
        accessManager.setTargetFunctionRole(address(spoke), spokeSelectors, Roles.SPOKE_ADMIN_ROLE);

        bytes4[] memory hubSelectors = new bytes4[](3);
        hubSelectors[0] = IHub.addAsset.selector;
        hubSelectors[1] = IHub.updateAssetConfig.selector;
        hubSelectors[2] = IHub.addSpoke.selector;
        accessManager.setTargetFunctionRole(address(hub), hubSelectors, Roles.HUB_ADMIN_ROLE);
    }

    /// @dev Lists `token` on the hub + spoke with the given price source, LTV and borrowability
    function _addReserve(address token, address priceSource, uint16 collateralFactorBps, bool borrowable) internal returns (uint256 reserveId) {
        bytes memory irData = abi.encode(IAssetInterestRateStrategy.InterestRateData({ optimalUsageRatio: 9000, baseDrawnRate: 500, rateGrowthBeforeOptimal: 500, rateGrowthAfterOptimal: 500 }));

        uint256 assetId = hub.addAsset(token, IERC20Metadata(token).decimals(), address(treasurySpoke), address(irStrategy), irData);
        hub.updateAssetConfig(assetId, IHub.AssetConfig({ feeReceiver: address(treasurySpoke), liquidityFee: 1000, irStrategy: address(irStrategy), reinvestmentController: address(0) }), new bytes(0));

        reserveId = spoke.addReserve(address(hub), assetId, priceSource, ISpoke.ReserveConfig({ paused: false, frozen: false, borrowable: borrowable, receiveSharesEnabled: true, collateralRisk: 0 }), ISpoke.DynamicReserveConfig({ collateralFactor: collateralFactorBps, maxLiquidationBonus: 10_500, liquidationFee: 1000 }));

        hub.addSpoke(assetId, address(spoke), IHub.SpokeConfig({ addCap: type(uint40).max, drawCap: type(uint40).max, riskPremiumThreshold: 100_000, active: true, halted: false }));
    }

    function _proxify(address impl, bytes memory initData) internal returns (address) {
        return address(new TransparentUpgradeableProxy(impl, admin, initData));
    }

    function _logAndRecord() internal {
        console.log("AccessManager:  ", address(accessManager));
        console.log("Hub:            ", address(hub));
        console.log("Spoke:          ", address(spoke));
        console.log("AaveOracle:     ", address(oracle));
        console.log("IRStrategy:     ", address(irStrategy));
        console.log("TreasurySpoke:  ", address(treasurySpoke));
        console.log("weETH/USD feed: ", address(weethUsdFeed));
        console.log("weETH reserveId:", weethReserveId);
        console.log("USDC reserveId: ", usdcReserveId);

        string memory obj = "aave-v4-test";
        vm.serializeAddress(obj, "liquidationLogic", LIQUIDATION_LOGIC);
        vm.serializeAddress(obj, "admin", admin);
        vm.serializeAddress(obj, "accessManager", address(accessManager));
        vm.serializeAddress(obj, "hub", address(hub));
        vm.serializeAddress(obj, "spoke", address(spoke));
        vm.serializeAddress(obj, "aaveOracle", address(oracle));
        vm.serializeAddress(obj, "irStrategy", address(irStrategy));
        vm.serializeAddress(obj, "treasurySpoke", address(treasurySpoke));
        vm.serializeAddress(obj, "weethUsdFeed", address(weethUsdFeed));
        vm.serializeUint(obj, "weethReserveId", weethReserveId);
        string memory output = vm.serializeUint(obj, "usdcReserveId", usdcReserveId);

        string memory path = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/aave-v4-test.json");
        vm.writeJson(output, path);
        console.log("Recorded:", path);
    }
}
