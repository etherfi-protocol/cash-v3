// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { stdJson } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { IBackedCCIPBridge } from "../../src/interfaces/IBackedCCIPBridge.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { StockMigrationModule } from "../../src/migration/StockMigrationModule.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { StockWrapModule } from "../../src/modules/stock-wrap/StockWrapModule.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { StockBridgeWithdrawModule } from "../../src/stock-withdraw/StockBridgeWithdrawModule.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { DynamicReserveConfigLike, IAaveOracleLike, IHubConfiguratorLike, IHubLike, ISpokeConfiguratorLike, ISpokeLike, InterestRateDataLike, LendRails, ReserveConfigLike, ReserveLike, SpokeConfigLike } from "../stock-listing/StockLendConfig.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { XStocksOPDeployer } from "./XStocksOPDeployer.sol";
import { XStock, XStocksOPProd as C } from "./XStocksOPProdConfig.sol";

/**
 * @title XStocksOPLaunch3CP
 * @notice Six Safe bundles that put SPYx, QQQx and TBLLx on their native Optimism wrappers. Each timelock is
 *         driven by its own Safe (the Admin Safe schedules and executes on the 8h admin timelock, the Upgrade
 *         Safe on the 2d upgrade timelock); the ADMIN_ROLE setters come straight from the Operating Safe.
 *
 *           Step 1 (session day): schedule three timelock batches.
 *             admin-safe:   admin timelock (8h), modules:  setSwapPairs, setWrapPairs, configureWrappers,
 *                                                          default modules, the bridge module on the
 *                                                          can-request list, the migration module as driver
 *                           admin timelock (8h), top-up:   TopUpDest.setStockWrappers (needs the upgrade first)
 *             upgrade-safe: upgrade timelock (2d):         TopUpDest.upgradeToAndCall to the wrapStock impl
 *           Step 2 (>= 8h after step 1 EXECUTES, and after the Summer Lend listing has executed):
 *             admin-safe:      execute the modules batch
 *             controller-safe: the ADMIN_ROLE config sent directly: PriceProviderV2 entries for the wrappers
 *                              (live vault rate on the raw stock's USD entry), DebtManager collateral copied
 *                              from the stand-ins, LendGateway reserve ids, withdraw assets
 *           Step 3 (>= 2d after step 1 EXECUTES):
 *             upgrade-safe: execute the upgrade
 *             admin-safe:   execute the top-up batch, after the upgrade
 *
 *         An optional seed bundle (Operating Safe direct, same session as step 2 or later) moves wrapper from
 *         the Safe into the migration module and the TopUpDest buffer; amounts come from env and default to none.
 *
 * @dev The Summer Lend listing of the wrappers is the aave-v4 repo's timelock script; when it has not executed
 *      on the fork, the simulation rehearses it by pranking the lend timelock with the stand-in reserves'
 *      parameters, the same way the listing will be built. Salts are specific to this launch so the operation
 *      ids are unique. Every gate is asserted against the live RoleRegistry before anything is written; a gate
 *      that moved since 2026-10-12 fails the precondition instead of producing a wrong bundle.
 *
 * Prerequisites: DeployXStocksOP has run. Before it has, the generator rehearsal-deploys the same initcode at
 * the same CREATE3 addresses on its fork, so the bundles can be authored and simulated ahead of the deploy.
 *
 * Usage (no broadcast; writes ./output/*.json and simulates every step on the fork):
 *   forge script scripts/xstocks-op/XStocksOPLaunch3CP.s.sol --rpc-url $OPTIMISM_RPC --sender 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E --no-isolate -vvv
 *   (--sender: the default script sender cannot `new` on this fork, nothing is sent. --no-isolate: the simulation
 *   pranks the Safe, which has code.)
 */
contract XStocksOPLaunch3CP is XStocksOPDeployer, GnosisHelpers, Test {
    using stdJson for string;

    bytes32 constant TL_PREDECESSOR = bytes32(0);
    bytes32 constant SALT_MODULES = keccak256("XStocksOP.modules");
    bytes32 constant SALT_TOP_UP = keccak256("XStocksOP.topUpDest");
    bytes32 constant SALT_UPGRADE = keccak256("XStocksOP.topUpDestUpgrade");
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// @dev The stand-in prices through a relayed sink that lags the live wrapper rate by up to ~25 bps in market hours
    uint256 constant PRICE_TOLERANCE_BPS = 50;

    RoleRegistry roleRegistry;
    EtherFiDataProvider dataProvider;
    ICashModule cashModule;
    LendGateway gateway;
    IDebtManager debtManager;
    PriceProviderV2 priceProvider;
    TopUpDest topUpDest;
    address topUpDestImpl;
    StockMigrationModule migration;
    StockWrapModule wrap;
    StockBridgeWithdrawModule bridgeWithdraw;
    address[] wrapperFeeds;
    XStock[] stocks;

    address[] modulesTargets;
    bytes[] modulesPayloads;
    address[] topUpTargets;
    bytes[] topUpPayloads;
    address[] upgradeTargets;
    bytes[] upgradePayloads;
    uint256[] reserveIds;
    uint256[] seedAmounts;
    uint256[] bufferAmounts;

    function run() public {
        require(block.chainid == C.OP_CHAIN_ID, "Optimism only");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");
        _load();
        _checkPreconditions();
        _buildBatches();

        string memory step1Admin = _writeBundle("admin-safe-step1-schedule", string.concat(_header(C.ADMIN_SAFE), _scheduleTx(C.ADMIN_TIMELOCK, modulesTargets, modulesPayloads, SALT_MODULES, C.ADMIN_DELAY, false), _scheduleTx(C.ADMIN_TIMELOCK, topUpTargets, topUpPayloads, SALT_TOP_UP, C.ADMIN_DELAY, true)));
        string memory step1Upgrade = _writeBundle("upgrade-safe-step1-schedule", string.concat(_header(C.UPGRADE_SAFE), _scheduleTx(C.UPGRADE_TIMELOCK, upgradeTargets, upgradePayloads, SALT_UPGRADE, C.UPGRADE_DELAY, true)));
        string memory step2Admin = _writeBundle("admin-safe-step2-execute-modules", string.concat(_header(C.ADMIN_SAFE), _executeTx(C.ADMIN_TIMELOCK, modulesTargets, modulesPayloads, SALT_MODULES, true)));
        string memory step3Upgrade = _writeBundle("upgrade-safe-step3-execute-upgrade", string.concat(_header(C.UPGRADE_SAFE), _executeTx(C.UPGRADE_TIMELOCK, upgradeTargets, upgradePayloads, SALT_UPGRADE, true)));
        string memory step3Admin = _writeBundle("admin-safe-step3-execute-wrappers", string.concat(_header(C.ADMIN_SAFE), _executeTx(C.ADMIN_TIMELOCK, topUpTargets, topUpPayloads, SALT_TOP_UP, true)));

        console.log("=== Step 1: schedule the three batches ===");
        executeGnosisTransactionBundle(step1Admin);
        executeGnosisTransactionBundle(step1Upgrade);
        require(_isOperation(C.ADMIN_TIMELOCK, modulesTargets, modulesPayloads, SALT_MODULES), "modules batch not scheduled");
        require(_isOperation(C.ADMIN_TIMELOCK, topUpTargets, topUpPayloads, SALT_TOP_UP), "top-up batch not scheduled");
        require(_isOperation(C.UPGRADE_TIMELOCK, upgradeTargets, upgradePayloads, SALT_UPGRADE), "upgrade batch not scheduled");

        console.log("=== Warp 8h, step 2: modules batch + Operating Safe config ===");
        vm.warp(block.timestamp + C.ADMIN_DELAY + 1);
        _resolveReserveIds();
        string memory step2Config = _writeBundle("controller-safe-step2-config", _step2Txs());
        executeGnosisTransactionBundle(step2Admin);
        executeGnosisTransactionBundle(step2Config);
        _assertStep2();

        console.log("=== Warp 2d, step 3: TopUpDest upgrade, then wrappers ===");
        vm.warp(block.timestamp + C.UPGRADE_DELAY + 1);
        executeGnosisTransactionBundle(step3Upgrade);
        executeGnosisTransactionBundle(step3Admin);
        _assertStep3();

        _seed();
        console.log("Simulation OK");
    }

    function _load() internal {
        string memory d = readDeploymentFile();
        roleRegistry = RoleRegistry(d.readAddress(".addresses.RoleRegistry"));
        dataProvider = EtherFiDataProvider(d.readAddress(".addresses.EtherFiDataProvider"));
        cashModule = ICashModule(d.readAddress(".addresses.CashModule"));
        gateway = LendGateway(d.readAddress(".addresses.LendGateway"));
        debtManager = IDebtManager(d.readAddress(".addresses.DebtManager"));
        priceProvider = PriceProviderV2(d.readAddress(".addresses.PriceProvider"));
        topUpDest = TopUpDest(payable(d.readAddress(".addresses.TopUpDest")));

        // The CREATE3 addresses the deploy script produces; rehearsal-deployed here when not live yet
        string memory feeds = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/summer-lend-feeds.json"));
        OPDeployment memory deployed = _deployOP(true, address(dataProvider), address(roleRegistry), feeds);
        _checkRecorded(d, C.KEY_MIGRATION, deployed.migration);
        _checkRecorded(d, C.KEY_WRAP, deployed.wrap);
        _checkRecorded(d, C.KEY_BRIDGE_WITHDRAW, deployed.bridgeWithdraw);
        _checkRecorded(d, C.KEY_TOP_UP_DEST_IMPL, deployed.topUpDestImpl);
        topUpDestImpl = deployed.topUpDestImpl;
        migration = StockMigrationModule(deployed.migration);
        wrap = StockWrapModule(deployed.wrap);
        bridgeWithdraw = StockBridgeWithdrawModule(deployed.bridgeWithdraw);

        XStock[] memory list = C.stocks();
        for (uint256 i; i < list.length; ++i) {
            stocks.push(list[i]);
            wrapperFeeds.push(deployed.wrapperFeeds[i]);
            seedAmounts.push(vm.envOr(string.concat("XSTOCKS_SEED_", list[i].symbol), uint256(0)));
            bufferAmounts.push(vm.envOr(string.concat("XSTOCKS_BUFFER_", list[i].symbol), uint256(0)));
        }
    }

    function _checkPreconditions() internal {
        // Governance as verified on 2026-10-12: owner paths on the 2d timelock, ADMIN_TIMELOCK_ROLE on the 8h one,
        // ADMIN_ROLE on the Safe, and the legacy per-contract admin roles retired (no holders). A role that moved
        // re-routes a tx, so stop here if one did.
        require(roleRegistry.owner() == C.UPGRADE_TIMELOCK, "RoleRegistry owner is not the upgrade timelock");
        require(roleRegistry.hasRole(keccak256("ADMIN_TIMELOCK_ROLE"), C.ADMIN_TIMELOCK), "admin timelock lacks ADMIN_TIMELOCK_ROLE");
        require(roleRegistry.hasRole(keccak256("ADMIN_ROLE"), C.SAFE), "Safe lacks ADMIN_ROLE");
        _checkTimelock(C.UPGRADE_TIMELOCK, C.UPGRADE_DELAY, C.UPGRADE_SAFE);
        _checkTimelock(C.ADMIN_TIMELOCK, C.ADMIN_DELAY, C.ADMIN_SAFE);
        string[5] memory retiredRoles = ["CASH_MODULE_CONTROLLER_ROLE", "DATA_PROVIDER_ADMIN_ROLE", "LEND_GATEWAY_ADMIN_ROLE", "PRICE_PROVIDER_ADMIN_ROLE", "DEBT_MANAGER_ADMIN_ROLE"];
        for (uint256 i; i < retiredRoles.length; ++i) {
            require(roleRegistry.roleHolders(keccak256(bytes(retiredRoles[i]))).length == 0, string.concat(retiredRoles[i], " still has holders: the gates moved back"));
        }

        // The recorded modules are this repo's source, bound to the prod RoleRegistry and DataProvider
        require(_sameCodeIgnoringSelf(_implOf(address(migration)), address(new StockMigrationModule(address(dataProvider)))), "migration impl != local build");
        require(_sameCodeIgnoringSelf(_implOf(address(wrap)), address(new StockWrapModule(address(dataProvider)))), "wrap impl != local build");
        require(_sameCodeIgnoringSelf(_implOf(address(bridgeWithdraw)), address(new StockBridgeWithdrawModule(address(dataProvider)))), "bridge-withdraw impl != local build");
        require(_sameCodeIgnoringSelf(topUpDestImpl, address(new TopUpDest(address(dataProvider), C.OP_WETH))), "TopUpDest impl != local build");
        require(address(migration.roleRegistry()) == address(roleRegistry) && address(wrap.roleRegistry()) == address(roleRegistry) && address(bridgeWithdraw.roleRegistry()) == address(roleRegistry), "module bound to another RoleRegistry");
        (address bridge, uint64 selector) = bridgeWithdraw.getBridge();
        require(bridge == C.BACKED_BRIDGE && selector == C.ETHEREUM_SELECTOR, "bridge module points elsewhere");
        require(_implOf(address(topUpDest)) != topUpDestImpl, "TopUpDest already upgraded");

        // Nothing configured yet, and the pieces each entry composes on exist
        for (uint256 i; i < stocks.length; ++i) {
            XStock memory s = stocks[i];
            require(IERC4626(s.wrapper).asset() == s.raw, string.concat(s.symbol, ": wrapper asset mismatch"));
            require(IBackedCCIPBridge(C.BACKED_BRIDGE).tokenIds(s.raw) != 0, string.concat(s.symbol, ": raw not on the bridge"));
            require(IAaveV4PriceFeed(wrapperFeeds[i]).latestAnswer() > 0, string.concat(s.symbol, ": wrapper feed does not price"));
            require(priceProvider.tokenConfig(s.raw).oracle != address(0) && priceProvider.tokenConfig(s.raw).baseAsset == address(0), string.concat(s.symbol, ": raw is not a PriceProviderV2 base entry"));
            require(priceProvider.tokenConfig(s.wrapper).oracle == address(0), string.concat(s.symbol, ": wrapper already priced"));
            require(debtManager.isCollateralToken(s.standIn) && !debtManager.isCollateralToken(s.wrapper), string.concat(s.symbol, ": DebtManager collateral state unexpected"));
            require(gateway.isRegistered(s.standIn) && !gateway.isRegistered(s.wrapper), string.concat(s.symbol, ": gateway reserve state unexpected"));
            require(migration.swapPairFor(s.standIn) == address(0) && wrap.wrapPairFor(s.raw) == address(0) && !bridgeWithdraw.isWrapperSupported(s.wrapper), string.concat(s.symbol, ": pair already set"));
        }
        require(!dataProvider.isDefaultModule(address(migration)) && !gateway.isDriver(address(migration)), "migration module already configured");
    }

    function _checkTimelock(address timelock, uint256 delay, address safe) internal view {
        EtherFiTimelock tl = EtherFiTimelock(payable(timelock));
        require(tl.getMinDelay() == delay, "timelock minDelay mismatch");
        require(tl.hasRole(tl.PROPOSER_ROLE(), safe), "Safe is not a proposer");
        require(tl.hasRole(tl.EXECUTOR_ROLE(), safe) || tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "Safe is not an executor");
    }

    function _buildBatches() internal {
        modulesTargets.push(address(migration));
        modulesPayloads.push(abi.encodeCall(StockMigrationModule.setSwapPairs, (C.standIns(), C.wrappers())));
        modulesTargets.push(address(wrap));
        modulesPayloads.push(abi.encodeCall(StockWrapModule.setWrapPairs, (C.raws(), C.wrappers())));
        modulesTargets.push(address(bridgeWithdraw));
        modulesPayloads.push(abi.encodeCall(StockBridgeWithdrawModule.configureWrappers, (C.wrappers(), C.flags(stocks.length, true))));
        // ADMIN_TIMELOCK_ROLE gates since the Sep 2026 re-gate: default modules, the can-request list, the gateway driver
        address[] memory modules = new address[](3);
        modules[0] = address(migration);
        modules[1] = address(wrap);
        modules[2] = address(bridgeWithdraw);
        address[] memory canRequest = new address[](1);
        canRequest[0] = address(bridgeWithdraw);
        modulesTargets.push(address(dataProvider));
        modulesPayloads.push(abi.encodeCall(EtherFiDataProvider.configureDefaultModules, (modules, C.flags(3, true))));
        modulesTargets.push(address(cashModule));
        modulesPayloads.push(abi.encodeCall(ICashModule.configureModulesCanRequestWithdraw, (canRequest, C.flags(1, true))));
        modulesTargets.push(address(gateway));
        modulesPayloads.push(abi.encodeCall(LendGateway.setDriver, (address(migration), true)));

        topUpTargets.push(address(topUpDest));
        topUpPayloads.push(abi.encodeCall(TopUpDest.setStockWrappers, (C.raws(), C.wrappers())));

        upgradeTargets.push(address(topUpDest));
        upgradePayloads.push(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", topUpDestImpl, ""));

        require(!_isOperation(C.ADMIN_TIMELOCK, modulesTargets, modulesPayloads, SALT_MODULES), "modules batch already scheduled");
        require(!_isOperation(C.ADMIN_TIMELOCK, topUpTargets, topUpPayloads, SALT_TOP_UP), "top-up batch already scheduled");
        require(!_isOperation(C.UPGRADE_TIMELOCK, upgradeTargets, upgradePayloads, SALT_UPGRADE), "upgrade batch already scheduled");
    }

    // ── Step 2: the Safe-direct config, after the lend listing ────────────────────

    function _step2Txs() internal view returns (string memory) {
        address[] memory wrappers = C.wrappers();
        PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](stocks.length);
        for (uint256 i; i < stocks.length; ++i) {
            configs[i] = _wrapperPriceConfig(stocks[i]);
        }
        // Only the wrappers are withdrawable: a raw stock rebases, so a fixed-amount request could not settle
        address[] memory withdrawAssets = new address[](stocks.length);
        for (uint256 i; i < stocks.length; ++i) {
            withdrawAssets[i] = stocks[i].wrapper;
        }

        // The ADMIN_ROLE setters the Operating Safe sends directly
        string memory txs = string.concat(_header(C.SAFE), _tx(address(priceProvider), abi.encodeCall(PriceProviderV2.setTokenConfig, (wrappers, configs)), false));
        for (uint256 i; i < stocks.length; ++i) {
            txs = string.concat(txs, _tx(address(debtManager), abi.encodeCall(IDebtManager.supportCollateralToken, (stocks[i].wrapper, debtManager.collateralTokenConfig(stocks[i].standIn))), false));
            txs = string.concat(txs, _tx(address(gateway), abi.encodeCall(LendGateway.setReserveId, (stocks[i].wrapper, reserveIds[i])), false));
        }
        txs = string.concat(txs, _tx(address(cashModule), abi.encodeCall(ICashModule.configureWithdrawAssets, (withdrawAssets, C.flags(withdrawAssets.length, true))), true));
        return txs;
    }

    /// @dev The wrapper is worth its live redemption rate in raw stock, times the raw stock's USD entry
    function _wrapperPriceConfig(XStock memory s) internal pure returns (PriceProviderV2.Config memory) {
        return PriceProviderV2.Config({ oracle: s.wrapper, priceFunctionCalldata: abi.encodeCall(IERC4626.convertToAssets, (1e18)), isChainlinkType: false, oraclePriceDecimals: 18, maxStaleness: 0, dataType: PriceProviderV2.ReturnType.Uint256, isStableToken: false, baseAsset: s.raw });
    }

    /// @dev Summer Lend reserve ids of the wrappers; live once the aave-v4 timelock listing executed, otherwise
    ///      rehearsed on the fork with the stand-in reserves' parameters
    function _resolveReserveIds() internal {
        ISpokeLike spoke = ISpokeLike(LendRails.CASH_SPOKE);
        for (uint256 i; i < stocks.length; ++i) {
            uint256 id = _reserveIdOf(spoke, stocks[i].wrapper);
            if (id == type(uint256).max) {
                _rehearseListing(stocks[i], wrapperFeeds[i]);
                id = _reserveIdOf(spoke, stocks[i].wrapper);
                require(id != type(uint256).max, string.concat(stocks[i].symbol, ": rehearsal did not list the reserve"));
            }
            reserveIds.push(id);
        }
    }

    function _rehearseListing(XStock memory s, address feed) internal {
        ISpokeLike spoke = ISpokeLike(LendRails.CASH_SPOKE);
        IHubLike hub = IHubLike(LendRails.CASH_HUB);
        uint256 standInId = _reserveIdOf(spoke, s.standIn);
        require(standInId != type(uint256).max, string.concat(s.symbol, ": stand-in not listed"));
        ReserveLike memory standIn = spoke.getReserve(standInId);
        DynamicReserveConfigLike memory dynamic = spoke.getDynamicReserveConfig(standInId, standIn.dynamicConfigKey);
        SpokeConfigLike memory spokeConfig = hub.getSpokeConfig(standIn.assetId, LendRails.CASH_SPOKE);
        uint256 assetId = hub.getAssetCount();

        console.log(string.concat("  [REHEARSAL] ", s.symbol, " wrapper listed on Summer Lend with the stand-in's parameters, assetId"), assetId);
        vm.startPrank(C.LEND_TIMELOCK);
        IHubConfiguratorLike(LendRails.HUB_CONFIGURATOR).addAsset(LendRails.CASH_HUB, s.wrapper, LendRails.TREASURY_SPOKE, 0, LendRails.IR_STRATEGY, abi.encode(InterestRateDataLike({ optimalUsageRatio: 9900, baseDrawnRate: 0, rateGrowthBeforeOptimal: 0, rateGrowthAfterOptimal: 0 })));
        IHubConfiguratorLike(LendRails.HUB_CONFIGURATOR).addSpoke(LendRails.CASH_HUB, LendRails.CASH_SPOKE, assetId, SpokeConfigLike({ addCap: spokeConfig.addCap, drawCap: 0, riskPremiumThreshold: 0, active: true, halted: false }));
        ISpokeConfiguratorLike(LendRails.SPOKE_CONFIGURATOR).addReserve(LendRails.CASH_SPOKE, LendRails.CASH_HUB, assetId, feed, ReserveConfigLike({ collateralRisk: 0, paused: false, frozen: false, borrowable: false, receiveSharesEnabled: true }), dynamic);
        vm.stopPrank();
    }

    function _reserveIdOf(ISpokeLike spoke, address token) internal view returns (uint256) {
        uint256 count = spoke.getReserveCount();
        for (uint256 i; i < count; ++i) {
            if (spoke.getReserve(i).underlying == token) return i;
        }
        return type(uint256).max;
    }

    // ── Post-state ─────────────────────────────────────────────────────────────────

    function _assertStep2() internal view {
        for (uint256 i; i < stocks.length; ++i) {
            XStock memory s = stocks[i];
            assertEq(migration.swapPairFor(s.standIn), s.wrapper, string.concat(s.symbol, ": swap pair"));
            assertEq(wrap.wrapPairFor(s.raw), s.wrapper, string.concat(s.symbol, ": wrap pair"));
            assertTrue(bridgeWithdraw.isWrapperSupported(s.wrapper), string.concat(s.symbol, ": bridge wrapper"));

            uint256 wrapperPrice = priceProvider.price(s.wrapper);
            uint256 standInPrice = priceProvider.price(s.standIn);
            assertApproxEqRel(wrapperPrice, standInPrice, PRICE_TOLERANCE_BPS * 1e14, string.concat(s.symbol, ": wrapper price off the stand-in's"));
            uint256 aavePrice = IAaveOracleLike(LendRails.AAVE_ORACLE).getReservePrice(reserveIds[i]);
            assertApproxEqRel(aavePrice * 1e6 / 1e8, wrapperPrice, PRICE_TOLERANCE_BPS * 1e14, string.concat(s.symbol, ": Aave price off the cash price"));

            IDebtManager.CollateralTokenConfig memory want = debtManager.collateralTokenConfig(s.standIn);
            IDebtManager.CollateralTokenConfig memory got = debtManager.collateralTokenConfig(s.wrapper);
            assertTrue(debtManager.isCollateralToken(s.wrapper), string.concat(s.symbol, ": not DebtManager collateral"));
            assertEq(uint256(got.ltv), uint256(want.ltv), string.concat(s.symbol, ": ltv"));
            assertEq(uint256(got.liquidationThreshold), uint256(want.liquidationThreshold), string.concat(s.symbol, ": liquidation threshold"));
            assertEq(uint256(got.liquidationBonus), uint256(want.liquidationBonus), string.concat(s.symbol, ": liquidation bonus"));
            assertEq(gateway.reserveIdOf(s.wrapper), reserveIds[i], string.concat(s.symbol, ": gateway reserve id"));
            assertTrue(_contains(cashModule.getWhitelistedWithdrawAssets(), s.wrapper), string.concat(s.symbol, ": wrapper not a withdraw asset"));
            assertFalse(_contains(cashModule.getWhitelistedWithdrawAssets(), s.raw), string.concat(s.symbol, ": raw must not be a withdraw asset"));
            console.log(string.concat("  ", s.symbol, " wrapper price (6 dec):"), wrapperPrice, "stand-in:", standInPrice);
        }
        assertTrue(dataProvider.isDefaultModule(address(migration)) && dataProvider.isDefaultModule(address(wrap)) && dataProvider.isDefaultModule(address(bridgeWithdraw)), "default modules");
        assertTrue(_contains(cashModule.getWhitelistedModulesCanRequestWithdraw(), address(bridgeWithdraw)), "bridge module cannot request withdrawals");
        assertTrue(gateway.isDriver(address(migration)), "migration not a driver");
        assertTrue(_implOf(address(topUpDest)) != topUpDestImpl, "TopUpDest must not be upgraded before step 3");
    }

    function _assertStep3() internal view {
        assertEq(_implOf(address(topUpDest)), topUpDestImpl, "TopUpDest impl slot != new impl");
        for (uint256 i; i < stocks.length; ++i) {
            assertEq(topUpDest.stockWrapperFor(stocks[i].raw), stocks[i].wrapper, string.concat(stocks[i].symbol, ": TopUpDest wrapper"));
        }
    }

    // ── Optional seed bundle ───────────────────────────────────────────────────────

    /// @dev Safe-direct: wrapper from the Safe into the migration module (swap seed) and the TopUpDest buffer.
    ///      Skipped when every amount is zero. The fork deals the Safe the wrapper it needs.
    function _seed() internal {
        bool any;
        for (uint256 i; i < stocks.length; ++i) {
            any = any || seedAmounts[i] != 0 || bufferAmounts[i] != 0;
        }
        if (!any) {
            console.log("No XSTOCKS_SEED_* / XSTOCKS_BUFFER_* amounts set; seed bundle not written");
            return;
        }
        require(roleRegistry.hasRole(keccak256("DEPOSITOR_ROLE"), C.SAFE), "Safe lacks DEPOSITOR_ROLE");
        string memory txs = _header(C.SAFE);
        for (uint256 i; i < stocks.length; ++i) {
            XStock memory s = stocks[i];
            deal(s.wrapper, C.SAFE, IERC20(s.wrapper).balanceOf(C.SAFE) + seedAmounts[i] + bufferAmounts[i]);
            if (seedAmounts[i] != 0) txs = string.concat(txs, _tx(s.wrapper, abi.encodeCall(IERC20.transfer, (address(migration), seedAmounts[i])), false));
            if (bufferAmounts[i] != 0) {
                txs = string.concat(txs, _tx(s.wrapper, abi.encodeCall(IERC20.approve, (address(topUpDest), bufferAmounts[i])), false));
                txs = string.concat(txs, _tx(address(topUpDest), abi.encodeCall(TopUpDest.deposit, (s.wrapper, bufferAmounts[i])), false));
            }
        }
        txs = string.concat(txs, _tx(address(topUpDest), abi.encodeCall(TopUpDest.getDeposit, (stocks[0].wrapper)), true));
        string memory path = _writeBundle("seed", txs);
        executeGnosisTransactionBundle(path);
        for (uint256 i; i < stocks.length; ++i) {
            assertEq(IERC20(stocks[i].wrapper).balanceOf(address(migration)), seedAmounts[i], string.concat(stocks[i].symbol, ": seed"));
            assertEq(topUpDest.getDeposit(stocks[i].wrapper), bufferAmounts[i], string.concat(stocks[i].symbol, ": buffer"));
        }
    }

    // ── Bundle encoding ────────────────────────────────────────────────────────────

    function _header(address safe) internal pure returns (string memory) {
        return _getGnosisHeader("10", addressToHex(safe));
    }

    function _scheduleTx(address timelock, address[] memory targets, bytes[] memory payloads, bytes32 salt, uint256 delay, bool isLast) internal pure returns (string memory) {
        return _tx(timelock, abi.encodeWithSignature("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)", targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, salt, delay), isLast);
    }

    function _executeTx(address timelock, address[] memory targets, bytes[] memory payloads, bytes32 salt, bool isLast) internal pure returns (string memory) {
        return _tx(timelock, abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, salt), isLast);
    }

    function _tx(address to, bytes memory data, bool isLast) internal pure returns (string memory) {
        return _getGnosisTransaction(addressToHex(to), iToHex(data), "0", isLast);
    }

    function _writeBundle(string memory step, string memory txs) internal returns (string memory) {
        vm.createDir("./output", true);
        string memory path = string.concat("./output/XStocksOPLaunch3CP-10-", step, ".json");
        vm.writeFile(path, txs);
        console.log("Wrote", path);
        return path;
    }

    function _isOperation(address timelock, address[] memory targets, bytes[] memory payloads, bytes32 salt) internal view returns (bool) {
        EtherFiTimelock tl = EtherFiTimelock(payable(timelock));
        return tl.isOperation(tl.hashOperationBatch(targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, salt));
    }

    /// @dev UUPSUpgradeable bakes `address(this)` into an implementation, so a local build never hash-matches a
    ///      deployed one; blank each side's own address before comparing
    function _sameCodeIgnoringSelf(address deployed, address local) internal view returns (bool) {
        return keccak256(_blankSelf(deployed.code, deployed)) == keccak256(_blankSelf(local.code, local));
    }

    function _blankSelf(bytes memory code, address self) internal pure returns (bytes memory) {
        bytes20 needle = bytes20(self);
        for (uint256 i = 0; i + 20 <= code.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < 20 && hit; j++) {
                hit = code[i + j] == needle[j];
            }
            if (hit) {
                for (uint256 j = 0; j < 20; j++) {
                    code[i + j] = 0;
                }
                i += 19;
            }
        }
        return code;
    }

    function _implOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    function _contains(address[] memory list, address item) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == item) return true;
        }
        return false;
    }
}
