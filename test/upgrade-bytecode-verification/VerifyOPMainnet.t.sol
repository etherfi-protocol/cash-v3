// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";
import { Utils, ChainConfig } from "../utils/Utils.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiSafe } from "../../src/safe/EtherFiSafe.sol";
import { EtherFiSafeFactory } from "../../src/safe/EtherFiSafeFactory.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { CashLens } from "../../src/modules/cash/CashLens.sol";
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { DebtManagerAdmin } from "../../src/debt-manager/DebtManagerAdmin.sol";
import { PriceProvider } from "../../src/oracle/PriceProvider.sol";
import { CashbackDispatcher } from "../../src/cashback-dispatcher/CashbackDispatcher.sol";
import { BinSponsor } from "../../src/interfaces/ICashModule.sol";
import { SettlementDispatcherV2 } from "../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { OpenOceanSwapModule } from "../../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { EtherFiLiquidModuleWithReferrer } from "../../src/modules/etherfi/EtherFiLiquidModuleWithReferrer.sol";
import { StargateModule } from "../../src/modules/stargate/StargateModule.sol";
import { FraxModule } from "../../src/modules/frax/FraxModule.sol";
import { EtherFiStakeModule } from "../../src/modules/etherfi/EtherFiStakeModule.sol";
import { LiquidUSDLiquifierOPModule } from "../../src/modules/etherfi/LiquidUSDLiquifierOP.sol";
import { CashLiquidationHelper } from "../../src/modules/cash/CashLiquidationHelper.sol";

/// @title OP Mainnet Bytecode Verification
/// @notice Verifies that every deployed contract on OP mainnet matches the bytecode from this repo.
///         Reads implementation addresses directly from proxy storage slots on-chain.
///
/// Usage:
///   TEST_CHAIN=10 forge test --match-contract VerifyOPMainnetBytecode -vv
contract VerifyOPMainnetBytecode is ContractCodeChecker, Utils {
    bytes32 constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // Deployed proxy addresses from deployments.json
    address dataProviderProxy;
    address roleRegistryProxy;
    address cashModuleProxy;
    address cashLensProxy;
    address cashEventEmitterProxy;
    address cashbackDispatcherProxy;
    address debtManagerProxy;
    address priceProviderProxy;
    address hookProxy;
    address safeFactoryProxy;
    address settlementReapProxy;
    address settlementRainProxy;
    address settlementPixProxy;
    address settlementCardOrderProxy;
    address topUpDestProxy;
    address openOceanSwapModule;
    address etherFiLiquidModule;
    address etherFiLiquidModuleWithReferrer;
    address stargateModule;
    address fraxModule;
    address liquidUsdLiquifierProxy;
    address etherFiStakeModule;
    address cashLiquidationHelper;

    // Resolved implementation addresses (read from EIP-1967 slot)
    address dataProviderImpl;
    address roleRegistryImpl;
    address cashModuleCoreImpl;
    address cashLensImpl;
    address cashEventEmitterImpl;
    address cashbackDispatcherImpl;
    address debtManagerCoreImpl;
    address priceProviderImpl;
    address hookImpl;
    address safeFactoryImpl;
    address safeImpl; // read from factory
    address settlementReapImpl;
    address settlementRainImpl;
    address settlementPixImpl;
    address settlementCardOrderImpl;
    address topUpDestImpl;

    // CashModule setters impl (stored in CashModuleCore storage)
    address cashModuleSettersImpl;
    // DebtManager admin impl (stored in DebtManagerCore storage)
    address debtManagerAdminImpl;

    ChainConfig cc;

    function setUp() public {
        string memory rpc = _tryEnv("OPTIMISM_RPC", "https://mainnet.optimism.io");
        vm.createSelectFork(rpc);

        cc = getChainConfig(vm.toString(block.chainid));

        string memory deployments = readDeploymentFile();

        dataProviderProxy = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        roleRegistryProxy = stdJson.readAddress(deployments, ".addresses.RoleRegistry");
        cashModuleProxy = stdJson.readAddress(deployments, ".addresses.CashModule");
        cashLensProxy = stdJson.readAddress(deployments, ".addresses.CashLens");
        cashEventEmitterProxy = stdJson.readAddress(deployments, ".addresses.CashEventEmitter");
        cashbackDispatcherProxy = stdJson.readAddress(deployments, ".addresses.CashbackDispatcher");
        debtManagerProxy = stdJson.readAddress(deployments, ".addresses.DebtManager");
        priceProviderProxy = stdJson.readAddress(deployments, ".addresses.PriceProvider");
        hookProxy = stdJson.readAddress(deployments, ".addresses.EtherFiHook");
        safeFactoryProxy = stdJson.readAddress(deployments, ".addresses.EtherFiSafeFactory");
        settlementReapProxy = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherReap");
        settlementRainProxy = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherRain");
        settlementPixProxy = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherPix");
        settlementCardOrderProxy = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherCardOrder");
        topUpDestProxy = stdJson.readAddress(deployments, ".addresses.TopUpDest");
        openOceanSwapModule = stdJson.readAddress(deployments, ".addresses.OpenOceanSwapModule");
        etherFiLiquidModule = stdJson.readAddress(deployments, ".addresses.EtherFiLiquidModule");
        etherFiLiquidModuleWithReferrer = stdJson.readAddress(deployments, ".addresses.EtherFiLiquidModuleWithReferrer");
        stargateModule = stdJson.readAddress(deployments, ".addresses.StargateModule");
        fraxModule = stdJson.readAddress(deployments, ".addresses.FraxModule");
        liquidUsdLiquifierProxy = stdJson.readAddress(deployments, ".addresses.LiquidUSDLiquifierModule");
        etherFiStakeModule = stdJson.readAddress(deployments, ".addresses.EtherFiStakeModule");
        cashLiquidationHelper = stdJson.readAddress(deployments, ".addresses.CashLiquidationHelper");

        // Read implementation addresses from EIP-1967 slots
        dataProviderImpl = _getImpl(dataProviderProxy);
        roleRegistryImpl = _getImpl(roleRegistryProxy);
        cashModuleCoreImpl = _getImpl(cashModuleProxy);
        cashLensImpl = _getImpl(cashLensProxy);
        cashEventEmitterImpl = _getImpl(cashEventEmitterProxy);
        cashbackDispatcherImpl = _getImpl(cashbackDispatcherProxy);
        debtManagerCoreImpl = _getImpl(debtManagerProxy);
        priceProviderImpl = _getImpl(priceProviderProxy);
        hookImpl = _getImpl(hookProxy);
        safeFactoryImpl = _getImpl(safeFactoryProxy);
        settlementReapImpl = _getImpl(settlementReapProxy);
        settlementRainImpl = _getImpl(settlementRainProxy);
        settlementPixImpl = _getImpl(settlementPixProxy);
        settlementCardOrderImpl = _getImpl(settlementCardOrderProxy);
        topUpDestImpl = _getImpl(topUpDestProxy);

        // Read safe impl from beacon
        safeImpl = UpgradeableBeacon(EtherFiSafeFactory(safeFactoryProxy).beacon()).implementation();

        // Read CashModuleSetters impl from CashModuleCore
        cashModuleSettersImpl = CashModuleCore(cashModuleProxy).getCashModuleSetters();

        // Read DebtManagerAdmin impl from DebtManagerCore
        debtManagerAdminImpl = DebtManagerCore(debtManagerProxy).getDebtManagerAdmin();
    }

    // ---- Core infrastructure ----

    function test_verifyBytecode_EtherFiDataProvider() public {
        address local = address(new EtherFiDataProvider());
        _verify("EtherFiDataProvider", dataProviderImpl, local);
    }

    function test_verifyBytecode_RoleRegistry() public {
        address local = address(new RoleRegistry(dataProviderProxy));
        _verify("RoleRegistry", roleRegistryImpl, local);
    }

    function test_verifyBytecode_EtherFiSafe() public {
        address local = address(new EtherFiSafe(dataProviderProxy));
        _verify("EtherFiSafe", safeImpl, local);
    }

    function test_verifyBytecode_EtherFiSafeFactory() public {
        address local = address(new EtherFiSafeFactory());
        _verify("EtherFiSafeFactory", safeFactoryImpl, local);
    }

    function test_verifyBytecode_EtherFiHook() public {
        address local = address(new EtherFiHook(dataProviderProxy));
        _verify("EtherFiHook", hookImpl, local);
    }

    // ---- Cash module ----

    function test_verifyBytecode_CashModuleCore() public {
        address local = address(new CashModuleCore(dataProviderProxy));
        _verify("CashModuleCore", cashModuleCoreImpl, local);
    }

    function test_verifyBytecode_CashModuleSetters() public {
        address local = address(new CashModuleSetters(dataProviderProxy));
        _verify("CashModuleSetters", cashModuleSettersImpl, local);
    }

    function test_verifyBytecode_CashLens() public {
        address local = address(new CashLens(cashModuleProxy, dataProviderProxy));
        _verify("CashLens", cashLensImpl, local);
    }

    function test_verifyBytecode_CashEventEmitter() public {
        address local = address(new CashEventEmitter(cashModuleProxy));
        _verify("CashEventEmitter", cashEventEmitterImpl, local);
    }

    function test_verifyBytecode_CashbackDispatcher() public {
        address local = address(new CashbackDispatcher(dataProviderProxy));
        _verify("CashbackDispatcher", cashbackDispatcherImpl, local);
    }

    // ---- Debt manager ----

    function test_verifyBytecode_DebtManagerCore() public {
        address local = address(new DebtManagerCore(dataProviderProxy));
        _verify("DebtManagerCore", debtManagerCoreImpl, local);
    }

    function test_verifyBytecode_DebtManagerAdmin() public {
        address local = address(new DebtManagerAdmin(dataProviderProxy));
        _verify("DebtManagerAdmin", debtManagerAdminImpl, local);
    }

    // ---- Oracle ----

    function test_verifyBytecode_PriceProvider() public {
        address local = address(new PriceProvider());
        _verify("PriceProvider", priceProviderImpl, local);
    }

    // ---- Settlement dispatchers ----

    function test_verifyBytecode_SettlementDispatcherReap() public {
        address local = address(new SettlementDispatcherV2(BinSponsor.Reap, dataProviderProxy));
        _verify("SettlementDispatcherReap", settlementReapImpl, local);
    }

    function test_verifyBytecode_SettlementDispatcherRain() public {
        address local = address(new SettlementDispatcherV2(BinSponsor.Rain, dataProviderProxy));
        _verify("SettlementDispatcherRain", settlementRainImpl, local);
    }

    function test_verifyBytecode_SettlementDispatcherPix() public {
        address local = address(new SettlementDispatcherV2(BinSponsor.PIX, dataProviderProxy));
        _verify("SettlementDispatcherPix", settlementPixImpl, local);
    }

    function test_verifyBytecode_SettlementDispatcherCardOrder() public {
        address local = address(new SettlementDispatcherV2(BinSponsor.CardOrder, dataProviderProxy));
        _verify("SettlementDispatcherCardOrder", settlementCardOrderImpl, local);
    }

    // ---- Top up ----

    function test_verifyBytecode_TopUpDest() public {
        address local = address(new TopUpDest(dataProviderProxy, cc.weth));
        _verify("TopUpDest", topUpDestImpl, local);
    }

    // ---- Modules (non-proxy, deployed via CREATE3) ----

    function test_verifyBytecode_OpenOceanSwapModule() public {
        address local = address(new OpenOceanSwapModule(cc.swapRouterOpenOcean, dataProviderProxy));
        _verify("OpenOceanSwapModule", openOceanSwapModule, local);
    }

    function test_verifyBytecode_EtherFiLiquidModule() public {
        address[] memory assets = new address[](4);
        assets[0] = cc.liquidEth;
        assets[1] = cc.liquidBtc;
        assets[2] = cc.liquidUsd;
        assets[3] = cc.ebtc;

        address[] memory tellers = new address[](4);
        tellers[0] = cc.liquidEthTeller;
        tellers[1] = cc.liquidBtcTeller;
        tellers[2] = cc.liquidUsdTeller;
        tellers[3] = cc.ebtcTeller;

        address local = address(new EtherFiLiquidModule(assets, tellers, dataProviderProxy, cc.weth));
        _verify("EtherFiLiquidModule", etherFiLiquidModule, local);
    }

    function test_verifyBytecode_EtherFiLiquidModuleWithReferrer() public {
        address[] memory assets = new address[](1);
        assets[0] = cc.sethfi;

        address[] memory tellers = new address[](1);
        tellers[0] = cc.sethfiTeller;

        address local = address(new EtherFiLiquidModuleWithReferrer(assets, tellers, dataProviderProxy, cc.weth));
        _verify("EtherFiLiquidModuleWithReferrer", etherFiLiquidModuleWithReferrer, local);
    }

    function test_verifyBytecode_StargateModule() public {
        address[] memory assets = new address[](2);
        assets[0] = cc.usdc;
        assets[1] = cc.weETH;

        StargateModule.AssetConfig[] memory configs = new StargateModule.AssetConfig[](2);
        configs[0] = StargateModule.AssetConfig({ isOFT: false, pool: cc.stargateUsdcPool });
        configs[1] = StargateModule.AssetConfig({ isOFT: true, pool: cc.weETH });

        address local = address(new StargateModule(assets, configs, dataProviderProxy));
        _verify("StargateModule", stargateModule, local);
    }

    function test_verifyBytecode_FraxModule() public {
        address local = address(new FraxModule(dataProviderProxy, cc.fraxusd, cc.fraxCustodian, cc.fraxRemoteHop));
        _verify("FraxModule", fraxModule, local);
    }

    function test_verifyBytecode_EtherFiStakeModule() public {
        address local = address(new EtherFiStakeModule(dataProviderProxy, cc.syncPool, cc.weth, cc.weETH));
        _verify("EtherFiStakeModule", etherFiStakeModule, local);
    }

    function test_verifyBytecode_LiquidUSDLiquifierModule() public {
        address liquifierImpl = _getImpl(liquidUsdLiquifierProxy);
        address local = address(new LiquidUSDLiquifierOPModule(debtManagerProxy, dataProviderProxy));
        _verify("LiquidUSDLiquifierModule", liquifierImpl, local);
    }

    function test_verifyBytecode_CashLiquidationHelper() public {
        // eUsd address on OP — used as constructor arg
        address eUsd = 0x939778D83b46B456224A33Fb59630B11DEC56663;
        address local = address(new CashLiquidationHelper(debtManagerProxy, eUsd));
        _verify("CashLiquidationHelper", cashLiquidationHelper, local);
    }

    // ---- Helpers ----

    function _getImpl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
    }

    function _verify(string memory name, address deployed, address local) internal {
        console.log("------", name, "------");
        console.log("  Deployed:", deployed);
        console.log("  Local:   ", local);
        verifyContractByteCodeMatch(deployed, local);
    }

    function _tryEnv(string memory key, string memory fallback_) internal view returns (string memory) {
        try vm.envString(key) returns (string memory val) {
            return bytes(val).length > 0 ? val : fallback_;
        } catch {
            return fallback_;
        }
    }
}
