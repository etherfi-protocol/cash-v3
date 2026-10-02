// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console2 } from "forge-std/console2.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { RoleRegistry } from "../../../src/role-registry/RoleRegistry.sol";
import { EtherFiDataProvider } from "../../../src/data-provider/EtherFiDataProvider.sol";
import { CashModuleCore } from "../../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../../src/modules/cash/CashModuleSetters.sol";
import { ICashModule } from "../../../src/interfaces/ICashModule.sol";
import { DebtManagerCore } from "../../../src/debt-manager/DebtManagerCore.sol";
import { DebtManagerAdmin } from "../../../src/debt-manager/DebtManagerAdmin.sol";
import { IDebtManager } from "../../../src/interfaces/IDebtManager.sol";
import { PriceProviderV2 } from "../../../src/oracle/PriceProviderV2.sol";
import { AcrossSwapModule } from "../../../src/across/AcrossSwapModule.sol";
import { EnsoSwapModule } from "../../../src/enso/EnsoSwapModule.sol";
import { StockWithdrawModule } from "../../../src/stock-withdraw/StockWithdrawModule.sol";
import { LendGateway } from "../../../src/modules/lend-gateway/LendGateway.sol";
import { TopUpDest } from "../../../src/top-up/TopUpDest.sol";
import { SettlementDispatcherV2 } from "../../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { BinSponsor } from "../../../src/interfaces/ICashModule.sol";
import { CashbackDispatcher } from "../../../src/cashback-dispatcher/CashbackDispatcher.sol";
import { EtherFiLiquidModule } from "../../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { EtherFiLiquidModuleWithReferrer } from "../../../src/modules/etherfi/EtherFiLiquidModuleWithReferrer.sol";
import { StargateModule } from "../../../src/modules/stargate/StargateModule.sol";
import { BeHYPEStakeModule } from "../../../src/modules/hype/BeHYPEStakeModule.sol";
import { MidasModule } from "../../../src/modules/midas/MidasModule.sol";
import { EtherFiDeployer } from "../../../src/utils/EtherFiDeployer.sol";
import { Utils } from "../../utils/Utils.sol";

/**
 * @notice Brings OP dev's cash stack onto re-gated code, mirroring what prod's role-gating batch 3
 *         did on Optimism: upgrades the proxies whose access control was re-gated onto the
 *         RoleRegistry's ADMIN_ROLE / ADMIN_TIMELOCK_ROLE, and redeploys the five immutable
 *         modules (EtherFiLiquidModule, EtherFiLiquidModuleWithReferrer, StargateModule,
 *         BeHYPEStakeModule, MidasModule) alongside the old ones with their live config copied
 *         over.
 *
 *         OP dev's RoleRegistry is already re-gated (impl upgraded, DEV_ADMIN already holds
 *         ADMIN_ROLE and ADMIN_TIMELOCK_ROLE) - this script only asserts that precondition, it
 *         does not re-gate the registry itself.
 *
 *         The old modules are left exactly as they are: still default, still whitelisted, still
 *         LendGateway drivers, still withdraw-requesters. The new modules are added alongside
 *         them. Nothing old is demoted, un-whitelisted or un-drivered here - that is a separate,
 *         explicitly approved cutover step.
 *
 *         Idempotent - every deploy and every wiring call is skipped when already in the target
 *         state, so a partially-run or re-run broadcast is safe. With PRIVATE_KEY unset the run
 *         impersonates DEV_ADMIN (fork simulation); a real broadcast must supply the dev admin key.
 *
 * Usage (simulate):
 *   source .env && forge script scripts/dev/role-regating/DeployRoleRegatingOPDev.s.sol \
 *     --rpc-url $OPTIMISM_RPC
 *
 * Usage (broadcast):
 *   source .env && forge script scripts/dev/role-regating/DeployRoleRegatingOPDev.s.sol \
 *     --rpc-url $OPTIMISM_RPC --broadcast --verify
 */
contract DeployRoleRegatingOPDev is Utils {
    using stdJson for string;

    EtherFiDeployer private constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);
    address private constant DEV_ADMIN = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;

    // -- Dev OP proxies / contracts (deployments/dev/10/deployments.json) --
    address private constant DATA_PROVIDER = 0x4a9c44c97BBf6079db37C4769AebE425bBcDD09a;
    address private constant ROLE_REGISTRY = 0xa322a04d1e2Cb44672473740F9F35B057FA29CFB;
    address private constant CASH_MODULE = 0xA4F3A3229FDFBfc7A30FEAC42337d931E85Dc969;
    address private constant DEBT_MANAGER = 0x92adCa2e95Eb9aCcA65a7dBa1A03ad5246d8f4F4;
    address private constant PRICE_PROVIDER = 0x7d7947D1ace9088048AaB067cF2F54eA1F762a4f;
    address private constant ACROSS_SWAP_MODULE = 0x7EF26F117a5C4f84A0caE2f79a61Af90Fb1D8e8A;
    address private constant ENSO_SWAP_MODULE = 0xd6B0c55f4F2bFdFe9355e5Af1Bac0f3DAb101DC2;
    address private constant STOCK_WITHDRAW_MODULE = 0x367c0f68599c4B75DBeC7500dFA6dB7F55a1Dd0c;
    address private constant LEND_GATEWAY = 0x26ba458CFc67e73dB227AB7BBd71d33d04865695;
    address private constant CASHBACK_DISPATCHER = 0x88758BDA231b8d989AFA0B408FfFD1dF67021F10;
    address private constant TOP_UP_DEST = 0x06fe42Cf3C63412f1955758ce2798709476a38fd;
    address private constant SETTLEMENT_RAIN = 0x26d90676C6aeF2a09Cf383af499cc67E9D6ad7CA;
    address private constant SETTLEMENT_REAP = 0xea6e574886797A65eD22CcF2307e48a83C355771;
    address private constant SETTLEMENT_PIX = 0xe61c5A65d26fDf27260cf34281a691a227C34bA3;
    address private constant SETTLEMENT_CARD_ORDER = 0x8e7AB8E9037FBd6C91f3758c6c9E2abf92675Aea;

    // -- Old immutable modules, left exactly as-is --
    address private constant OLD_LIQUID_MODULE = 0xC5B64C973ac9D8fd04c77addC43970ce08b0dA9b;
    address private constant OLD_LIQUID_MODULE_REFERRER = 0xC40C1C57fdb3B1480D791298E8A059ae7872A6c1;
    address private constant OLD_STARGATE_MODULE = 0x88626Bd138A5435733675f4Bcd8e156ba1282911;
    address private constant OLD_BEHYPE_STAKE_MODULE = 0xACF460cacB308Ca12773FBD1729944e9eb8EF185;
    address private constant OLD_MIDAS_MODULE = 0x9AB4a3943E0edcE47fE2E746Ca50957afFec796c;

    address private constant WETH = 0x4200000000000000000000000000000000000006;

    // -- Candidate addresses used to read live config off the old modules. New assets listed on
    //    dev after this file was written must be appended here before re-running, the same
    //    constraint prod's batch-3 config file carries. --
    address private constant LIQUID_ETH = 0xf0bb20865277aBd641a307eCe5Ee04E79073416C;
    address private constant LIQUID_BTC = 0x5f46d540b6eD704C3c8789105F30E075AA900726;
    address private constant LIQUID_USD = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address private constant EBTC = 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;
    address private constant SETHFI = 0x86B5780b606940Eb59A062aA85a07959518c0161;
    address private constant STARGATE_USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address private constant STARGATE_WEETH = 0x5A7fACB970D094B6C7FF1df0eA68D99E6e73CBFF;
    address private constant MIDAS_TOKEN = 0xca5921DF65E2e1b0B98Ae91c0187BA80D4124898;

    string private constant SALT_PREFIX = "RoleRegating.Dev.v1.OP.";
    string private constant MANIFEST_PATH = "/deployments/dev/10/role-regating.json";

    function run() external {
        require(block.chainid == 10, "must run on Optimism");
        require(DEPLOYER.isDeployer(DEV_ADMIN), "dev admin is not an EtherFiDeployer");

        RoleRegistry registry = RoleRegistry(ROLE_REGISTRY);
        require(registry.owner() == DEV_ADMIN, "dev admin does not own the OP RoleRegistry");
        require(address(registry.etherFiDataProvider()) == DATA_PROVIDER, "registry points at the wrong data provider");

        // OP's RoleRegistry was already re-gated before this script exists (ADMIN_ROLE() resolves
        // and DEV_ADMIN already holds both roles) - this script never grants or upgrades it.
        require(registry.hasRole(registry.ADMIN_ROLE(), DEV_ADMIN), "DEV_ADMIN lacks ADMIN_ROLE on OP registry");
        require(registry.hasRole(registry.ADMIN_TIMELOCK_ROLE(), DEV_ADMIN), "DEV_ADMIN lacks ADMIN_TIMELOCK_ROLE on OP registry");

        _startBroadcast();

        address[] memory newImpls = _deployAndUpgradeProxies();
        address[] memory newModules = _redeployImmutableModules();
        _wireNewModules(newModules);

        vm.stopBroadcast();

        _verifyGovernanceUnchanged(registry);
        _writeManifest(newImpls, newModules);
    }

    // ------------------------------------------------------------------
    // 1. Deploy new impls, upgrade the proxies that were re-gated
    // ------------------------------------------------------------------

    // Index map for the newImpls array threaded through deploy -> upgrade -> manifest.
    uint256 private constant I_DATA_PROVIDER = 0;
    uint256 private constant I_CASH_MODULE_CORE = 1;
    uint256 private constant I_CASH_MODULE_SETTERS = 2;
    uint256 private constant I_DEBT_MANAGER_CORE = 3;
    uint256 private constant I_DEBT_MANAGER_ADMIN = 4;
    uint256 private constant I_PRICE_PROVIDER = 5;
    uint256 private constant I_ACROSS = 6;
    uint256 private constant I_ENSO = 7;
    uint256 private constant I_STOCK_WITHDRAW = 8;
    uint256 private constant I_LEND_GATEWAY = 9;
    uint256 private constant I_TOP_UP_DEST = 10;
    uint256 private constant I_SETTLEMENT_RAIN = 11;
    uint256 private constant I_SETTLEMENT_REAP = 12;
    uint256 private constant I_SETTLEMENT_PIX = 13;
    uint256 private constant I_SETTLEMENT_CARD_ORDER = 14;
    uint256 private constant I_CASHBACK_DISPATCHER = 15;
    uint256 private constant N_IMPLS = 16;

    function _deployAndUpgradeProxies() internal returns (address[] memory newImpls) {
        newImpls = _deployNewImpls();
        _upgradeAllProxies(newImpls);
    }

    function _deployNewImpls() internal returns (address[] memory impls) {
        console2.log("=== Deploying re-gated implementations ===");
        impls = new address[](N_IMPLS);
        impls[I_DATA_PROVIDER] = _deploy("EtherFiDataProviderImpl", abi.encodePacked(type(EtherFiDataProvider).creationCode));
        impls[I_CASH_MODULE_CORE] = _deploy("CashModuleCoreImpl", abi.encodePacked(type(CashModuleCore).creationCode, abi.encode(DATA_PROVIDER)));
        impls[I_CASH_MODULE_SETTERS] = _deploy("CashModuleSettersImpl", abi.encodePacked(type(CashModuleSetters).creationCode, abi.encode(DATA_PROVIDER)));
        impls[I_DEBT_MANAGER_CORE] = _deploy("DebtManagerCoreImpl", abi.encodePacked(type(DebtManagerCore).creationCode, abi.encode(DATA_PROVIDER)));
        impls[I_DEBT_MANAGER_ADMIN] = _deploy("DebtManagerAdminImpl", abi.encodePacked(type(DebtManagerAdmin).creationCode, abi.encode(DATA_PROVIDER)));
        impls[I_PRICE_PROVIDER] = _deploy("PriceProviderV2Impl", abi.encodePacked(type(PriceProviderV2).creationCode));
        impls[I_ACROSS] = _deploy("AcrossSwapModuleImpl", abi.encodePacked(type(AcrossSwapModule).creationCode, abi.encode(DATA_PROVIDER)));
        impls[I_ENSO] = _deploy("EnsoSwapModuleImpl", abi.encodePacked(type(EnsoSwapModule).creationCode, abi.encode(DATA_PROVIDER)));
        impls[I_STOCK_WITHDRAW] = _deploy("StockWithdrawModuleImpl", abi.encodePacked(type(StockWithdrawModule).creationCode, abi.encode(DATA_PROVIDER)));
        impls[I_LEND_GATEWAY] = _deploy("LendGatewayImpl", abi.encodePacked(type(LendGateway).creationCode, abi.encode(DATA_PROVIDER, address(LendGateway(payable(LEND_GATEWAY)).spoke()))));
        impls[I_TOP_UP_DEST] = _deploy("TopUpDestImpl", abi.encodePacked(type(TopUpDest).creationCode, abi.encode(DATA_PROVIDER, address(TopUpDest(payable(TOP_UP_DEST)).weth()))));
        impls[I_SETTLEMENT_RAIN] = _deploy("SettlementDispatcherRainImpl", abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.Rain, DATA_PROVIDER)));
        impls[I_SETTLEMENT_REAP] = _deploy("SettlementDispatcherReapImpl", abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.Reap, DATA_PROVIDER)));
        impls[I_SETTLEMENT_PIX] = _deploy("SettlementDispatcherPixImpl", abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.PIX, DATA_PROVIDER)));
        impls[I_SETTLEMENT_CARD_ORDER] = _deploy("SettlementDispatcherCardOrderImpl", abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.CardOrder, DATA_PROVIDER)));
        impls[I_CASHBACK_DISPATCHER] = _deploy("CashbackDispatcherImpl", abi.encodePacked(type(CashbackDispatcher).creationCode, abi.encode(DATA_PROVIDER)));
    }

    function _upgradeAllProxies(address[] memory impls) internal {
        console2.log("=== Upgrading proxies ===");
        _upgrade("EtherFiDataProvider", DATA_PROVIDER, impls[I_DATA_PROVIDER]);
        _upgrade("DebtManager (core)", DEBT_MANAGER, impls[I_DEBT_MANAGER_CORE]);
        _setDebtManagerAdmin(impls[I_DEBT_MANAGER_ADMIN]);
        _upgrade("CashModule (core)", CASH_MODULE, impls[I_CASH_MODULE_CORE]);
        _setCashModuleSetters(impls[I_CASH_MODULE_SETTERS]);
        _upgrade("PriceProvider", PRICE_PROVIDER, impls[I_PRICE_PROVIDER]);
        _upgrade("AcrossSwapModule", ACROSS_SWAP_MODULE, impls[I_ACROSS]);
        _upgrade("EnsoSwapModule", ENSO_SWAP_MODULE, impls[I_ENSO]);
        _upgrade("StockWithdrawModule", STOCK_WITHDRAW_MODULE, impls[I_STOCK_WITHDRAW]);
        _upgrade("LendGateway", LEND_GATEWAY, impls[I_LEND_GATEWAY]);
        _upgrade("TopUpDest", TOP_UP_DEST, impls[I_TOP_UP_DEST]);
        _upgrade("SettlementDispatcherRain", SETTLEMENT_RAIN, impls[I_SETTLEMENT_RAIN]);
        _upgrade("SettlementDispatcherReap", SETTLEMENT_REAP, impls[I_SETTLEMENT_REAP]);
        _upgrade("SettlementDispatcherPix", SETTLEMENT_PIX, impls[I_SETTLEMENT_PIX]);
        _upgrade("SettlementDispatcherCardOrder", SETTLEMENT_CARD_ORDER, impls[I_SETTLEMENT_CARD_ORDER]);
        _upgrade("CashbackDispatcher", CASHBACK_DISPATCHER, impls[I_CASHBACK_DISPATCHER]);
    }

    function _upgrade(string memory label, address proxy, address newImpl) internal {
        address current = _currentImpl(proxy);
        if (current == newImpl) {
            console2.log(string.concat("  [SKIP] ", label, " already on target impl"));
            return;
        }
        UUPSUpgradeable(proxy).upgradeToAndCall(newImpl, "");
        require(_currentImpl(proxy) == newImpl, string.concat(label, ": upgrade did not stick"));
        console2.log(string.concat("  [OK] ", label, " upgraded"));
    }

    function _currentImpl(address proxy) internal view returns (address) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        return address(uint160(uint256(vm.load(proxy, slot))));
    }

    function _setCashModuleSetters(address newSetters) internal {
        if (CashModuleCore(CASH_MODULE).getCashModuleSetters() == newSetters) {
            console2.log("  [SKIP] CashModule setters pointer already set");
            return;
        }
        ICashModule(CASH_MODULE).setCashModuleSettersAddress(newSetters);
        require(CashModuleCore(CASH_MODULE).getCashModuleSetters() == newSetters, "setCashModuleSettersAddress did not stick");
        console2.log("  [OK] CashModule setters pointer updated");
    }

    function _setDebtManagerAdmin(address newAdmin) internal {
        if (IDebtManager(DEBT_MANAGER).getDebtManagerAdmin() == newAdmin) {
            console2.log("  [SKIP] DebtManager admin pointer already set");
            return;
        }
        IDebtManager(DEBT_MANAGER).setAdminImpl(newAdmin);
        require(IDebtManager(DEBT_MANAGER).getDebtManagerAdmin() == newAdmin, "setAdminImpl did not stick");
        console2.log("  [OK] DebtManager admin pointer updated");
    }

    // ------------------------------------------------------------------
    // 2. Redeploy the five immutable modules, config copied from the old ones
    // ------------------------------------------------------------------

    function _redeployImmutableModules() internal returns (address[] memory newModules) {
        console2.log("=== Redeploying immutable modules (config copied from the old ones) ===");

        newModules = new address[](5);
        newModules[0] = _redeployLiquidModule();
        newModules[1] = _redeployLiquidModuleReferrer();
        newModules[2] = _redeployStargateModule();
        newModules[3] = _redeployBeHYPEStakeModule();
        newModules[4] = _redeployMidasModule();
    }

    function _redeployLiquidModule() internal returns (address module) {
        address[] memory candidates = new address[](4);
        candidates[0] = LIQUID_ETH;
        candidates[1] = LIQUID_BTC;
        candidates[2] = LIQUID_USD;
        candidates[3] = EBTC;

        (address[] memory assets, address[] memory tellers) = _liquidAssetsAndTellers(OLD_LIQUID_MODULE, candidates);

        module = _deploy("EtherFiLiquidModule", abi.encodePacked(type(EtherFiLiquidModule).creationCode, abi.encode(assets, tellers, DATA_PROVIDER, WETH)));
        console2.log("  EtherFiLiquidModule:", module);

        for (uint256 i = 0; i < assets.length; ++i) {
            address queue = EtherFiLiquidModule(OLD_LIQUID_MODULE).getLiquidAssetWithdrawQueue(assets[i]);
            if (queue == address(0)) continue;
            if (EtherFiLiquidModule(module).getLiquidAssetWithdrawQueue(assets[i]) == queue) continue;
            EtherFiLiquidModule(module).setLiquidAssetWithdrawQueue(assets[i], queue);
        }
    }

    function _redeployLiquidModuleReferrer() internal returns (address module) {
        address[] memory candidates = new address[](1);
        candidates[0] = SETHFI;

        (address[] memory assets, address[] memory tellers) = _liquidAssetsAndTellers(OLD_LIQUID_MODULE_REFERRER, candidates);

        module = _deploy("EtherFiLiquidModuleWithReferrer", abi.encodePacked(type(EtherFiLiquidModuleWithReferrer).creationCode, abi.encode(assets, tellers, DATA_PROVIDER, WETH)));
        console2.log("  EtherFiLiquidModuleWithReferrer:", module);

        for (uint256 i = 0; i < assets.length; ++i) {
            address queue = EtherFiLiquidModule(OLD_LIQUID_MODULE_REFERRER).getLiquidAssetWithdrawQueue(assets[i]);
            if (queue == address(0)) continue;
            if (EtherFiLiquidModule(module).getLiquidAssetWithdrawQueue(assets[i]) == queue) continue;
            EtherFiLiquidModule(module).setLiquidAssetWithdrawQueue(assets[i], queue);
        }
    }

    function _liquidAssetsAndTellers(address oldModule, address[] memory candidates) internal view returns (address[] memory assets, address[] memory tellers) {
        address[] memory a = new address[](candidates.length);
        address[] memory t = new address[](candidates.length);
        uint256 n;
        for (uint256 i = 0; i < candidates.length; ++i) {
            address teller = address(EtherFiLiquidModule(oldModule).liquidAssetToTeller(candidates[i]));
            if (teller == address(0)) continue;
            a[n] = candidates[i];
            t[n] = teller;
            ++n;
        }
        assets = new address[](n);
        tellers = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            assets[i] = a[i];
            tellers[i] = t[i];
        }
    }

    function _redeployStargateModule() internal returns (address module) {
        address[] memory candidates = new address[](2);
        candidates[0] = STARGATE_USDC;
        candidates[1] = STARGATE_WEETH;

        address[] memory a = new address[](candidates.length);
        StargateModule.AssetConfig[] memory c = new StargateModule.AssetConfig[](candidates.length);
        uint256 n;
        for (uint256 i = 0; i < candidates.length; ++i) {
            StargateModule.AssetConfig memory cfg = StargateModule(payable(OLD_STARGATE_MODULE)).getAssetConfig(candidates[i]);
            if (cfg.pool == address(0)) continue;
            a[n] = candidates[i];
            c[n] = cfg;
            ++n;
        }
        address[] memory assets = new address[](n);
        StargateModule.AssetConfig[] memory configs = new StargateModule.AssetConfig[](n);
        for (uint256 i = 0; i < n; ++i) {
            assets[i] = a[i];
            configs[i] = c[i];
        }

        module = _deploy("StargateModule", abi.encodePacked(type(StargateModule).creationCode, abi.encode(assets, configs, DATA_PROVIDER)));
        console2.log("  StargateModule:", module);
    }

    function _redeployBeHYPEStakeModule() internal returns (address module) {
        address staker = address(BeHYPEStakeModule(payable(OLD_BEHYPE_STAKE_MODULE)).staker());
        address whype = BeHYPEStakeModule(payable(OLD_BEHYPE_STAKE_MODULE)).whype();
        address beHYPE = BeHYPEStakeModule(payable(OLD_BEHYPE_STAKE_MODULE)).beHYPE();
        uint32 refundGasLimit = BeHYPEStakeModule(payable(OLD_BEHYPE_STAKE_MODULE)).getRefundGasLimit();

        module = _deploy("BeHYPEStakeModule", abi.encodePacked(type(BeHYPEStakeModule).creationCode, abi.encode(DATA_PROVIDER, staker, whype, beHYPE, refundGasLimit)));
        console2.log("  BeHYPEStakeModule:", module);
    }

    function _redeployMidasModule() internal returns (address module) {
        address[] memory candidates = new address[](1);
        candidates[0] = MIDAS_TOKEN;

        address[] memory tok = new address[](candidates.length);
        address[] memory dep = new address[](candidates.length);
        address[] memory red = new address[](candidates.length);
        uint256 n;
        for (uint256 i = 0; i < candidates.length; ++i) {
            (address depositVault, address redemptionVault) = MidasModule(OLD_MIDAS_MODULE).vaults(candidates[i]);
            if (depositVault == address(0)) continue;
            tok[n] = candidates[i];
            dep[n] = depositVault;
            red[n] = redemptionVault;
            ++n;
        }
        address[] memory midasTokens = new address[](n);
        address[] memory depositVaults = new address[](n);
        address[] memory redemptionVaults = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            midasTokens[i] = tok[i];
            depositVaults[i] = dep[i];
            redemptionVaults[i] = red[i];
        }

        module = _deploy("MidasModule", abi.encodePacked(type(MidasModule).creationCode, abi.encode(DATA_PROVIDER, midasTokens, depositVaults, redemptionVaults)));
        console2.log("  MidasModule:", module);
    }

    // ------------------------------------------------------------------
    // 3. Wire the new modules in alongside the old ones
    // ------------------------------------------------------------------

    function _wireNewModules(address[] memory newModules) internal {
        console2.log("=== Wiring new modules alongside the old ones ===");
        EtherFiDataProvider provider = EtherFiDataProvider(DATA_PROVIDER);

        // (a) default modules - additive only, the old five stay default.
        address[] memory toDefault = new address[](newModules.length);
        bool[] memory flags = new bool[](newModules.length);
        uint256 nDefault;
        for (uint256 i = 0; i < newModules.length; ++i) {
            if (provider.isDefaultModule(newModules[i])) continue;
            toDefault[nDefault] = newModules[i];
            flags[nDefault] = true;
            ++nDefault;
        }
        if (nDefault > 0) {
            address[] memory m = new address[](nDefault);
            bool[] memory f = new bool[](nDefault);
            for (uint256 i = 0; i < nDefault; ++i) {
                m[i] = toDefault[i];
                f[i] = flags[i];
            }
            provider.configureDefaultModules(m, f);
            console2.log("  [OK] new modules marked default");
        } else {
            console2.log("  [SKIP] all new modules already default");
        }

        // (b) LendGateway drivers - every new module except StargateModule, mirroring the old set.
        LendGateway gateway = LendGateway(payable(LEND_GATEWAY));
        for (uint256 i = 0; i < newModules.length; ++i) {
            if (newModules[i] == newModules[2]) continue; // StargateModule stays a non-driver, like the old one.
            if (gateway.isDriver(newModules[i])) continue;
            gateway.setDriver(newModules[i], true);
        }
        console2.log("  [OK] LendGateway drivers set (Stargate excluded, matching the old module)");

        // (c) withdraw-requesters - mirror whichever old modules currently hold the status.
        address[] memory oldModules = new address[](5);
        oldModules[0] = OLD_LIQUID_MODULE;
        oldModules[1] = OLD_LIQUID_MODULE_REFERRER;
        oldModules[2] = OLD_STARGATE_MODULE;
        oldModules[3] = OLD_BEHYPE_STAKE_MODULE;
        oldModules[4] = OLD_MIDAS_MODULE;

        address[] memory withdrawRequestersToAdd = new address[](newModules.length);
        uint256 nRequesters;
        for (uint256 i = 0; i < newModules.length; ++i) {
            if (!_isWithdrawRequester(oldModules[i])) continue;
            if (_isWithdrawRequester(newModules[i])) continue;
            withdrawRequestersToAdd[nRequesters] = newModules[i];
            ++nRequesters;
        }
        if (nRequesters > 0) {
            address[] memory m = new address[](nRequesters);
            bool[] memory f = new bool[](nRequesters);
            for (uint256 i = 0; i < nRequesters; ++i) {
                m[i] = withdrawRequestersToAdd[i];
                f[i] = true;
            }
            ICashModule(CASH_MODULE).configureModulesCanRequestWithdraw(m, f);
            console2.log("  [OK] new modules granted withdraw-requester status mirroring the old ones");
        } else {
            console2.log("  [SKIP] no new withdraw-requesters needed");
        }
    }

    function _isWithdrawRequester(address module) internal view returns (bool) {
        address[] memory requesters = ICashModule(CASH_MODULE).getWhitelistedModulesCanRequestWithdraw();
        for (uint256 i = 0; i < requesters.length; ++i) {
            if (requesters[i] == module) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _deploy(string memory name, bytes memory creationCode) internal returns (address deployed) {
        bytes32 salt = getSalt(string.concat(SALT_PREFIX, name));
        deployed = DEPLOYER.getDeterministicAddress(salt);
        if (deployed.code.length > 0) {
            console2.log(string.concat("  [SKIP] ", name, " already deployed at"), deployed);
            return deployed;
        }
        address result = DEPLOYER.deploy(salt, creationCode);
        require(result == deployed, string.concat(name, ": deployed off the predicted address"));
        console2.log(string.concat("  [OK] deployed ", name, " at"), deployed);
    }

    function _verifyGovernanceUnchanged(RoleRegistry registry) internal view {
        require(registry.owner() == DEV_ADMIN, "CRITICAL: OP RoleRegistry owner changed!");
        require(registry.hasRole(registry.ADMIN_ROLE(), DEV_ADMIN), "CRITICAL: DEV_ADMIN lost ADMIN_ROLE!");
        require(registry.hasRole(registry.ADMIN_TIMELOCK_ROLE(), DEV_ADMIN), "CRITICAL: DEV_ADMIN lost ADMIN_TIMELOCK_ROLE!");
        console2.log("  [OK] OP RoleRegistry governance unchanged");
    }

    function _writeManifest(address[] memory newImpls, address[] memory newModules) internal {
        string memory path = string.concat(vm.projectRoot(), MANIFEST_PATH);
        string memory obj = "role-regating-op-dev";

        string memory json = vm.serializeAddress(obj, "RoleRegistryImpl", _currentImpl(ROLE_REGISTRY));
        json = vm.serializeAddress(obj, "EtherFiDataProviderImpl", newImpls[I_DATA_PROVIDER]);
        json = vm.serializeAddress(obj, "CashModuleCoreImpl", newImpls[I_CASH_MODULE_CORE]);
        json = vm.serializeAddress(obj, "CashModuleSettersImpl", newImpls[I_CASH_MODULE_SETTERS]);
        json = vm.serializeAddress(obj, "DebtManagerCoreImpl", newImpls[I_DEBT_MANAGER_CORE]);
        json = vm.serializeAddress(obj, "DebtManagerAdminImpl", newImpls[I_DEBT_MANAGER_ADMIN]);
        json = vm.serializeAddress(obj, "PriceProviderV2Impl", newImpls[I_PRICE_PROVIDER]);
        json = vm.serializeAddress(obj, "AcrossSwapModuleImpl", newImpls[I_ACROSS]);
        json = vm.serializeAddress(obj, "EnsoSwapModuleImpl", newImpls[I_ENSO]);
        json = vm.serializeAddress(obj, "StockWithdrawModuleImpl", newImpls[I_STOCK_WITHDRAW]);
        json = vm.serializeAddress(obj, "LendGatewayImpl", newImpls[I_LEND_GATEWAY]);
        json = vm.serializeAddress(obj, "TopUpDestImpl", newImpls[I_TOP_UP_DEST]);
        json = vm.serializeAddress(obj, "SettlementDispatcherRainImpl", newImpls[I_SETTLEMENT_RAIN]);
        json = vm.serializeAddress(obj, "SettlementDispatcherReapImpl", newImpls[I_SETTLEMENT_REAP]);
        json = vm.serializeAddress(obj, "SettlementDispatcherPixImpl", newImpls[I_SETTLEMENT_PIX]);
        json = vm.serializeAddress(obj, "SettlementDispatcherCardOrderImpl", newImpls[I_SETTLEMENT_CARD_ORDER]);
        json = vm.serializeAddress(obj, "CashbackDispatcherImpl", newImpls[I_CASHBACK_DISPATCHER]);

        json = vm.serializeAddress(obj, "EtherFiLiquidModule", newModules[0]);
        json = vm.serializeAddress(obj, "old_EtherFiLiquidModule", OLD_LIQUID_MODULE);
        json = vm.serializeAddress(obj, "EtherFiLiquidModuleWithReferrer", newModules[1]);
        json = vm.serializeAddress(obj, "old_EtherFiLiquidModuleWithReferrer", OLD_LIQUID_MODULE_REFERRER);
        json = vm.serializeAddress(obj, "StargateModule", newModules[2]);
        json = vm.serializeAddress(obj, "old_StargateModule", OLD_STARGATE_MODULE);
        json = vm.serializeAddress(obj, "BeHYPEStakeModule", newModules[3]);
        json = vm.serializeAddress(obj, "old_BeHYPEStakeModule", OLD_BEHYPE_STAKE_MODULE);
        json = vm.serializeAddress(obj, "MidasModule", newModules[4]);
        json = vm.serializeAddress(obj, "old_MidasModule", OLD_MIDAS_MODULE);

        vm.writeJson(json, path);
        console2.log("Wrote", path);
    }

    function _startBroadcast() private {
        uint256 privateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (privateKey == 0) {
            vm.startBroadcast(DEV_ADMIN);
        } else {
            require(vm.addr(privateKey) == DEV_ADMIN, "PRIVATE_KEY is not the dev admin");
            vm.startBroadcast(privateKey);
        }
    }
}
