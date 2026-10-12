// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { CCTPModule } from "../../src/modules/cctp/CCTPModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { TradingLens } from "../../src/trading-safe/TradingLens.sol";
import { EtherFiDeployerHelper } from "../utils/EtherFiDeployerHelper.sol";
import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";

/// @title CCTPRegateProd3CP
/// @notice Generates and fork-simulates the 3CP bundles that roll out cash-v3 #343 on prod. It contains no
///         broadcast call: it only writes Safe Transaction Builder JSONs to ./output and simulates them with prank.
///
///         Optimism (10), signed by the Admin Timelock Safe 0x4799...240B (3/6), a proposer and executor on the
///         8h operating timelock. Every call is gated on ADMIN_TIMELOCK_ROLE, which only that timelock holds:
///           nonce 3  operatingTimelock.scheduleBatch
///           nonce 5  operatingTimelock.executeBatch (not before 8 hours after nonce 3 executes)
///         The batch enables the re-gated CCTPModule next to the live one and copies the live config:
///           a. EtherFiDataProvider.configureDefaultModules([new], [true])  (also whitelists it)
///           b. CashModule.configureModulesCanRequestWithdraw([new], [true])
///           c. new.setAllowedRoutes(USDC, live routes, all true)
///           d. new.setproviderFeeRecipient(live recipient)
///         The old module stays enabled until cash-be prod points at the new one; its retirement and the
///         CCTP_MODULE_ADMIN_ROLE revocation are a later batch.
///
///         Ethereum (1), signed by the governance Safe 0xA6cf...AAC4, a proposer and executor on the 2-day upgrade
///         timelock, which owns the trading RoleRegistry:
///           nonce 70  upgradeTimelock.scheduleBatch
///           nonce 72  upgradeTimelock.executeBatch (not before 2 days after nonce 70 executes)
///         The batch:
///           a. TradingLens.upgradeToAndCall(new impl, "")
///           b. trading RoleRegistry.grantRole(TRADING_LENS_TOKEN_LISTER_ROLE, listing wallet)
///
///         The nonces interleave with 3CP-725 on the same Safes: it takes Admin Timelock Safe nonces 2 and 4 and
///         governance Safe nonces 69 and 71, so both 3CPs wait out their timelock delays at the same time.
///
///         Safe Transaction Builder files carry no nonce; the nonce is in each file name and must be set when the
///         bundle is created in the Safe UI.
///
///         If the contracts are not deployed yet (DeployCCTPRegateProd.s.sol), the simulation deploys them on the
///         fork with the same salts and args; the real deploy is still a precondition for signing. If the Admin
///         Timelock Safe is not yet a proposer on Optimism, the queued governance Safe tx (nonce 136) that grants
///         it is replayed first.
///
///         Bundles queued at other nonces on the same Safes can be replayed with PRIOR_BUNDLES (before this 3CP's
///         schedule) and BETWEEN_BUNDLES (after its schedule and delay, right before its execute). Each is a
///         comma-separated list of Transaction Builder files run in order; the entry WARP moves the fork 2 days
///         ahead, past both timelock delays.
///
/// Usage (no broadcast):
///   ENV=mainnet forge script scripts/cctp-regate/CCTPRegateProd3CP.s.sol --rpc-url $OPTIMISM_RPC
///   ENV=mainnet forge script scripts/cctp-regate/CCTPRegateProd3CP.s.sol --rpc-url $MAINNET_RPC
///   Optional: PRIOR_BUNDLES=<file>,<file>  BETWEEN_BUNDLES=WARP,<file>
contract CCTPRegateProd3CP is EtherFiDeployerHelper, GnosisHelpers, ContractCodeChecker {
    using stdJson for string;

    // ─────────────────────────────── governance ───────────────────────────────

    address internal constant GOVERNANCE_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address internal constant ADMIN_TIMELOCK_SAFE = 0x47992A4E7920EE57eb3dD06131C1a086963b240B;
    address internal constant OPERATING_TIMELOCK = 0x9AEb8eaa982084219d1A938D8F7B5040a1d47849;
    address internal constant UPGRADE_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;
    uint256 internal constant OPERATING_DELAY = 8 hours;
    uint256 internal constant UPGRADE_DELAY = 2 days;

    uint256 internal constant OP_SCHEDULE_NONCE = 3;
    uint256 internal constant OP_EXECUTE_NONCE = 5;
    uint256 internal constant ETH_SCHEDULE_NONCE = 70;
    uint256 internal constant ETH_EXECUTE_NONCE = 72;

    bytes32 internal constant TL_PREDECESSOR = bytes32(0);
    bytes32 internal constant TL_SALT_OP = keccak256("CCTPRegate.OP.EnableCCTPModule.v1");
    bytes32 internal constant TL_SALT_ETH = keccak256("CCTPRegate.ETH.TradingLensLister.v1");

    /// @dev Queued governance Safe tx (OP nonce 136): operatingTimelock.executeBatch granting the Admin Timelock
    ///      Safe PROPOSER, EXECUTOR and CANCELLER on the operating timelock
    bytes32 internal constant HANDOVER_SALT = 0x0efaff3715805c95720e6aa21c58d3fa93f4c6aac2ac56e4c91e3810f4c093b1;

    // ─────────────────────────────── Optimism ───────────────────────────────

    string internal constant MODULE_SALT = "Prod.CCTPRegate.Optimism.CCTPModule";
    address internal constant NEW_MODULE = 0xD3f5c617EF328b73130467b0ec867aD9058a1784;
    address internal constant OLD_MODULE = 0xFEF147ce61614aa787B6E68c24Ff096D13593A9d;
    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address internal constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    uint256 internal constant MAX_FEE_BPS = 200;
    uint256 internal constant PROVIDER_FEE_BPS = 0;
    /// @dev Ops wallet Safe, the live module's provider fee recipient
    address internal constant PROVIDER_FEE_RECIPIENT = 0x86fBaEB3D6b5247F420590D303a6ffC9cd523790;
    /// @dev Highest CCTP domain checked when comparing the live and new route sets
    uint32 internal constant MAX_DOMAIN = 31;

    // ─────────────────────────────── Ethereum ───────────────────────────────

    string internal constant LENS_IMPL_SALT = "Prod.CCTPRegate.Ethereum.TradingLensImpl";
    address internal constant NEW_LENS_IMPL = 0x8E0C445d86c1Bf904e5e460B5c8F725eA34d968c;
    address internal constant OLD_LENS_IMPL = 0x53cD7C85Cc424AB52300B95A79531C9b455585e4;
    address internal constant TRADING_LENS = 0x7135AD135Ec21ec765C1930E93DEB7DA9c27290C;
    address internal constant TRADING_REGISTRY = 0xBdAe3A2EfDFf4f27Dc1D89E0BEdb88F3e9A62Bd0;
    address internal constant TRADING_PRICE_PROVIDER = 0x5e67363807764b90Cb7E86b33F2163224eFCb1A2;
    /// @dev Backend asset-listing wallet (MAINNET_ASSET_LISTING_PVT_KEY)
    address internal constant TOKEN_LISTER = 0x3A38ad2cb838e99Dd557f888d78f4769c64b21d0;

    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address[] internal targets;
    bytes[] internal payloads;

    // Optimism live contracts and the pre-batch counts the end state is checked against
    EtherFiDataProvider internal dataProvider;
    ICashModule internal cashModule;
    RoleRegistry internal cashRegistry;
    uint256 internal whitelistedBefore;
    uint256 internal defaultsBefore;
    uint256 internal requestersBefore;

    // Ethereum state read right before the execute
    address[] internal tokensBefore;
    address[] internal adminsBefore;
    address[] internal atlBefore;

    function run() public {
        require(isEqualString(getEnv(), "mainnet"), "prod only: ENV must be mainnet");
        console.log("Fork block:", block.number);
        _replayBundles("PRIOR_BUNDLES");
        if (block.chainid == 10) _runOptimism();
        else if (block.chainid == 1) _runEthereum();
        else revert("run on Optimism or Ethereum");
    }

    // ═══════════════════════════════ Optimism ═══════════════════════════════

    function _runOptimism() internal {
        string memory dep = readDeploymentFile();
        dataProvider = EtherFiDataProvider(dep.readAddress(".addresses.EtherFiDataProvider"));
        cashModule = ICashModule(dep.readAddress(".addresses.CashModule"));
        cashRegistry = RoleRegistry(dep.readAddress(".addresses.RoleRegistry"));

        _checkTimelock(OPERATING_TIMELOCK, OPERATING_DELAY);
        require(cashRegistry.owner() == UPGRADE_TIMELOCK, "cash RoleRegistry owner is not the upgrade timelock");
        address[] memory atl = cashRegistry.roleHolders(cashRegistry.ADMIN_TIMELOCK_ROLE());
        require(atl.length == 1 && atl[0] == OPERATING_TIMELOCK, "ADMIN_TIMELOCK_ROLE is not held by exactly the operating timelock");
        _ensureAdminTimelockSafeIsProposer();

        uint32[] memory routes = _liveRoutes();
        require(routes.length > 0, "live module has no route");
        require(CCTPModule(OLD_MODULE).getproviderFeeRecipient() == PROVIDER_FEE_RECIPIENT, "live fee recipient changed");
        require(dataProvider.isDefaultModule(OLD_MODULE) && _isRequester(OLD_MODULE), "live module is not enabled");

        _ensureModule();
        require(!dataProvider.isWhitelistedModule(NEW_MODULE), "new module already whitelisted");
        require(!_isRequester(NEW_MODULE), "new module already a withdraw requester");

        _buildOptimismBatch(routes);
        bytes32 id = TimelockController(payable(OPERATING_TIMELOCK)).hashOperationBatch(targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, TL_SALT_OP);
        require(!TimelockController(payable(OPERATING_TIMELOCK)).isOperation(id), "operation already scheduled");

        (string memory schedulePath, string memory executePath) = _writeBundles(ADMIN_TIMELOCK_SAFE, OPERATING_TIMELOCK, OPERATING_DELAY, TL_SALT_OP, OP_SCHEDULE_NONCE, OP_EXECUTE_NONCE, "op");
        _simulateOptimism(id, schedulePath, executePath);
        _assertOptimismEndState();

        console.log("");
        console.log("  [OK] new CCTPModule enabled with the live config:", NEW_MODULE);
        console.log("  routes:", routes.length);
        console.log("8h operation id:");
        console.logBytes32(id);
    }

    function _buildOptimismBatch(uint32[] memory routes) internal {
        address[] memory m = new address[](1);
        m[0] = NEW_MODULE;
        bool[] memory yes = new bool[](1);
        yes[0] = true;
        bool[] memory allowed = new bool[](routes.length);
        for (uint256 i = 0; i < routes.length; ++i) allowed[i] = true;
        targets.push(address(dataProvider));
        payloads.push(abi.encodeCall(EtherFiDataProvider.configureDefaultModules, (m, yes)));
        targets.push(address(cashModule));
        payloads.push(abi.encodeCall(ICashModule.configureModulesCanRequestWithdraw, (m, yes)));
        targets.push(NEW_MODULE);
        payloads.push(abi.encodeCall(CCTPModule.setAllowedRoutes, (USDC, routes, allowed)));
        targets.push(NEW_MODULE);
        payloads.push(abi.encodeCall(CCTPModule.setproviderFeeRecipient, (PROVIDER_FEE_RECIPIENT)));
    }

    function _simulateOptimism(bytes32 id, string memory schedulePath, string memory executePath) internal {
        TimelockController tl = TimelockController(payable(OPERATING_TIMELOCK));

        // Neither Safe can configure the new module directly; the governance Safe still holds the old
        // CCTP_MODULE_ADMIN_ROLE, which the new module no longer accepts
        require(cashRegistry.hasRole(keccak256("CCTP_MODULE_ADMIN_ROLE"), GOVERNANCE_SAFE), "governance Safe no longer holds CCTP_MODULE_ADMIN_ROLE");
        _expectRevert(GOVERNANCE_SAFE, NEW_MODULE, payloads[3], "governance Safe configured the new module directly");
        _expectRevert(ADMIN_TIMELOCK_SAFE, NEW_MODULE, payloads[3], "Admin Timelock Safe configured the new module directly");
        _expectRevert(GOVERNANCE_SAFE, address(dataProvider), payloads[0], "governance Safe enabled the module directly");

        console.log("=== Simulating schedule (Admin Timelock Safe nonce 3) ===");
        executeGnosisTransactionBundle(schedulePath);
        require(tl.isOperationPending(id) && !tl.isOperationReady(id), "operation not pending after schedule");
        _expectRevert(ADMIN_TIMELOCK_SAFE, OPERATING_TIMELOCK, _executeData(TL_SALT_OP), "executeBatch succeeded before the delay");

        vm.warp(block.timestamp + OPERATING_DELAY + 1);
        require(tl.isOperationReady(id), "operation not ready after 8 hours");
        _replayBundles("BETWEEN_BUNDLES");

        // Counted right before the execute, so changes from bundles replayed in between are not attributed to it
        whitelistedBefore = dataProvider.getWhitelistedModules().length;
        defaultsBefore = dataProvider.getDefaultModules().length;
        requestersBefore = cashModule.getWhitelistedModulesCanRequestWithdraw().length;

        console.log("=== Simulating execute (Admin Timelock Safe nonce 5) ===");
        executeGnosisTransactionBundle(executePath);
        require(tl.isOperationDone(id), "operation not done after execute");
    }

    function _assertOptimismEndState() internal view {
        CCTPModule module = CCTPModule(NEW_MODULE);
        CCTPModule old = CCTPModule(OLD_MODULE);
        require(dataProvider.isWhitelistedModule(NEW_MODULE) && dataProvider.isDefaultModule(NEW_MODULE), "new module not whitelisted and default");
        require(_isRequester(NEW_MODULE), "new module cannot request withdrawals");
        require(dataProvider.getWhitelistedModules().length == whitelistedBefore + 1, "whitelist changed by more than the new module");
        require(dataProvider.getDefaultModules().length == defaultsBefore + 1, "default set changed by more than the new module");
        require(cashModule.getWhitelistedModulesCanRequestWithdraw().length == requestersBefore + 1, "requesters changed by more than the new module");
        require(dataProvider.isDefaultModule(OLD_MODULE) && _isRequester(OLD_MODULE), "old module was disabled");
        for (uint32 d = 0; d <= MAX_DOMAIN; ++d) {
            require(module.isRouteAllowed(USDC, d) == old.isRouteAllowed(USDC, d), "route set differs from the live module");
        }
        require(module.getproviderFeeRecipient() == old.getproviderFeeRecipient(), "fee recipient differs from the live module");
        uint32[2] memory modes = [module.FINALITY_CONFIRMED(), module.FINALITY_FINALIZED()];
        for (uint256 i = 0; i < 2; ++i) {
            (address t1, uint256 p1, uint256 c1) = module.getBridgeFee(USDC, 12_345e6, modes[i]);
            (address t0, uint256 p0, uint256 c0) = old.getBridgeFee(USDC, 12_345e6, modes[i]);
            require(t1 == t0 && p1 == p0 && c1 == c0, "bridge fee quote differs from the live module");
        }
        require(cashRegistry.owner() == UPGRADE_TIMELOCK, "RoleRegistry owner changed");
    }

    /// @dev Replays the queued governance Safe tx (OP nonce 136) when the Admin Timelock Safe is not yet a proposer
    function _ensureAdminTimelockSafeIsProposer() internal {
        EtherFiTimelock tl = EtherFiTimelock(payable(OPERATING_TIMELOCK));
        if (!tl.hasRole(tl.PROPOSER_ROLE(), ADMIN_TIMELOCK_SAFE)) {
            address[] memory t = new address[](3);
            bytes[] memory p = new bytes[](3);
            bytes32[3] memory roles = [tl.PROPOSER_ROLE(), tl.EXECUTOR_ROLE(), tl.CANCELLER_ROLE()];
            for (uint256 i = 0; i < 3; ++i) {
                t[i] = OPERATING_TIMELOCK;
                p[i] = abi.encodeWithSignature("grantRole(bytes32,address)", roles[i], ADMIN_TIMELOCK_SAFE);
            }
            bytes32 id = tl.hashOperationBatch(t, new uint256[](3), p, TL_PREDECESSOR, HANDOVER_SALT);
            require(tl.isOperationPending(id), "the timelock grant for the Admin Timelock Safe is not queued");
            console.log("WARNING: Admin Timelock Safe is not a proposer yet; replaying governance Safe nonce 136 on the fork");
            uint256 readyAt = tl.getTimestamp(id);
            if (block.timestamp < readyAt) vm.warp(readyAt);
            vm.prank(GOVERNANCE_SAFE);
            tl.executeBatch(t, new uint256[](3), p, TL_PREDECESSOR, HANDOVER_SALT);
        }
        require(tl.hasRole(tl.PROPOSER_ROLE(), ADMIN_TIMELOCK_SAFE), "Admin Timelock Safe is not a proposer");
        require(tl.hasRole(tl.EXECUTOR_ROLE(), ADMIN_TIMELOCK_SAFE), "Admin Timelock Safe is not an executor");
    }

    /// @dev Deploys the module on the fork when the real deploy has not happened yet, then checks it either way
    function _ensureModule() internal {
        require(_predictAddress(MODULE_SALT) == NEW_MODULE, "module salt does not resolve to the pinned address");
        if (NEW_MODULE.code.length == 0) {
            console.log("WARNING: new CCTPModule not deployed on-chain yet; deploying on the fork only");
            address[] memory assets = new address[](1);
            assets[0] = USDC;
            CCTPModule.AssetConfig[] memory cfgs = new CCTPModule.AssetConfig[](1);
            cfgs[0] = CCTPModule.AssetConfig({ tokenMessenger: TOKEN_MESSENGER, maxFeeBps: MAX_FEE_BPS, providerFeeBps: PROVIDER_FEE_BPS });
            vm.prank(DEPLOYER.getDeployers()[0]);
            DEPLOYER.deploy(getSalt(MODULE_SALT), abi.encodePacked(type(CCTPModule).creationCode, abi.encode(assets, cfgs, address(dataProvider))));
        }
        requireExactCodeMatch("CCTPModule", NEW_MODULE, _localModule());
        CCTPModule.AssetConfig memory cfg = CCTPModule(NEW_MODULE).getAssetConfig(USDC);
        CCTPModule.AssetConfig memory live = CCTPModule(OLD_MODULE).getAssetConfig(USDC);
        require(cfg.tokenMessenger == live.tokenMessenger && cfg.maxFeeBps == live.maxFeeBps && cfg.providerFeeBps == live.providerFeeBps, "new module USDC config differs from the live module");
        require(address(CCTPModule(NEW_MODULE).etherFiDataProvider()) == address(dataProvider), "new module data provider mismatch");
        require(CCTPModule(NEW_MODULE).getproviderFeeRecipient() == address(0), "new module fee recipient already set");
    }

    /// @dev A local build with the same constructor args (immutables included)
    function _localModule() internal returns (address) {
        address[] memory assets = new address[](1);
        assets[0] = USDC;
        CCTPModule.AssetConfig[] memory cfgs = new CCTPModule.AssetConfig[](1);
        cfgs[0] = CCTPModule.AssetConfig({ tokenMessenger: TOKEN_MESSENGER, maxFeeBps: MAX_FEE_BPS, providerFeeBps: PROVIDER_FEE_BPS });
        return address(new CCTPModule(assets, cfgs, address(dataProvider)));
    }

    function _liveRoutes() internal view returns (uint32[] memory routes) {
        uint32[] memory tmp = new uint32[](MAX_DOMAIN + 1);
        uint256 n;
        for (uint32 d = 0; d <= MAX_DOMAIN; ++d) {
            if (CCTPModule(OLD_MODULE).isRouteAllowed(USDC, d)) tmp[n++] = d;
        }
        routes = new uint32[](n);
        for (uint256 i = 0; i < n; ++i) routes[i] = tmp[i];
    }

    function _isRequester(address module) internal view returns (bool) {
        address[] memory list = cashModule.getWhitelistedModulesCanRequestWithdraw();
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == module) return true;
        }
        return false;
    }

    // ═══════════════════════════════ Ethereum ═══════════════════════════════

    function _runEthereum() internal {
        RoleRegistry registry = RoleRegistry(TRADING_REGISTRY);
        TradingLens lens = TradingLens(TRADING_LENS);

        _checkTimelock(UPGRADE_TIMELOCK, UPGRADE_DELAY);
        require(registry.owner() == UPGRADE_TIMELOCK, "trading RoleRegistry owner is not the upgrade timelock");
        require(address(lens.roleRegistry()) == TRADING_REGISTRY, "lens points at another registry");
        require(_impl(TRADING_LENS) == OLD_LENS_IMPL, "lens is not on the expected live impl");

        _ensureLensImpl();
        bytes32 listerRole = TradingLens(NEW_LENS_IMPL).TRADING_LENS_TOKEN_LISTER_ROLE();
        require(listerRole == keccak256("TRADING_LENS_TOKEN_LISTER_ROLE"), "unexpected lister role hash");
        require(registry.roleHolders(listerRole).length == 0, "lister role already has a holder");
        require(!registry.hasRole(registry.ADMIN_ROLE(), TOKEN_LISTER), "listing wallet holds ADMIN_ROLE");

        targets.push(TRADING_LENS);
        payloads.push(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (NEW_LENS_IMPL, "")));
        targets.push(TRADING_REGISTRY);
        payloads.push(abi.encodeCall(RoleRegistry.grantRole, (listerRole, TOKEN_LISTER)));

        TimelockController tl = TimelockController(payable(UPGRADE_TIMELOCK));
        bytes32 id = tl.hashOperationBatch(targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, TL_SALT_ETH);
        require(!tl.isOperation(id), "operation already scheduled");

        (string memory schedulePath, string memory executePath) = _writeBundles(GOVERNANCE_SAFE, UPGRADE_TIMELOCK, UPGRADE_DELAY, TL_SALT_ETH, ETH_SCHEDULE_NONCE, ETH_EXECUTE_NONCE, "eth");

        // The Safe cannot upgrade or grant directly
        _expectRevert(GOVERNANCE_SAFE, TRADING_LENS, payloads[0], "Safe upgraded the lens directly");
        _expectRevert(GOVERNANCE_SAFE, TRADING_REGISTRY, payloads[1], "Safe granted the role directly");

        console.log("=== Simulating schedule (governance Safe nonce 70) ===");
        executeGnosisTransactionBundle(schedulePath);
        require(tl.isOperationPending(id) && !tl.isOperationReady(id), "operation not pending after schedule");
        _expectRevert(GOVERNANCE_SAFE, UPGRADE_TIMELOCK, _executeData(TL_SALT_ETH), "executeBatch succeeded before the delay");
        vm.warp(block.timestamp + OPERATING_DELAY + 1);
        _expectRevert(GOVERNANCE_SAFE, UPGRADE_TIMELOCK, _executeData(TL_SALT_ETH), "executeBatch succeeded after only 8 hours");

        vm.warp(block.timestamp + UPGRADE_DELAY);
        require(tl.isOperationReady(id), "operation not ready after 2 days");
        _replayBundles("BETWEEN_BUNDLES");

        // Read right before the execute, so changes from bundles replayed in between are not attributed to it
        tokensBefore = lens.getSupportedTokens();
        adminsBefore = registry.roleHolders(registry.ADMIN_ROLE());
        atlBefore = registry.roleHolders(registry.ADMIN_TIMELOCK_ROLE());

        console.log("=== Simulating execute (governance Safe nonce 72) ===");
        executeGnosisTransactionBundle(executePath);
        require(tl.isOperationDone(id), "operation not done after execute");

        // End state
        require(_impl(TRADING_LENS) == NEW_LENS_IMPL, "lens not on the new impl");
        require(address(lens.priceProvider()) == TRADING_PRICE_PROVIDER, "lens price provider changed");
        require(keccak256(abi.encode(lens.getSupportedTokens())) == keccak256(abi.encode(tokensBefore)), "supported tokens changed across the upgrade");
        address[] memory listers = registry.roleHolders(listerRole);
        require(listers.length == 1 && listers[0] == TOKEN_LISTER, "lister role not held by exactly the listing wallet");
        require(keccak256(abi.encode(registry.roleHolders(registry.ADMIN_ROLE()))) == keccak256(abi.encode(adminsBefore)), "ADMIN_ROLE holders changed");
        require(keccak256(abi.encode(registry.roleHolders(registry.ADMIN_TIMELOCK_ROLE()))) == keccak256(abi.encode(atlBefore)), "ADMIN_TIMELOCK_ROLE holders changed");
        require(registry.owner() == UPGRADE_TIMELOCK, "trading RoleRegistry owner changed");

        // Behaviour: the lister can add but not remove, a stranger cannot add
        address probe = address(0xC0FFEE);
        vm.expectRevert(TradingLens.OnlyTokenLister.selector);
        vm.prank(address(0xBEEF));
        lens.addSupportedToken(probe);
        vm.prank(TOKEN_LISTER);
        lens.addSupportedToken(probe);
        require(lens.isSupportedToken(probe), "lister could not add a token");
        vm.expectRevert(RoleRegistry.OnlyAdmin.selector);
        vm.prank(TOKEN_LISTER);
        lens.removeSupportedToken(probe);
        vm.prank(GOVERNANCE_SAFE);
        lens.removeSupportedToken(probe);
        require(!lens.isSupportedToken(probe), "admin could not remove the token");

        console.log("");
        console.log("  [OK] TradingLens upgraded to", NEW_LENS_IMPL);
        console.log("  [OK] TRADING_LENS_TOKEN_LISTER_ROLE granted to", TOKEN_LISTER);
        console.log("  supported tokens preserved:", tokensBefore.length);
        console.log("2-day operation id:");
        console.logBytes32(id);
    }

    function _ensureLensImpl() internal {
        require(_predictAddress(LENS_IMPL_SALT) == NEW_LENS_IMPL, "lens impl salt does not resolve to the pinned address");
        if (NEW_LENS_IMPL.code.length == 0) {
            console.log("WARNING: TradingLens impl not deployed on-chain yet; deploying on the fork only");
            vm.prank(DEPLOYER.getDeployers()[0]);
            DEPLOYER.deploy(getSalt(LENS_IMPL_SALT), abi.encodePacked(type(TradingLens).creationCode, abi.encode(TRADING_PRICE_PROVIDER)));
        }
        requireCodeMatchAllowingAddressEmbeds("TradingLensImpl", NEW_LENS_IMPL, address(new TradingLens(TRADING_PRICE_PROVIDER)));
    }

    function _impl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    // ═══════════════════════════════ shared ═══════════════════════════════

    function _replayBundles(string memory envKey) internal {
        string[] memory entries = vm.envOr(envKey, ",", new string[](0));
        for (uint256 i = 0; i < entries.length; ++i) {
            if (isEqualString(entries[i], "WARP")) {
                vm.warp(block.timestamp + UPGRADE_DELAY + 1);
                console.log(envKey, ": warped 2 days");
                continue;
            }
            string memory json = vm.readFile(entries[i]);
            require(vm.parseJsonUint(json, ".chainId") == block.chainid, "replayed bundle is for another chain");
            executeGnosisTransactionBundle(entries[i]);
            console.log(envKey, "replayed:", entries[i]);
        }
    }

    function _checkTimelock(address timelock, uint256 delay) internal view {
        require(keccak256(timelock.code) == keccak256(type(EtherFiTimelock).runtimeCode), "timelock bytecode != local build");
        EtherFiTimelock tl = EtherFiTimelock(payable(timelock));
        require(tl.getMinDelay() == delay, "timelock: unexpected delay");
        require(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), timelock), "timelock is not its own admin");
    }

    function _scheduleData(uint256 delay, bytes32 salt) internal view returns (bytes memory) {
        return abi.encodeCall(TimelockController.scheduleBatch, (targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, salt, delay));
    }

    function _executeData(bytes32 salt) internal view returns (bytes memory) {
        return abi.encodeCall(TimelockController.executeBatch, (targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, salt));
    }

    function _writeBundles(address safe, address timelock, uint256 delay, bytes32 salt, uint256 scheduleNonce, uint256 executeNonce, string memory chain) internal returns (string memory schedulePath, string memory executePath) {
        string memory prefix = string.concat("./output/CCTPRegate-", chain, "-", vm.toString(block.chainid), "-");
        schedulePath = string.concat(prefix, "nonce", vm.toString(scheduleNonce), "-schedule.json");
        executePath = string.concat(prefix, "nonce", vm.toString(executeNonce), "-execute.json");
        _writeBundle(schedulePath, safe, timelock, _scheduleData(delay, salt));
        _writeBundle(executePath, safe, timelock, _executeData(salt));
    }

    function _writeBundle(string memory path, address safe, address timelock, bytes memory data) internal {
        string memory header = _getGnosisHeader(vm.toString(block.chainid), addressToHex(safe));
        vm.writeFile(path, string.concat(header, _getGnosisTransaction(addressToHex(timelock), iToHex(data), "0", true)));
        console.log("Wrote", path);
    }

    function _expectRevert(address from, address to, bytes memory data, string memory err) internal {
        vm.prank(from);
        (bool ok,) = to.call(data);
        require(!ok, err);
    }
}
