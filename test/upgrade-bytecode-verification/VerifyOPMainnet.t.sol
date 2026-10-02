// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test, console } from "forge-std/Test.sol";

import { ChainConfig } from "../utils/Utils.sol";
import { TradingStackBytecode } from "./TradingStackBytecode.sol";

import { AcrossSwapModule } from "../../src/across/AcrossSwapModule.sol";
import { CashbackDistributor } from "../../src/cashback-distributor/CashbackDistributor.sol";
import { EnsoSwapModule } from "../../src/enso/EnsoSwapModule.sol";
import { AaveV4Lens } from "../../src/lens/AaveV4Lens.sol";
import { SafeErc1271Lib } from "../../src/libraries/SafeErc1271Lib.sol";
import { CashLiquidationHelper } from "../../src/modules/cash/CashLiquidationHelper.sol";
import { CCTPModule } from "../../src/modules/cctp/CCTPModule.sol";
import { MidasLiquifierModule } from "../../src/modules/etherfi/MidasLiquifierModule.sol";
import { BeHYPEStakeModule } from "../../src/modules/hype/BeHYPEStakeModule.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { MidasModule } from "../../src/modules/midas/MidasModule.sol";
import { AssetRecoveryModule } from "../../src/modules/recovery/AssetRecoveryModule.sol";
import { SafeAssetRecoveryModule } from "../../src/modules/recovery/SafeAssetRecoveryModule.sol";
import { StockWithdrawModule } from "../../src/stock-withdraw/StockWithdrawModule.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { CashbackDispatcher } from "../../src/cashback-dispatcher/CashbackDispatcher.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { DebtManagerAdmin } from "../../src/debt-manager/DebtManagerAdmin.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";
import { BinSponsor } from "../../src/interfaces/ICashModule.sol";
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { CashLens } from "../../src/modules/cash/CashLens.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { EtherFiLiquidModuleWithReferrer } from "../../src/modules/etherfi/EtherFiLiquidModuleWithReferrer.sol";
import { EtherFiStakeModule } from "../../src/modules/etherfi/EtherFiStakeModule.sol";
import { LiquidUSDLiquifierOPModule } from "../../src/modules/etherfi/LiquidUSDLiquifierOP.sol";
import { FraxModule } from "../../src/modules/frax/FraxModule.sol";
import { OpenOceanSwapModule } from "../../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { StargateModule } from "../../src/modules/stargate/StargateModule.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiSafe } from "../../src/safe/EtherFiSafe.sol";
import { EtherFiSafeFactory } from "../../src/safe/EtherFiSafeFactory.sol";
import { SettlementDispatcherV2 } from "../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";

/// @title OP Mainnet Bytecode Verification
/// @notice Verifies that every deployed contract on OP mainnet matches the bytecode from this repo.
///         Reads implementation addresses directly from proxy storage slots on-chain.
///
/// Usage:
///   TEST_CHAIN=10 forge test --match-contract VerifyOPMainnetBytecode -vv
contract VerifyOPMainnetBytecode is TradingStackBytecode {
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
    string deployments;
    string fixtures;
    string record;

    function setUp() public {
        string memory rpc = _tryEnv("OPTIMISM_RPC", "https://mainnet.optimism.io");
        vm.createSelectFork(rpc);
        _load();
    }

    function _load() internal {
        cc = getChainConfig(vm.toString(block.chainid));
        _loadTrading();

        deployments = readDeploymentFile();
        fixtures = vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet/fixtures/fixtures.json"));
        record = vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet/10/role-gating-batch3.json"));

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
        address local = address(new PriceProviderV2());
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

    // ---- Swap, lend and withdraw proxies ----

    function test_verifyBytecode_AcrossSwapModule() public {
        address local = address(new AcrossSwapModule(dataProviderProxy));
        _verify("AcrossSwapModule", _getImpl(_cash("AcrossSwapModule")), local);
    }

    function test_verifyBytecode_EnsoSwapModule() public {
        address local = address(new EnsoSwapModule(dataProviderProxy));
        _verify("EnsoSwapModule", _getImpl(_cash("EnsoSwapModule")), local);
    }

    function test_verifyBytecode_LendGateway() public {
        address gateway = _cash("LendGateway");
        address local = address(new LendGateway(dataProviderProxy, address(LendGateway(gateway).spoke())));
        _verify("LendGateway", _getImpl(gateway), local);
    }

    function test_verifyBytecode_StockWithdrawModule() public {
        address local = address(new StockWithdrawModule(dataProviderProxy));
        _verify("StockWithdrawModule", _getImpl(_cash("StockWithdrawModule")), local);
    }

    // ---- Immutable modules rebuilt from the config of the module each one replaced ----

    function test_verifyBytecode_BeHYPEStakeModule() public {
        BeHYPEStakeModule old = BeHYPEStakeModule(stdJson.readAddress(record, ".old_beHypeStakeModule"));
        address local = address(new BeHYPEStakeModule(dataProviderProxy, address(old.staker()), old.whype(), old.beHYPE(), old.getRefundGasLimit()));
        _verify("BeHYPEStakeModule", _cash("BeHYPEStakeModule"), local);
    }

    function test_verifyBytecode_MidasModule() public {
        MidasModule old = MidasModule(stdJson.readAddress(record, ".old_midasModule"));
        string[3] memory names = ["liquidReserve", "liquidEUR", "liquidRWA"];
        uint256 count;
        for (uint256 i = 0; i < names.length; ++i) {
            (address deposit,) = old.vaults(_fixture(names[i]));
            if (deposit != address(0)) ++count;
        }
        require(count > 0, "old Midas module has no configured vaults");
        address[] memory tokens = new address[](count);
        address[] memory deposits = new address[](count);
        address[] memory redemptions = new address[](count);
        uint256 j;
        for (uint256 i = 0; i < names.length; ++i) {
            address token = _fixture(names[i]);
            (address deposit, address redemption) = old.vaults(token);
            if (deposit == address(0)) continue;
            tokens[j] = token;
            deposits[j] = deposit;
            redemptions[j] = redemption;
            ++j;
        }
        address local = address(new MidasModule(dataProviderProxy, tokens, deposits, redemptions));
        _verify("MidasModule", _cash("MidasModule"), local);
    }

    // ---- Other cash contracts ----

    function test_verifyBytecode_CCTPModule() public {
        CCTPModule live = CCTPModule(_cash("CCTPModule"));
        address[] memory assets = new address[](1);
        assets[0] = cc.usdc;
        CCTPModule.AssetConfig[] memory configs = new CCTPModule.AssetConfig[](1);
        configs[0] = live.getAssetConfig(cc.usdc);
        address local = address(new CCTPModule(assets, configs, dataProviderProxy));
        _verify("CCTPModule", address(live), local);
    }

    function test_verifyBytecode_AssetRecoveryModule() public {
        AssetRecoveryModule live = AssetRecoveryModule(_cash("AssetRecoveryModule"));
        address local = address(new AssetRecoveryModule(dataProviderProxy, address(live.endpoint()), live.owner()));
        _verify("AssetRecoveryModule", address(live), local);
    }

    function test_verifyBytecode_SafeAssetRecoveryModule() public {
        address local = address(new SafeAssetRecoveryModule(dataProviderProxy));
        _verify("SafeAssetRecoveryModule", _cash("SafeAssetRecoveryModule"), local);
    }

    function test_verifyBytecode_MidasLiquifierModule() public {
        address local = address(new MidasLiquifierModule(debtManagerProxy, dataProviderProxy));
        _verify("MidasLiquifierModule", _getImpl(_cash("MidasLiquifierModule")), local);
    }

    function test_verifyBytecode_CashbackDistributor() public {
        CashbackDistributor live = CashbackDistributor(_cash("CashbackDistributor"));
        address local = address(new CashbackDistributor(live.ethfi(), live.sEthfi(), dataProviderProxy));
        _verify("CashbackDistributor", _getImpl(address(live)), local);
    }

    function test_verifyBytecode_CashLiquidationHelper() public {
        address local = address(new CashLiquidationHelper(debtManagerProxy, _fixture("eUSD")));
        _verify("CashLiquidationHelper", _cash("CashLiquidationHelper"), local);
    }

    function test_verifyBytecode_AaveV4Lens() public {
        address local = address(new AaveV4Lens());
        _verify("AaveV4Lens", _getImpl(_cash("AaveV4Lens")), local);
    }

    function test_verifyBytecode_EtherFiTimelock() public {
        address[] memory none = new address[](0);
        address local = address(new EtherFiTimelock(0, none, none, address(0)));
        _verify("EtherFiTimelock (2 day)", _cash("EtherFiTimelock"), local);
        _verify("EtherFiTimelock (8 hour)", stdJson.readAddress(vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet/10/roles.json")), ".governance.operatingTimelock.address"), local);
    }

    /// @dev A library embeds its own address as the first PUSH20 operand, so the local copy is etched at a
    ///      fresh address with that operand patched to it.
    function test_verifyBytecode_SafeErc1271Lib() public {
        bytes memory code = vm.getDeployedCode("SafeErc1271Lib.sol:SafeErc1271Lib");
        address local = makeAddr("SafeErc1271Lib");
        bytes20 self = bytes20(local);
        for (uint256 i = 0; i < 20; ++i) {
            code[1 + i] = self[i];
        }
        vm.etch(local, code);
        _verify("SafeErc1271Lib", _cash("SafeErc1271Lib"), local);
    }

    // ---- Helpers ----

    function _cash(string memory key) internal view returns (address) {
        return stdJson.readAddress(deployments, string.concat(".addresses.", key));
    }

    function _fixture(string memory name) internal view returns (address) {
        return stdJson.readAddress(fixtures, string.concat(".10.", name));
    }
}
