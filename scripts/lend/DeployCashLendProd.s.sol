// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { BeaconFactory, UpgradeableBeacon } from "../../src/beacon-factory/BeaconFactory.sol";
import { AcrossSwapModule } from "../../src/across/AcrossSwapModule.sol";
import { EnsoSwapModule } from "../../src/enso/EnsoSwapModule.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { DebtManagerAdmin } from "../../src/debt-manager/DebtManagerAdmin.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";
import { IAaveV4Spoke } from "../../src/interfaces/IAaveV4Spoke.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { AaveV4Lens } from "../../src/lens/AaveV4Lens.sol";
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { CashLens } from "../../src/modules/cash/CashLens.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { EtherFiLiquidModuleWithReferrer } from "../../src/modules/etherfi/EtherFiLiquidModuleWithReferrer.sol";
import { EtherFiStakeModule } from "../../src/modules/etherfi/EtherFiStakeModule.sol";
import { LiquidUSDLiquifierOPModule } from "../../src/modules/etherfi/LiquidUSDLiquifierOP.sol";
import { FraxModule } from "../../src/modules/frax/FraxModule.sol";
import { BeHYPEStakeModule } from "../../src/modules/hype/BeHYPEStakeModule.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { MidasModule } from "../../src/modules/midas/MidasModule.sol";
import { OpenOceanSwapModule } from "../../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiSafe } from "../../src/safe/EtherFiSafe.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { CashLendProdConfig } from "./CashLendProdConfig.sol";

/**
 * @title DeployCashLendProd
 * @notice Upgrades the Optimism prod Cash deployment to Lend and generates the Gnosis Safe bundle
 *         with every privileged call. Two-actor flow:
 *
 *         1. The deployer EOA broadcasts only unprivileged CREATE3 deployments: every new
 *            implementation, the seven replacement modules (immutable, so new copies carry the old
 *            on-chain configuration), and the LendGateway proxy (initialized atomically in its
 *            constructor — never deploy-then-init). All of it goes through the protocol's
 *            permissioned CREATE3 deployer (EtherFiDeployer), never a public factory, so nobody can
 *            squat a `CashLendProd.*` address ahead of us — see _create3. The broadcaster must be in
 *            that deployer's registry; the script asserts this before broadcasting anything.
 *         2. Every privileged call (proxy upgrades, safe-beacon upgrade, module policy, gateway
 *            config, activation) is written to output/CashLendProd-10.json for the prod Safe
 *            (0xA6cf...AAC4) to execute via the Gnosis tx builder. The script simulates the full
 *            bundle against the fork and asserts the end state before writing anything.
 *
 *         Prerequisite: deployments/mainnet/10/summer-lend.json must exist with `.spoke` pointing
 *         at the live Summer Lend (Aave v4) Spoke from the AIP payload. The bundle includes
 *         `spoke.updatePositionManager(gateway, true)`; if the Safe does not hold the Spoke admin
 *         role on the prod instance, the simulation fails there — remove that tx and have the
 *         Spoke admin (or the AIP payload) activate the CREATE3-deterministic gateway address.
 *         NOTE: that address derives from EtherFiDeployer, not Nick's factory — re-derive it (run
 *         this script without --broadcast and read the summary) before handing it to anyone.
 *
 *         Module policy (default / whitelisted / withdraw-requester) is mirrored per module from
 *         the live chain rather than hardcoded, so prod-only differences (e.g. Stargate as a
 *         requester, Midas vault additions) carry over exactly. Old modules stay enabled for
 *         gradual migration — run scripts/lend/check-pending-withdrawals.sh before any later
 *         retirement pass.
 *
 * Usage (drop --broadcast to simulate; sender comes from CLI wallet flags):
 *   source .env && ENV=mainnet forge script scripts/lend/DeployCashLendProd.s.sol:DeployCashLendProd \
 *     --rpc-url $OPTIMISM_RPC --ledger --sender $PROD_DEPLOYER \
 *     --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvvv
 *
 * After the Safe executes the bundle:
 *   source .env && ENV=mainnet forge script scripts/lend/VerifyCashLendProd.s.sol \
 *     --rpc-url $OPTIMISM_RPC -vvvv
 */
contract DeployCashLendProd is Utils, GnosisHelpers, CashLendProdConfig {
    struct Existing {
        address cashEventEmitter;
        address cashLens;
        address cashModule;
        address dataProvider;
        address debtManager;
        address hook;
        address roleRegistry;
        address topUpDest;
        address safeFactory;
        // canonical module order: openOcean, liquid, liquidReferrer, frax, stake, midas, beHype
        address[7] modules;
        address liquifier;
        address enso;
        address across;
    }

    struct Deployed {
        address cashModuleCore;
        address cashModuleSetters;
        address cashLens;
        address cashEventEmitter;
        address debtManagerCore;
        address debtManagerAdmin;
        address hook;
        address topUpDest;
        address liquifierImpl;
        address ensoImpl;
        address acrossImpl;
        address safeImpl;
        address gatewayImpl;
        address gatewayProxy;
        address aaveV4LensImpl;
        address aaveV4LensProxy;
        address[7] modules;
    }

    /// @dev Live policy of the seven old modules, mirrored onto their replacements.
    struct Policy {
        bool[7] isDefault;
        bool[7] isWhitelisted;
        bool[7] isRequester;
    }

    struct TxItem {
        address to;
        bytes data;
    }

    TxItem[] internal bundle;

    function run() public {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "mainnet"), "ENV must be mainnet");

        Existing memory existing = _readExisting();
        (IAaveV4Spoke spoke, bool skipPositionManagerTx) = _readSpoke();
        Policy memory policy = _readPolicy(existing);
        _validateExisting(existing);
        require(RoleRegistry(existing.roleRegistry).owner() == SAFE, "RoleRegistry owner is not the prod Safe");
        _requireDeployer(msg.sender);

        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // ── 1. Deployer EOA: unprivileged CREATE3 deployments only ──
        vm.startBroadcast(privateKey);
        Deployed memory deployed = _deployAll(existing, address(spoke));
        vm.stopBroadcast();

        // ── 2. Build the Gnosis bundle ──
        _buildBundle(existing, deployed, spoke, policy, skipPositionManagerTx);
        string memory path = _writeBundle();

        // ── 3. Simulate the bundle as the Safe and assert the end state ──
        executeGnosisTransactionBundle(path);
        _assertEndState(existing, deployed, spoke, policy, skipPositionManagerTx);

        _writeDeploymentRecord(deployed, address(spoke));
        _logSummary(deployed, path);
    }

    // ─────────────────────────────── inputs ───────────────────────────────

    function _readExisting() internal view returns (Existing memory c) {
        string memory json = readDeploymentFile();
        c.cashEventEmitter = _addr(json, "CashEventEmitter");
        c.cashLens = _addr(json, "CashLens");
        c.cashModule = _addr(json, "CashModule");
        c.dataProvider = _addr(json, "EtherFiDataProvider");
        c.debtManager = _addr(json, "DebtManager");
        c.hook = _addr(json, "EtherFiHook");
        c.roleRegistry = _addr(json, "RoleRegistry");
        c.topUpDest = _addr(json, "TopUpDest");
        c.safeFactory = _addr(json, "EtherFiSafeFactory");
        c.modules[0] = _addr(json, "OpenOceanSwapModule");
        c.modules[1] = _addr(json, "EtherFiLiquidModule");
        c.modules[2] = _addr(json, "EtherFiLiquidModuleWithReferrer");
        c.modules[3] = _addr(json, "FraxModule");
        c.modules[4] = _addr(json, "EtherFiStakeModule");
        c.modules[5] = _addr(json, "MidasModule");
        c.modules[6] = _addr(json, "BeHYPEStakeModule");
        c.liquifier = _addr(json, "LiquidUSDLiquifierModule");

        string memory trading = vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet/10/trading-account.json"));
        c.enso = stdJson.readAddress(trading, ".EnsoSwapModule");
        c.across = stdJson.readAddress(trading, ".AcrossSwapModule");
    }

    function _addr(string memory json, string memory name) internal pure returns (address) {
        return stdJson.readAddress(json, string.concat(".addresses.", name));
    }

    /// @dev The prod Summer Lend instance ships via an Aave governance payload, so its Spoke lives in
    ///      a hand-maintained record, not this repo's deploy artifacts. Set the optional
    ///      `.skipPositionManagerTx: true` when the Spoke admin (not our Safe) activates the gateway
    ///      as a position manager — the bundle then omits that tx.
    function _readSpoke() internal view returns (IAaveV4Spoke, bool) {
        string memory path = string.concat(vm.projectRoot(), "/deployments/mainnet/10/summer-lend.json");
        require(vm.exists(path), "deployments/mainnet/10/summer-lend.json missing; create it with the live .spoke first");
        string memory json = vm.readFile(path);
        address spoke = stdJson.readAddress(json, ".spoke");
        require(spoke.code.length != 0, "summer-lend.json .spoke has no code");
        bool skipPositionManagerTx = vm.keyExistsJson(json, ".skipPositionManagerTx") && stdJson.readBool(json, ".skipPositionManagerTx");
        return (IAaveV4Spoke(spoke), skipPositionManagerTx);
    }

    function _readPolicy(Existing memory c) internal view returns (Policy memory policy) {
        address[] memory requesters = ICashModule(c.cashModule).getWhitelistedModulesCanRequestWithdraw();
        for (uint256 i = 0; i < 7; ++i) {
            policy.isDefault[i] = EtherFiDataProvider(c.dataProvider).isDefaultModule(c.modules[i]);
            policy.isWhitelisted[i] = EtherFiDataProvider(c.dataProvider).isWhitelistedModule(c.modules[i]);
            policy.isRequester[i] = _contains(requesters, c.modules[i]);
        }
    }

    function _validateExisting(Existing memory c) internal view {
        for (uint256 i = 0; i < 7; ++i) {
            require(c.modules[i].code.length != 0, "old module code missing");
        }
        require(c.liquifier.code.length != 0 && c.enso.code.length != 0 && c.across.code.length != 0, "old proxy code missing");
        // setLendGateway is one-time; a second run of the bundle would revert there.
        require(_currentLendGateway(c.cashModule) == address(0), "CashModule already references a lend gateway");
    }

    /// @dev Pre-upgrade the live impl has no getLendGateway(), so probe with a raw staticcall.
    function _currentLendGateway(address cashModule) internal view returns (address) {
        (bool ok, bytes memory ret) = cashModule.staticcall(abi.encodeWithSelector(ICashModule.getLendGateway.selector));
        if (!ok || ret.length != 32) return address(0);
        return abi.decode(ret, (address));
    }

    // ─────────────────────────────── deployments ───────────────────────────────

    function _deployAll(Existing memory c, address spoke) internal returns (Deployed memory d) {
        address weth = _fixtureAsset("weth");

        d.cashModuleCore = _create3("CashModuleCoreImpl", abi.encodePacked(type(CashModuleCore).creationCode, abi.encode(c.dataProvider)));
        d.cashModuleSetters = _create3("CashModuleSettersImpl", abi.encodePacked(type(CashModuleSetters).creationCode, abi.encode(c.dataProvider)));
        d.cashLens = _create3("CashLensImpl", abi.encodePacked(type(CashLens).creationCode, abi.encode(c.cashModule, c.dataProvider)));
        d.cashEventEmitter = _create3("CashEventEmitterImpl", abi.encodePacked(type(CashEventEmitter).creationCode, abi.encode(c.cashModule)));
        d.debtManagerCore = _create3("DebtManagerCoreImpl", abi.encodePacked(type(DebtManagerCore).creationCode, abi.encode(c.dataProvider)));
        d.debtManagerAdmin = _create3("DebtManagerAdminImpl", abi.encodePacked(type(DebtManagerAdmin).creationCode, abi.encode(c.dataProvider)));
        d.hook = _create3("EtherFiHookImpl", abi.encodePacked(type(EtherFiHook).creationCode, abi.encode(c.dataProvider)));
        d.topUpDest = _create3("TopUpDestImpl", abi.encodePacked(type(TopUpDest).creationCode, abi.encode(c.dataProvider, weth)));
        d.liquifierImpl = _create3("LiquifierImpl", abi.encodePacked(type(LiquidUSDLiquifierOPModule).creationCode, abi.encode(c.debtManager, c.dataProvider)));
        d.ensoImpl = _create3("EnsoImpl", abi.encodePacked(type(EnsoSwapModule).creationCode, abi.encode(c.dataProvider)));
        d.acrossImpl = _create3("AcrossImpl", abi.encodePacked(type(AcrossSwapModule).creationCode, abi.encode(c.dataProvider)));
        d.safeImpl = _create3("EtherFiSafeImpl", abi.encodePacked(type(EtherFiSafe).creationCode, abi.encode(c.dataProvider)));

        d.gatewayImpl = _create3("LendGatewayImpl", abi.encodePacked(type(LendGateway).creationCode, abi.encode(c.dataProvider, spoke)));
        d.gatewayProxy = _create3(
            "LendGatewayProxy",
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(d.gatewayImpl, abi.encodeWithSelector(LendGateway.initialize.selector, c.roleRegistry)))
        );

        // Read-only aggregator for the cash backend; the spoke is a call argument, so no Safe txs.
        d.aaveV4LensImpl = _create3("AaveV4LensImpl", type(AaveV4Lens).creationCode);
        d.aaveV4LensProxy = _create3(
            "AaveV4LensProxy",
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(d.aaveV4LensImpl, abi.encodeWithSelector(AaveV4Lens.initialize.selector, c.roleRegistry)))
        );

        d.modules = _deployModules(c);
    }

    /// @dev The seven direct modules are immutable, so Lend support means new copies that repeat the
    ///      old on-chain constructor configuration exactly. One helper per module keeps the default
    ///      (non-via-ir) profile clear of stack-too-deep.
    function _deployModules(Existing memory c) internal returns (address[7] memory modules) {
        modules[0] = _deployOpenOcean(c.modules[0], c.dataProvider);
        modules[1] = _deployLiquid("LiquidModule", c.modules[1], c.dataProvider, false);
        modules[2] = _deployLiquid("LiquidReferrerModule", c.modules[2], c.dataProvider, true);
        modules[3] = _deployFrax(c.modules[3], c.dataProvider);
        modules[4] = _deployStake(c.modules[4], c.dataProvider);
        modules[5] = _deployMidas(c.modules[5], c.dataProvider);
        modules[6] = _deployBeHype(c.modules[6], c.dataProvider);
    }

    function _deployOpenOcean(address old, address dataProvider) internal returns (address) {
        bytes memory args = abi.encode(OpenOceanSwapModule(old).swapRouter(), dataProvider);
        return _create3("OpenOceanModule", abi.encodePacked(type(OpenOceanSwapModule).creationCode, args));
    }

    function _deployLiquid(string memory name, address old, address dataProvider, bool referrer) internal returns (address) {
        (address[] memory assets, address[] memory tellers) = _liquidConfig(EtherFiLiquidModule(old));
        bytes memory args = abi.encode(assets, tellers, dataProvider, EtherFiLiquidModule(old).weth());
        bytes memory creationCode = referrer ? type(EtherFiLiquidModuleWithReferrer).creationCode : type(EtherFiLiquidModule).creationCode;
        return _create3(name, abi.encodePacked(creationCode, args));
    }

    function _deployFrax(address old, address dataProvider) internal returns (address) {
        bytes memory args = abi.encode(dataProvider, FraxModule(old).fraxusd(), FraxModule(old).custodian(), FraxModule(old).remoteHop());
        return _create3("FraxModule", abi.encodePacked(type(FraxModule).creationCode, args));
    }

    function _deployStake(address old, address dataProvider) internal returns (address) {
        bytes memory args = abi.encode(dataProvider, address(EtherFiStakeModule(old).syncPool()), EtherFiStakeModule(old).weth(), EtherFiStakeModule(old).weETH());
        return _create3("StakeModule", abi.encodePacked(type(EtherFiStakeModule).creationCode, args));
    }

    function _deployMidas(address old, address dataProvider) internal returns (address) {
        (address[] memory tokens, address[] memory deposits, address[] memory redemptions) = _midasConfig(MidasModule(old));
        bytes memory args = abi.encode(dataProvider, tokens, deposits, redemptions);
        return _create3("MidasModule", abi.encodePacked(type(MidasModule).creationCode, args));
    }

    function _deployBeHype(address old, address dataProvider) internal returns (address) {
        bytes memory args = abi.encode(dataProvider, address(BeHYPEStakeModule(old).staker()), BeHYPEStakeModule(old).whype(), BeHYPEStakeModule(old).beHYPE(), BeHYPEStakeModule(old).getRefundGasLimit());
        return _create3("BeHYPEModule", abi.encodePacked(type(BeHYPEStakeModule).creationCode, args));
    }

    /// @dev Idempotent CREATE3 through the protocol's OWN permissioned deployer. The salt (not the
    ///      initcode) fixes the address, so verification scripts can predict and require every
    ///      deployed address exactly.
    ///
    ///      Why not Nick's factory: CREATE3 through a PUBLIC factory derives the address from the
    ///      salt alone, and the intermediate CREATE3 proxy accepts a call from anybody. Our salts are
    ///      public (this repo is public), so anyone could occupy every `CashLendProd.*` address with
    ///      bytecode of their choosing before we broadcast. The skip-if-code-exists branch below
    ///      would then hand that foreign address straight into the Safe bundle as an implementation.
    ///      EtherFiDeployer.deploy is registry-gated and creates + consumes its CREATE3 proxy in one
    ///      call, so no outsider can ever place code at these addresses. That makes the skip safe:
    ///      code here can only have come from a registered deployer, i.e. from us.
    function _create3(string memory name, bytes memory creationCode) internal returns (address deployed) {
        deployed = _predicted(name);

        if (deployed.code.length > 0) {
            console.log("  [SKIP]", name, "already deployed at", deployed);
            return deployed;
        }

        address actual = EtherFiDeployer(ETHERFI_DEPLOYER).deploy(_salt(name), creationCode);
        require(actual == deployed, string.concat("CREATE3 address mismatch: ", name));
        require(deployed.code.length > 0, string.concat("CREATE3 verification failed: ", name));
        console.log(string.concat("  ", name, ":"), deployed);
    }

    /// @dev Fails before any broadcast if the deployer isn't the recorded one, isn't live on this
    ///      chain, or hasn't authorised the broadcaster — the whole no-squatting guarantee rests on
    ///      deploying through this contract, so it is not allowed to silently drift.
    function _requireDeployer(address broadcaster) internal view {
        address recorded = stdJson.readAddress(
            vm.readFile(string.concat(vm.projectRoot(), DEPLOYER_RECORD_PATH)), ".EtherFiDeployer"
        );
        require(recorded == ETHERFI_DEPLOYER, "ETHERFI_DEPLOYER does not match deployments/deployer/etherfi-deployer.json");
        require(ETHERFI_DEPLOYER.code.length != 0, "EtherFiDeployer not deployed on this chain");
        require(
            EtherFiDeployer(ETHERFI_DEPLOYER).isDeployer(broadcaster),
            "broadcaster is not a registered EtherFiDeployer deployer; owner must call configureDeployers first"
        );
    }

    // ─────────────────────────────── gnosis bundle ───────────────────────────────

    function _buildBundle(Existing memory c, Deployed memory d, IAaveV4Spoke spoke, Policy memory policy, bool skipPositionManagerTx) internal {
        // Proxy upgrades and delegated implementation pointers.
        _push(c.cashModule, abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, d.cashModuleCore, ""));
        _push(c.cashModule, abi.encodeWithSelector(ICashModule.setCashModuleSettersAddress.selector, d.cashModuleSetters));
        _push(c.cashLens, abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, d.cashLens, ""));
        _push(c.cashEventEmitter, abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, d.cashEventEmitter, ""));
        _push(c.debtManager, abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, d.debtManagerCore, ""));
        _push(c.debtManager, abi.encodeWithSelector(IDebtManager.setAdminImpl.selector, d.debtManagerAdmin));
        _push(c.hook, abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, d.hook, ""));
        _push(c.topUpDest, abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, d.topUpDest, ""));
        _push(c.liquifier, abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, d.liquifierImpl, ""));
        _push(c.enso, abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, d.ensoImpl, ""));
        _push(c.across, abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, d.acrossImpl, ""));

        // Safe beacon: RecoveryManager zero-threshold fix rides along; every Safe picks it up at once.
        _push(c.safeFactory, abi.encodeWithSelector(BeaconFactory.upgradeBeaconImplementation.selector, d.safeImpl));

        // Gateway configuration. The Safe grants itself the (new) gateway admin role first.
        _push(c.roleRegistry, abi.encodeWithSignature("grantRole(bytes32,address)", keccak256("LEND_GATEWAY_ADMIN_ROLE"), SAFE));
        _push(c.dataProvider, abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, _singleton(d.gatewayProxy), _bools(1, true)));

        uint256 reserveCount = spoke.getReserveCount();
        for (uint256 reserveId = 0; reserveId < reserveCount; ++reserveId) {
            _push(d.gatewayProxy, abi.encodeWithSelector(LendGateway.setReserveId.selector, spoke.getReserve(reserveId).underlying, reserveId));
        }
        string[7] memory spendAssetKeys = _spendAssetKeys();
        for (uint256 i = 0; i < spendAssetKeys.length; ++i) {
            _push(d.gatewayProxy, abi.encodeWithSelector(LendGateway.setSpendAsset.selector, _fixtureAsset(spendAssetKeys[i]), true));
        }
        _push(d.gatewayProxy, abi.encodeWithSelector(LendGateway.setMinHealthFactor.selector, MIN_HEALTH_FACTOR));

        // Drivers: everything that runs the lend sandwich or migration against the gateway.
        _push(d.gatewayProxy, abi.encodeWithSelector(LendGateway.setDriver.selector, c.debtManager, true));
        _push(d.gatewayProxy, abi.encodeWithSelector(LendGateway.setDriver.selector, c.topUpDest, true));
        for (uint256 i = 0; i < 7; ++i) {
            _push(d.gatewayProxy, abi.encodeWithSelector(LendGateway.setDriver.selector, d.modules[i], true));
        }
        _push(d.gatewayProxy, abi.encodeWithSelector(LendGateway.setDriver.selector, c.liquifier, true));
        _push(d.gatewayProxy, abi.encodeWithSelector(LendGateway.setDriver.selector, c.enso, true));
        _push(d.gatewayProxy, abi.encodeWithSelector(LendGateway.setDriver.selector, c.across, true));

        // Withdraw queues are post-constructor state, so copy them onto the new liquid modules
        // (the Safe holds ETHERFI_LIQUID_MODULE_ADMIN).
        _pushQueueCopies(EtherFiLiquidModule(c.modules[1]), d.modules[1]);
        _pushQueueCopies(EtherFiLiquidModule(c.modules[2]), d.modules[2]);

        // Enable the new modules with each old module's exact live policy. Old modules stay enabled.
        _pushModuleActivation(c, d, policy);

        // Gateway must be an active position manager on the Spoke before any Safe routes through it.
        // If the prod Spoke's ACL does not grant our Safe, set `.skipPositionManagerTx: true` in
        // summer-lend.json and have the Spoke admin (or the AIP payload) run this call instead.
        if (!skipPositionManagerTx && !spoke.isPositionManagerActive(d.gatewayProxy)) {
            _push(address(spoke), abi.encodeWithSelector(IAaveV4Spoke.updatePositionManager.selector, d.gatewayProxy, true));
        }

        // Activation last, so no Safe can reach a half-configured gateway (one-time set).
        _push(c.cashModule, abi.encodeWithSelector(ICashModule.setLendGateway.selector, d.gatewayProxy));
    }

    function _pushQueueCopies(EtherFiLiquidModule oldModule, address newModule) internal {
        address[9] memory assets = _liquidAssetCandidates();
        for (uint256 i = 0; i < assets.length; ++i) {
            address queue = oldModule.liquidWithdrawQueue(assets[i]);
            if (queue != address(0)) {
                _push(newModule, abi.encodeWithSelector(EtherFiLiquidModule.setLiquidAssetWithdrawQueue.selector, assets[i], queue));
            }
        }
    }

    function _pushModuleActivation(Existing memory c, Deployed memory d, Policy memory policy) internal {
        address[] memory newModules = new address[](7);
        bool[] memory defaultFlags = new bool[](7);
        bool[] memory whitelistFlags = new bool[](7);
        bool[] memory requesterFlags = new bool[](7);
        for (uint256 i = 0; i < 7; ++i) {
            newModules[i] = d.modules[i];
            defaultFlags[i] = policy.isDefault[i];
            whitelistFlags[i] = policy.isWhitelisted[i] && !policy.isDefault[i];
            requesterFlags[i] = policy.isRequester[i];
        }
        // configureDefaultModules whitelists as a side effect; configureModules covers the
        // whitelisted-but-not-default remainder.
        _push(c.dataProvider, abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, _filter(newModules, defaultFlags), _bools(_count(defaultFlags), true)));
        if (_count(whitelistFlags) > 0) {
            _push(c.dataProvider, abi.encodeWithSelector(EtherFiDataProvider.configureModules.selector, _filter(newModules, whitelistFlags), _bools(_count(whitelistFlags), true)));
        }
        _push(c.cashModule, abi.encodeWithSelector(ICashModule.configureModulesCanRequestWithdraw.selector, newModules, requesterFlags));
    }

    function _push(address to, bytes memory data) internal {
        bundle.push(TxItem({ to: to, data: data }));
    }

    function _writeBundle() internal returns (string memory path) {
        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
        for (uint256 i = 0; i < bundle.length; ++i) {
            txs = string.concat(txs, _getGnosisTransaction(addressToHex(bundle[i].to), iToHex(bundle[i].data), "0", i == bundle.length - 1));
        }
        path = string.concat("./output/CashLendProd-", vm.toString(block.chainid), ".json");
        vm.writeFile(path, txs);
    }

    // ─────────────────────────────── post-simulation asserts ───────────────────────────────

    function _assertEndState(Existing memory c, Deployed memory d, IAaveV4Spoke spoke, Policy memory policy, bool skipPositionManagerTx) internal view {
        require(_implementationOf(c.cashModule) == d.cashModuleCore, "CashModule impl mismatch");
        require(CashModuleCore(c.cashModule).getCashModuleSetters() == d.cashModuleSetters, "CashModule setters mismatch");
        require(_implementationOf(c.cashLens) == d.cashLens, "CashLens impl mismatch");
        require(_implementationOf(c.cashEventEmitter) == d.cashEventEmitter, "CashEventEmitter impl mismatch");
        require(_implementationOf(c.debtManager) == d.debtManagerCore, "DebtManager impl mismatch");
        require(IDebtManager(c.debtManager).getDebtManagerAdmin() == d.debtManagerAdmin, "DebtManager admin mismatch");
        require(_implementationOf(c.hook) == d.hook, "EtherFiHook impl mismatch");
        require(_implementationOf(c.topUpDest) == d.topUpDest, "TopUpDest impl mismatch");
        require(_implementationOf(c.liquifier) == d.liquifierImpl, "Liquifier impl mismatch");
        require(_implementationOf(c.enso) == d.ensoImpl, "Enso impl mismatch");
        require(_implementationOf(c.across) == d.acrossImpl, "Across impl mismatch");
        require(UpgradeableBeacon(BeaconFactory(c.safeFactory).beacon()).implementation() == d.safeImpl, "Safe beacon impl mismatch");

        require(_implementationOf(d.gatewayProxy) == d.gatewayImpl, "LendGateway impl mismatch");
        require(_implementationOf(d.aaveV4LensProxy) == d.aaveV4LensImpl, "AaveV4Lens impl mismatch");
        require(address(ICashModule(c.cashModule).getLendGateway()) == d.gatewayProxy, "LendGateway not set on CashModule");
        LendGateway gateway = LendGateway(d.gatewayProxy);
        require(gateway.isDriver(c.debtManager) && gateway.isDriver(c.topUpDest), "core drivers missing");
        require(gateway.isDriver(c.liquifier) && gateway.isDriver(c.enso) && gateway.isDriver(c.across), "proxy module drivers missing");
        // 0 is a valid value that DISABLES the floor (LendGateway.ensureMinHealthFactor no-ops), so a
        // dropped or edited setMinHealthFactor tx must fail here rather than ship without the buffer.
        require(gateway.minHealthFactor() == MIN_HEALTH_FACTOR, "minHealthFactor not set");
        string[7] memory spendAssetKeys = _spendAssetKeys();
        for (uint256 i = 0; i < spendAssetKeys.length; ++i) {
            require(gateway.isSpendAsset(_fixtureAsset(spendAssetKeys[i])), string.concat(spendAssetKeys[i], " not a spend asset"));
        }
        if (skipPositionManagerTx) {
            if (!spoke.isPositionManagerActive(d.gatewayProxy)) {
                console.log("WARNING: gateway is not yet an active position manager; the Spoke admin must activate it before any Safe migrates");
            }
        } else {
            require(spoke.isPositionManagerActive(d.gatewayProxy), "gateway not an active position manager");
        }
        require(EtherFiDataProvider(c.dataProvider).isDefaultModule(d.gatewayProxy), "gateway not a default module");

        uint256 reserveCount = spoke.getReserveCount();
        for (uint256 reserveId = 0; reserveId < reserveCount; ++reserveId) {
            require(gateway.isRegistered(spoke.getReserve(reserveId).underlying), "reserve not mirrored");
        }

        address[] memory requesters = ICashModule(c.cashModule).getWhitelistedModulesCanRequestWithdraw();
        for (uint256 i = 0; i < 7; ++i) {
            require(gateway.isDriver(d.modules[i]), "new module not a driver");
            require(EtherFiDataProvider(c.dataProvider).isDefaultModule(d.modules[i]) == policy.isDefault[i], "default policy not mirrored");
            require(EtherFiDataProvider(c.dataProvider).isWhitelistedModule(d.modules[i]) == policy.isWhitelisted[i], "whitelist policy not mirrored");
            require(_contains(requesters, d.modules[i]) == policy.isRequester[i], "requester policy not mirrored");
            // Old modules stay enabled for gradual migration.
            require(EtherFiDataProvider(c.dataProvider).isWhitelistedModule(c.modules[i]) == policy.isWhitelisted[i], "old module policy changed");
        }

        _assertCopiedLiquidConfig(EtherFiLiquidModule(c.modules[1]), EtherFiLiquidModule(d.modules[1]));
        _assertCopiedLiquidConfig(EtherFiLiquidModule(c.modules[2]), EtherFiLiquidModule(d.modules[2]));

        // A tx injected into the bundle could hand over governance; this must be the last check.
        require(RoleRegistry(c.roleRegistry).owner() == SAFE, "CRITICAL: RoleRegistry owner changed");
    }

    function _assertCopiedLiquidConfig(EtherFiLiquidModule oldModule, EtherFiLiquidModule newModule) internal view {
        address[9] memory assets = _liquidAssetCandidates();
        for (uint256 i = 0; i < assets.length; ++i) {
            require(newModule.liquidAssetToTeller(assets[i]) == oldModule.liquidAssetToTeller(assets[i]), "liquid teller mismatch");
            require(newModule.liquidWithdrawQueue(assets[i]) == oldModule.liquidWithdrawQueue(assets[i]), "liquid queue mismatch");
        }
    }

    // ─────────────────────────────── record & summary ───────────────────────────────

    function _writeDeploymentRecord(Deployed memory d, address spoke) internal {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) && !vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
            console.log("Dry run, not writing deployment record");
            return;
        }

        string memory object = "cash-lend-prod";
        vm.serializeUint(object, "chainId", block.chainid);
        vm.serializeAddress(object, "safe", SAFE);
        vm.serializeAddress(object, "create3Deployer", ETHERFI_DEPLOYER);
        vm.serializeAddress(object, "spoke", spoke);
        vm.serializeAddress(object, "lendGateway", d.gatewayProxy);
        vm.serializeAddress(object, "lendGatewayImpl", d.gatewayImpl);
        vm.serializeAddress(object, "aaveV4Lens", d.aaveV4LensProxy);
        vm.serializeAddress(object, "aaveV4LensImpl", d.aaveV4LensImpl);
        vm.serializeAddress(object, "cashModuleCoreImpl", d.cashModuleCore);
        vm.serializeAddress(object, "cashModuleSettersImpl", d.cashModuleSetters);
        vm.serializeAddress(object, "cashLensImpl", d.cashLens);
        vm.serializeAddress(object, "cashEventEmitterImpl", d.cashEventEmitter);
        vm.serializeAddress(object, "debtManagerCoreImpl", d.debtManagerCore);
        vm.serializeAddress(object, "debtManagerAdminImpl", d.debtManagerAdmin);
        vm.serializeAddress(object, "etherFiHookImpl", d.hook);
        vm.serializeAddress(object, "topUpDestImpl", d.topUpDest);
        vm.serializeAddress(object, "liquifierImpl", d.liquifierImpl);
        vm.serializeAddress(object, "ensoImpl", d.ensoImpl);
        vm.serializeAddress(object, "acrossImpl", d.acrossImpl);
        vm.serializeAddress(object, "etherFiSafeImpl", d.safeImpl);
        vm.serializeAddress(object, "openOcean", d.modules[0]);
        vm.serializeAddress(object, "liquid", d.modules[1]);
        vm.serializeAddress(object, "liquidReferrer", d.modules[2]);
        vm.serializeAddress(object, "frax", d.modules[3]);
        vm.serializeAddress(object, "stake", d.modules[4]);
        vm.serializeAddress(object, "midas", d.modules[5]);
        string memory output = vm.serializeAddress(object, "beHype", d.modules[6]);

        string memory path = string.concat(vm.projectRoot(), "/deployments/mainnet/10/cash-lend.json");
        vm.writeJson(output, path);
        console.log("Deployment record:", path);
    }

    function _logSummary(Deployed memory d, string memory path) internal view {
        console.log("");
        console.log("=== Deployed (EOA, CREATE3) ===");
        console.log("LendGateway proxy:       ", d.gatewayProxy);
        console.log("LendGateway impl:        ", d.gatewayImpl);
        console.log("AaveV4Lens proxy:        ", d.aaveV4LensProxy);
        console.log("AaveV4Lens impl:         ", d.aaveV4LensImpl);
        console.log("CashModuleCore impl:     ", d.cashModuleCore);
        console.log("CashModuleSetters impl:  ", d.cashModuleSetters);
        console.log("CashLens impl:           ", d.cashLens);
        console.log("CashEventEmitter impl:   ", d.cashEventEmitter);
        console.log("DebtManagerCore impl:    ", d.debtManagerCore);
        console.log("DebtManagerAdmin impl:   ", d.debtManagerAdmin);
        console.log("EtherFiHook impl:        ", d.hook);
        console.log("TopUpDest impl:          ", d.topUpDest);
        console.log("Liquifier impl:          ", d.liquifierImpl);
        console.log("Enso impl:               ", d.ensoImpl);
        console.log("Across impl:             ", d.acrossImpl);
        console.log("EtherFiSafe impl:        ", d.safeImpl);
        console.log("OpenOcean module:        ", d.modules[0]);
        console.log("Liquid module:           ", d.modules[1]);
        console.log("Liquid referrer module:  ", d.modules[2]);
        console.log("Frax module:             ", d.modules[3]);
        console.log("Stake module:            ", d.modules[4]);
        console.log("Midas module:            ", d.modules[5]);
        console.log("BeHYPE module:           ", d.modules[6]);
        console.log("");
        console.log("Gnosis bundle (%s txs):", vm.toString(bundle.length));
        console.log("  ", path);
    }

    // ─────────────────────────────── shared helpers ───────────────────────────────

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPLEMENTATION_SLOT))));
    }

    /// @dev Utils.getChainConfig parses fixture keys chain 10 doesn't have, so read directly.
    function _fixtureAsset(string memory key) internal view returns (address) {
        string memory fixtures = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/fixtures/fixtures.json"));
        return stdJson.readAddress(fixtures, string.concat(".", vm.toString(block.chainid), ".", key));
    }

    function _singleton(address value) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = value;
    }

    function _bools(uint256 length, bool value) internal pure returns (bool[] memory values) {
        values = new bool[](length);
        for (uint256 i = 0; i < length; ++i) {
            values[i] = value;
        }
    }

    function _filter(address[] memory values, bool[] memory keep) internal pure returns (address[] memory) {
        address[] memory filtered = new address[](_count(keep));
        uint256 j;
        for (uint256 i = 0; i < values.length; ++i) {
            if (keep[i]) filtered[j++] = values[i];
        }
        return filtered;
    }

    function _count(bool[] memory flags) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < flags.length; ++i) {
            if (flags[i]) ++count;
        }
    }

    function _contains(address[] memory values, address value) internal pure returns (bool) {
        for (uint256 i = 0; i < values.length; ++i) {
            if (values[i] == value) return true;
        }
        return false;
    }
}
