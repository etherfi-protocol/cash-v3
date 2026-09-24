// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test, console } from "forge-std/Test.sol";

import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";
import { ChainConfig, Utils } from "../utils/Utils.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { DebtManagerAdmin } from "../../src/debt-manager/DebtManagerAdmin.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { CashLens } from "../../src/modules/cash/CashLens.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { EtherFiLiquidModuleWithReferrer } from "../../src/modules/etherfi/EtherFiLiquidModuleWithReferrer.sol";
import { EtherFiStakeModule } from "../../src/modules/etherfi/EtherFiStakeModule.sol";
import { FraxModule } from "../../src/modules/frax/FraxModule.sol";
import { OpenOceanSwapModule } from "../../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { StargateModule } from "../../src/modules/stargate/StargateModule.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { EtherFiSafe } from "../../src/safe/EtherFiSafe.sol";
import { EtherFiSafeFactory } from "../../src/safe/EtherFiSafeFactory.sol";

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
    address cashModuleProxy;
    address cashLensProxy;
    address cashEventEmitterProxy;
    address debtManagerProxy;
    address priceProviderProxy;
    address hookProxy;
    address safeFactoryProxy;
    address openOceanSwapModule;
    address etherFiLiquidModule;
    address etherFiLiquidModuleWithReferrer;
    address stargateModule;
    address fraxModule;
    address etherFiStakeModule;

    // Resolved implementation addresses (read from EIP-1967 slot)
    address dataProviderImpl;
    address cashModuleCoreImpl;
    address cashLensImpl;
    address cashEventEmitterImpl;
    address debtManagerCoreImpl;
    address priceProviderImpl;
    address hookImpl;
    address safeFactoryImpl;
    address safeImpl; // read from factory

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
        cashModuleProxy = stdJson.readAddress(deployments, ".addresses.CashModule");
        cashLensProxy = stdJson.readAddress(deployments, ".addresses.CashLens");
        cashEventEmitterProxy = stdJson.readAddress(deployments, ".addresses.CashEventEmitter");
        debtManagerProxy = stdJson.readAddress(deployments, ".addresses.DebtManager");
        priceProviderProxy = stdJson.readAddress(deployments, ".addresses.PriceProvider");
        hookProxy = stdJson.readAddress(deployments, ".addresses.EtherFiHook");
        safeFactoryProxy = stdJson.readAddress(deployments, ".addresses.EtherFiSafeFactory");
        openOceanSwapModule = stdJson.readAddress(deployments, ".addresses.OpenOceanSwapModule");
        etherFiLiquidModule = stdJson.readAddress(deployments, ".addresses.EtherFiLiquidModule");
        etherFiLiquidModuleWithReferrer = stdJson.readAddress(deployments, ".addresses.EtherFiLiquidModuleWithReferrer");
        stargateModule = stdJson.readAddress(deployments, ".addresses.StargateModule");
        fraxModule = stdJson.readAddress(deployments, ".addresses.FraxModule");
        etherFiStakeModule = stdJson.readAddress(deployments, ".addresses.EtherFiStakeModule");

        // Read implementation addresses from EIP-1967 slots
        dataProviderImpl = _getImpl(dataProviderProxy);
        cashModuleCoreImpl = _getImpl(cashModuleProxy);
        cashLensImpl = _getImpl(cashLensProxy);
        cashEventEmitterImpl = _getImpl(cashEventEmitterProxy);
        debtManagerCoreImpl = _getImpl(debtManagerProxy);
        priceProviderImpl = _getImpl(priceProviderProxy);
        hookImpl = _getImpl(hookProxy);
        safeFactoryImpl = _getImpl(safeFactoryProxy);

        // Read safe impl from beacon
        safeImpl = UpgradeableBeacon(EtherFiSafeFactory(safeFactoryProxy).beacon()).implementation();

        // Read CashModuleSetters impl from CashModuleCore
        cashModuleSettersImpl = CashModuleCore(cashModuleProxy).getCashModuleSetters();

        // Read DebtManagerAdmin impl from DebtManagerCore
        debtManagerAdminImpl = DebtManagerCore(debtManagerProxy).getDebtManagerAdmin();
    }

    // ---- Core infrastructure ----

    // function test_verifyBytecode_EtherFiDataProvider() public {
    //     address local = address(new EtherFiDataProvider());
    //     _verify("EtherFiDataProvider", dataProviderImpl, local);
    // }

    function test_verifyBytecode_EtherFiSafe() public {
        address local = address(new EtherFiSafe(dataProviderProxy));
        _verify("EtherFiSafe", safeImpl, local);
    }

    function test_verifyBytecode_EtherFiSafeFactory() public {
        // The placeholder-upgrade reinitialize hook was removed (the OP prod bootstrap already ran),
        // so the factory bytecode no longer matches the deployed implementation. Re-enable after the
        // next factory deployment.
        vm.skip(true);
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
        address local = address(new PriceProviderV2());
        _verify("PriceProvider", priceProviderImpl, local);
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
