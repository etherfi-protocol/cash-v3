// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { UUPSProxy } from "../src/UUPSProxy.sol";
import { TopUpDest } from "../src/top-up/TopUpDest.sol";
import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";
import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { EtherFiSafe } from "../src/safe/EtherFiSafe.sol";
import { EtherFiSafeFactory } from "../src/safe/EtherFiSafeFactory.sol";
import { EtherFiHook } from "../src/hook/EtherFiHook.sol";
import { ICashModule, BinSponsor } from "../src/interfaces/ICashModule.sol";
import { CashLens } from "../src/modules/cash/CashLens.sol";
import { Utils, ChainConfig } from "./utils/Utils.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";
import { ICashbackDispatcher } from "../src/interfaces/ICashbackDispatcher.sol";
import { IPriceProvider } from "../src/interfaces/IPriceProvider.sol";
import { CashEventEmitter } from "../src/modules/cash/CashEventEmitter.sol";
import { CashModuleSetters } from "../src/modules/cash/CashModuleSetters.sol";
import { CashModuleCore } from "../src/modules/cash/CashModuleCore.sol";
import { DebtManagerInitializer } from "../src/debt-manager/DebtManagerInitializer.sol";
import { DebtManagerCore } from "../src/debt-manager/DebtManagerCore.sol";
import { DebtManagerAdmin } from "../src/debt-manager/DebtManagerAdmin.sol";
import { CashbackDispatcher } from "../src/cashback-dispatcher/CashbackDispatcher.sol";
import { PriceProvider, IAggregatorV3 } from "../src/oracle/PriceProvider.sol";
import { SettlementDispatcherV2 } from "../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { OpenOceanSwapModule } from "../src/modules/openocean-swap/OpenOceanSwapModule.sol";

contract SetupOptimismProd is Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    bytes32 constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    bytes32 constant SHIVAM_SAFE_SALT = 0xe306d58680ed575692529312f792a0236e57e612b2a95b15f748678638424a94;

    // ── Prod salts fetched from Scroll mainnet Nick's factory calls (blocks 14206922-14762472) ──
    // Verified against on-chain txs to 0x4e59b44847b379578588920cA78FbF26c0B4956C on chain 534352

    // Implementation salts
    bytes32 constant SALT_DATA_PROVIDER_IMPL          = 0x33426737cdc104136d409e458c4cd0e95193cebd080c1e44b289dbc1e940beaa; // keccak256("EtherFiDataProviderImpl")
    bytes32 constant SALT_ROLE_REGISTRY_IMPL          = 0x1206639152b566c622b4f941f56c06cf7ccb447bc9326c21c2b41c8d27b8ac74; // keccak256("RoleRegistryImplNew")
    bytes32 constant SALT_CASH_MODULE_SETTERS_IMPL    = 0x6ef7c305c72e716956d108ae8afca5f89a4ce45a74918b403f75d104122ba8d7; // keccak256("CashModuleSettersImpl")
    bytes32 constant SALT_CASH_MODULE_CORE_IMPL       = 0xaf898630953f50a7c1d33680fc7dcf155f3c8143df1c74df7490ef62c98b8248; // keccak256("CashModuleCoreImpl")
    bytes32 constant SALT_PRICE_PROVIDER_IMPL         = 0xaedf608e44a4a1db3cd12c7bde065403b086c16247255165ea591189a625b6da; // keccak256("PriceProviderImpl")
    bytes32 constant SALT_CASHBACK_DISPATCHER_IMPL    = 0x36a2d3f253a03bb2850d51aa4b008664a9655524d7818377e25cd8362f39f802; // keccak256("CashbackDispatcherImpl")
    bytes32 constant SALT_CASH_LENS_IMPL              = 0x9c4d2e9e03347d9ae5b84e91ba528127b4ca4fe0ce227106ed59acbd554df21f; // keccak256("CashLensImpl")
    bytes32 constant SALT_HOOK_IMPL                   = 0xa5255de9d2cd171ef9d8b5da6e27d8e1282493fa55cce90af6e145b2ce8d205e; // keccak256("EtherFiHookImpl")
    bytes32 constant SALT_OPEN_OCEAN_SWAP_MODULE      = 0xf23758838c89a5bb66a4addbe794a2f1ea17017821239e8a2195e71afc8ed6e3; // keccak256("OpenOceanSwapModule")
    bytes32 constant SALT_SAFE_IMPL                   = 0xff29656f33cc018695c4dadfbd883155f1ef30d667ca50827a9b9c56a50fe803; // keccak256("EtherFiSafeImpl")
    bytes32 constant SALT_SAFE_FACTORY_IMPL           = 0x89a0cb186faf1ec3240a4a2bdefe0124bd4fac7547ef1d07ad0d1f1a9f30cafe; // keccak256("TopUpSourceFactoryImpl")
    bytes32 constant SALT_DEBT_MANAGER_CORE_IMPL      = 0xd7d8accf3671d756a509daca0abd0356c4079376519f8b6e1796646b98b5f9bc; // keccak256("DebtManagerCoreImpl")
    bytes32 constant SALT_DEBT_MANAGER_ADMIN_IMPL     = 0xc3a0307fe194705a7248e1e199e6a1d405af038d07b82c61a736ad23635bfc9b; // keccak256("DebtManagerAdminImpl")
    bytes32 constant SALT_DEBT_MANAGER_INIT_IMPL      = 0x28d742794ce3c98e369e64a2f28494c25176e89a2682486b90aea435bd2a0a6f; // keccak256("DebtManagerInitializerImpl")
    bytes32 constant SALT_SETTLEMENT_REAP_IMPL        = 0xfb940a399a0b17489a29999f8d51b555d0834c50a92d989583deaff458551388; // keccak256("SettlementDispatcherImpl")
    bytes32 constant SALT_SETTLEMENT_RAIN_IMPL        = 0x9c80c1c53d2395cf81c7efdc6edae701961f3e792cc322d517886347b74aa513; // keccak256("ProdSettlementDispatcherRainImpl")
    bytes32 constant SALT_SETTLEMENT_PIX_IMPL         = 0x2927c21ef5b1924d6de0d3ac232b846fb5c7aac14e3252f12d31512dbd00aa5b; // keccak256("SettlementDispatcherPixImpl")
    bytes32 constant SALT_SETTLEMENT_CARD_ORDER_IMPL  = 0xd251318731c981b9b9d5546666e2dbb04bbc5be2feedb7f86476706f450bda14; // keccak256("SettlementDispatcherCardOrderImpl")
    bytes32 constant SALT_CASH_EVENT_EMITTER_IMPL     = 0xf84100a4d2d9b349177716ea94e9e2cf69065d341c91a34db1522f66d64c15f0; // keccak256("CashEventEmitterImpl")
    bytes32 constant SALT_TOP_UP_DEST_IMPL            = 0x5665b1d054cb150b9bce2109812c618aabb541dedf90abe9b62e4f34ac779e84; // keccak256("TopUpDestImpl")

    // Proxy salts
    bytes32 constant SALT_DATA_PROVIDER_PROXY         = 0x307f29e4d8b2893f186304a4b3aaa5ea9e7e6cddbcd75abc4b30edb1b4c939e9; // keccak256("EtherFiDataProviderProxy")
    bytes32 constant SALT_ROLE_REGISTRY_PROXY         = 0x6cae761c5315d96c88fdeb2bdf7f689cb66abc92a4e823b7954d41f88321bd0e; // keccak256("RoleRegistryProxy")
    bytes32 constant SALT_CASH_MODULE_PROXY           = 0xd485ab52f7eb6ae6746c1b5a90eb92d689d87341677d1c4a8ee974492b708e70; // keccak256("CashModuleProxy")
    bytes32 constant SALT_PRICE_PROVIDER_PROXY        = 0xe256577e04087bb0b33fe81ae0afcee684ec2a88ff642b2d8e3facd885c4fee2; // keccak256("PriceProviderProxy")
    bytes32 constant SALT_CASHBACK_DISPATCHER_PROXY   = 0x06e587da24f92e8e0e0e16610a27705bdbee83ca07df3ace65507f0dd7f98b68; // keccak256("CashbackDispatcherProxy")
    bytes32 constant SALT_CASH_LENS_PROXY             = 0x698110fb74c5af739d2291b8eb324ef7b3727788689e7486d7073f2aa6310bde; // keccak256("CashLensProxy")
    bytes32 constant SALT_HOOK_PROXY                  = 0x80709e224fc61f855f496af607a59a6e936ec718a156096af7b5b35f47de7824; // keccak256("EtherFiHookProxy")
    bytes32 constant SALT_SAFE_FACTORY_PROXY          = 0x4039d84c2c2b96cb1babbf2ca5c0b7be213be8ad0110e70d6e2d570741ef168b; // keccak256("TopUpSourceFactoryProxy")
    bytes32 constant SALT_DEBT_MANAGER_PROXY          = 0x6610dc15616a5f676fa3e670615ee9dfb656e8902313948c7c64a3edb3ab0a1a; // keccak256("DebtManagerProxy")
    bytes32 constant SALT_SETTLEMENT_REAP_PROXY       = 0xaa1e057d426deb6be4575e8f04f28ae380f223cdb64f3a8c75f794b692125955; // keccak256("SettlementDispatcherProxy")
    bytes32 constant SALT_SETTLEMENT_RAIN_PROXY       = 0xe1a06328ed2194684d37568395abeed7fdc26c5b17c010b73ac6c0bd2eb84260; // keccak256("ProdSettlementDispatcherRainProxy")
    bytes32 constant SALT_SETTLEMENT_PIX_PROXY        = 0xb41c7d6d164a5805864d248441939a2d76f98a2294296f0f9c96f4fd28d8c738; // keccak256("SettlementDispatcherPixProxy")
    bytes32 constant SALT_SETTLEMENT_CARD_ORDER_PROXY = 0x21f29b6246a6d23c4712db519298c542183be48de47f73d858b0a29169a32de6; // keccak256("SettlementDispatcherCardOrderProxy")
    bytes32 constant SALT_CASH_EVENT_EMITTER_PROXY    = 0xed6998f3c2ea6f567620976e6461add101a8ce47510c4c8aef17b4ec28296f84; // keccak256("CashEventEmitterProxy")
    bytes32 constant SALT_TOP_UP_DEST_PROXY           = 0x8572fe39434c3eb6f1e3b26d39a4f217b17bfba72ba042972cb4341f6de513eb; // keccak256("TopUpDestProxy")

    EtherFiSafeFactory safeFactory;
    EtherFiSafe safeImpl;
    EtherFiDataProvider dataProvider;
    RoleRegistry roleRegistry;
    EtherFiHook hook;
    TopUpDest topUpDest;
    ICashModule cashModule;
    CashLens cashLens;
    PriceProvider priceProvider;
    SettlementDispatcherV2 settlementDispatcherReap;
    SettlementDispatcherV2 settlementDispatcherRain;
    SettlementDispatcherV2 settlementDispatcherPix;
    SettlementDispatcherV2 settlementDispatcherCardOrder;
    IDebtManager debtManager;
    CashbackDispatcher cashbackDispatcher;
    CashEventEmitter cashEventEmitter;
    OpenOceanSwapModule openOceanSwapModule;

    address debtManagerCoreImpl;
    address debtManagerAdminImpl;
    address debtManagerInitializerImpl;
    address cashModuleSettersImpl;

    // ── OP Mainnet addresses ──
    address constant refundWallet = 0xF6B3422e3CC70fa9fce4fAb9A706ED2497c7bb9e;
    address constant etherFiRecoverySigner = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address constant thirdPartyRecoverySigner = 0x4F5eB42edEce3285B97245f56b64598191b5A58E;
    address constant etherFiWallet1 = 0xdC45DB93c3fC37272f40812bBa9C4Bad91344b46;
    address constant etherFiWallet2 = 0xB42833d6edd1241474D33ea99906fD4CBE893730;
    
    address constant openOceanSwapRouter = 0x6352a56caadC4F1E25CD6c75970Fa768A3304e64;
    address constant stargateUsdcPool = 0xcE8CcA271Ebc0533920C83d39F417ED6A0abB7D0;

    address constant usdc = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant wbtc = 0x68f180fcCe6836688e9084f035309E29Bf0A2095;
    address constant usdt = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
    address constant weth = 0x4200000000000000000000000000000000000006;
    address constant weeth = 0x5A7fACB970D094B6C7FF1df0eA68D99E6e73CBFF;
    address constant op = 0x4200000000000000000000000000000000000042;

    address constant weEthEthOracle = 0xb4479d436DDa5c1A79bD88D282725615202406E3;
    address constant wbtcUsdOracle = 0xD702DD976Fb76Fffc2D3963D037dfDae5b04E593;
    address constant usdcUsdOracle = 0x16a9FA2FDa030272Ce99B29CF780dFA30361E0f3;
    address constant usdtUsdOracle = 0xECef79E109e997bCA29c1c0897ec9d7b03647F5E;
    address constant ethUsdOracle = 0x13e3Ee699D1909E989722E753853AE30b17e08c5;
    address constant opUsdOracle = 0x0D276FC14719f9292D5C1eA2198673d1f4269246;

    function deployCreate3(bytes memory creationCode, bytes32 salt) internal returns (address deployed) {
        deployed = CREATE3.predictDeterministicAddress(salt, NICKS_FACTORY);

        if (deployed.code.length > 0) {
            console.log("  [SKIP] already deployed at", deployed);
            return deployed;
        }

        address proxy = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", NICKS_FACTORY, salt, CREATE3.PROXY_INITCODE_HASH)))));

        bool ok;
        if (proxy.code.length == 0) {
            (ok,) = NICKS_FACTORY.call(abi.encodePacked(salt, hex"67363d3d37363d34f03d5260086018f3"));
            require(ok, "CREATE3 proxy deploy failed");
        }

        (ok,) = proxy.call(creationCode);
        require(ok, "CREATE3 contract deploy failed");

        require(deployed.code.length > 0, "CREATE3 deployment verification failed");
    }

    struct Predicted {
        address roleRegistry;
        address dataProvider;
        address cashModule;
        address priceProvider;
        address cashbackDispatcher;
        address cashLens;
        address hook;
        address safeFactory;
        address debtManager;
        address settlementReap;
        address settlementRain;
        address settlementPix;
        address settlementCardOrder;
        address cashEventEmitter;
        address openOceanSwap;
        address topUpDest;
    }

    function _predictAll() internal pure returns (Predicted memory p) {
        p.roleRegistry = CREATE3.predictDeterministicAddress(SALT_ROLE_REGISTRY_PROXY, NICKS_FACTORY);
        p.dataProvider = CREATE3.predictDeterministicAddress(SALT_DATA_PROVIDER_PROXY, NICKS_FACTORY);
        p.cashModule = CREATE3.predictDeterministicAddress(SALT_CASH_MODULE_PROXY, NICKS_FACTORY);
        p.priceProvider = CREATE3.predictDeterministicAddress(SALT_PRICE_PROVIDER_PROXY, NICKS_FACTORY);
        p.cashbackDispatcher = CREATE3.predictDeterministicAddress(SALT_CASHBACK_DISPATCHER_PROXY, NICKS_FACTORY);
        p.cashLens = CREATE3.predictDeterministicAddress(SALT_CASH_LENS_PROXY, NICKS_FACTORY);
        p.hook = CREATE3.predictDeterministicAddress(SALT_HOOK_PROXY, NICKS_FACTORY);
        p.safeFactory = CREATE3.predictDeterministicAddress(SALT_SAFE_FACTORY_PROXY, NICKS_FACTORY);
        p.debtManager = CREATE3.predictDeterministicAddress(SALT_DEBT_MANAGER_PROXY, NICKS_FACTORY);
        p.settlementReap = CREATE3.predictDeterministicAddress(SALT_SETTLEMENT_REAP_PROXY, NICKS_FACTORY);
        p.settlementRain = CREATE3.predictDeterministicAddress(SALT_SETTLEMENT_RAIN_PROXY, NICKS_FACTORY);
        p.settlementPix = CREATE3.predictDeterministicAddress(SALT_SETTLEMENT_PIX_PROXY, NICKS_FACTORY);
        p.settlementCardOrder = CREATE3.predictDeterministicAddress(SALT_SETTLEMENT_CARD_ORDER_PROXY, NICKS_FACTORY);
        p.cashEventEmitter = CREATE3.predictDeterministicAddress(SALT_CASH_EVENT_EMITTER_PROXY, NICKS_FACTORY);
        p.openOceanSwap = CREATE3.predictDeterministicAddress(SALT_OPEN_OCEAN_SWAP_MODULE, NICKS_FACTORY);
        p.topUpDest = CREATE3.predictDeterministicAddress(SALT_TOP_UP_DEST_PROXY, NICKS_FACTORY);
    }

    function run() public {
        Predicted memory p = _predictAll();
        console.log("Predicted CashModule:", p.cashModule);
        console.log("Predicted DebtManager:", p.debtManager);

        vm.startBroadcast();

        console.log("Deploying EtherFiDataProvider...");
        address dataProviderImpl = deployCreate3(abi.encodePacked(type(EtherFiDataProvider).creationCode), SALT_DATA_PROVIDER_IMPL);
        {
            address[] memory modules = new address[](2);
            modules[0] = p.cashModule;
            modules[1] = p.openOceanSwap;

            bytes memory dpInitData = abi.encodeCall(
                EtherFiDataProvider.initialize,
                (EtherFiDataProvider.InitParams({
                    _roleRegistry: p.roleRegistry,
                    _cashModule: p.cashModule,
                    _cashLens: p.cashLens,
                    _modules: modules,
                    _defaultModules: modules,
                    _hook: p.hook,
                    _etherFiSafeFactory: p.safeFactory,
                    _priceProvider: p.priceProvider,
                    _etherFiRecoverySigner: etherFiRecoverySigner,
                    _thirdPartyRecoverySigner: thirdPartyRecoverySigner,
                    _refundWallet: refundWallet
                }))
            );
            dataProvider = EtherFiDataProvider(deployCreate3(
                abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(dataProviderImpl, dpInitData)),
                SALT_DATA_PROVIDER_PROXY
            ));
        }

        // RoleRegistry proxy already deployed (from ReserveAddresses); impl upgrade done via gnosis-txs/SetupOptimismProdGnosis.s.sol
        roleRegistry = RoleRegistry(p.roleRegistry);

        address roleRegistryImpl = deployCreate3(abi.encodePacked(type(RoleRegistry).creationCode, abi.encode(p.dataProvider)), SALT_ROLE_REGISTRY_IMPL);

        console.log("Deploying CashModule...");
        cashModuleSettersImpl = deployCreate3(abi.encodePacked(type(CashModuleSetters).creationCode, abi.encode(p.dataProvider)), SALT_CASH_MODULE_SETTERS_IMPL);
        address cashModuleCoreImpl = deployCreate3(abi.encodePacked(type(CashModuleCore).creationCode, abi.encode(p.dataProvider)), SALT_CASH_MODULE_CORE_IMPL);
        {
            bytes memory cmInitData = abi.encodeCall(
                ICashModule.initialize,
                (p.roleRegistry, p.debtManager, p.settlementReap, p.settlementRain, p.cashbackDispatcher, p.cashEventEmitter, cashModuleSettersImpl)
            );
            cashModule = ICashModule(deployCreate3(
                abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(cashModuleCoreImpl, cmInitData)),
                SALT_CASH_MODULE_PROXY
            ));
        }

        console.log("Deploying PriceProvider...");
        _setupPriceProvider(p.roleRegistry);

        console.log("Deploying CashbackDispatcher...");
        _setupCashbackDispatcher(p.roleRegistry, p.cashModule, p.priceProvider);

        console.log("Deploying CashLens...");
        address cashLensImpl = deployCreate3(abi.encodePacked(type(CashLens).creationCode, abi.encode(p.cashModule, p.dataProvider)), SALT_CASH_LENS_IMPL);
        cashLens = CashLens(deployCreate3(
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(cashLensImpl, abi.encodeCall(CashLens.initialize, (p.roleRegistry)))),
            SALT_CASH_LENS_PROXY
        ));

        console.log("Deploying EtherFiHook...");
        address hookImpl = deployCreate3(abi.encodePacked(type(EtherFiHook).creationCode, abi.encode(p.dataProvider)), SALT_HOOK_IMPL);
        hook = EtherFiHook(deployCreate3(
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(hookImpl, abi.encodeCall(EtherFiHook.initialize, (p.roleRegistry)))),
            SALT_HOOK_PROXY
        ));

        console.log("Deploying OpenOceanSwapModule...");
        openOceanSwapModule = OpenOceanSwapModule(deployCreate3(abi.encodePacked(type(OpenOceanSwapModule).creationCode, abi.encode(openOceanSwapRouter, p.dataProvider)), SALT_OPEN_OCEAN_SWAP_MODULE));

        console.log("Deploying EtherFiSafe + Factory...");
        safeImpl = EtherFiSafe(payable(deployCreate3(abi.encodePacked(type(EtherFiSafe).creationCode, abi.encode(p.dataProvider)), SALT_SAFE_IMPL)));
        address safeFactoryImpl = deployCreate3(abi.encodePacked(type(EtherFiSafeFactory).creationCode, ""), SALT_SAFE_FACTORY_IMPL);
        safeFactory = EtherFiSafeFactory(deployCreate3(
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(safeFactoryImpl, abi.encodeCall(EtherFiSafeFactory.initialize, (p.roleRegistry, address(safeImpl))))),
            SALT_SAFE_FACTORY_PROXY
        ));

        console.log("Deploying DebtManager...");
        _setupDebtManager(p.roleRegistry);

        console.log("Deploying SettlementDispatchers...");
        _setupSettlementDispatchers(p.roleRegistry, p.dataProvider);

        console.log("Deploying CashEventEmitter...");
        address cashEventEmitterImpl = deployCreate3(abi.encodePacked(type(CashEventEmitter).creationCode, abi.encode(p.cashModule)), SALT_CASH_EVENT_EMITTER_IMPL);
        cashEventEmitter = CashEventEmitter(deployCreate3(
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(cashEventEmitterImpl, abi.encodeCall(CashEventEmitter.initialize, (p.roleRegistry)))),
            SALT_CASH_EVENT_EMITTER_PROXY
        ));

        console.log("Deploying TopUpDest...");
        address topUpDestImpl = deployCreate3(abi.encodePacked(type(TopUpDest).creationCode, abi.encode(p.dataProvider)), SALT_TOP_UP_DEST_IMPL);
        topUpDest = TopUpDest(deployCreate3(
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(topUpDestImpl, abi.encodeCall(TopUpDest.initialize, (p.roleRegistry)))),
            SALT_TOP_UP_DEST_PROXY
        ));

        _writeDeployments();

        vm.stopBroadcast();
    }

    function _assertDeployment() internal view {
        // Expected addresses (deterministic: same salts + Nick's factory = same addresses as Scroll mainnet)
        _assertAddress("RoleRegistry", address(roleRegistry), 0x5C1E3D653fcbC54Ae25c2AD9d59548D2082C687B);
        _assertAddress("EtherFiDataProvider", address(dataProvider), 0xDC515Cb479a64552c5A11a57109C314E40A1A778);
        _assertAddress("EtherFiHook", address(hook), 0x5D3c4f5CF2208bB54e8fd129730d01D82d4611b3);
        _assertAddress("EtherFiSafeFactory", address(safeFactory), 0xF4e147Db314947fC1275a8CbB6Cde48c510cd8CF);
        _assertAddress("PriceProvider", address(priceProvider), 0x44dd2372FE7B97C4B4D6a7d4DeCf72466485BAcB);
        _assertAddress("CashbackDispatcher", address(cashbackDispatcher), 0xef55eC694B0B8273967f28627C5BC26F5deea836);
        _assertAddress("CashModule", address(cashModule), 0x7Ca0b75E67E33c0014325B739A8d019C4FE445F0);
        _assertAddress("CashEventEmitter", address(cashEventEmitter), 0x380B2e96799405be6e3D965f4044099891881acB);
        _assertAddress("CashLens", address(cashLens), 0x7DA874f3BacA1A8F0af27E5ceE1b8C66A772F84E);
        _assertAddress("DebtManager", address(debtManager), 0x0078C5a459132e279056B2371fE8A8eC973A9553);
        _assertAddress("TopUpDest", address(topUpDest), 0x3a6A724595184dda4be69dB1Ce726F2Ac3D66B87);
        _assertAddress("SettlementDispatcherReap", address(settlementDispatcherReap), 0x9623e86Df854FF3b48F7B4079a516a4F64861Db2);
        _assertAddress("SettlementDispatcherRain", address(settlementDispatcherRain), 0x50A233C4a0Bb1d7124b0224880037d35767a501C);

        console.log("");
        console.log("=== VERIFYING IMPLEMENTATION SLOTS ===");
        _assertImplAndInit("DataProvider", address(dataProvider));
        _assertImplAndInit("RoleRegistry", address(roleRegistry));
        _assertImplAndInit("CashModule", address(cashModule));
        _assertImplAndInit("PriceProvider", address(priceProvider));
        _assertImplAndInit("CashbackDispatcher", address(cashbackDispatcher));
        _assertImplAndInit("CashLens", address(cashLens));
        _assertImplAndInit("EtherFiHook", address(hook));
        _assertImplAndInit("EtherFiSafeFactory", address(safeFactory));
        _assertImplAndInit("DebtManager", address(debtManager));
        _assertImplAndInit("SettlementDispatcherReap", address(settlementDispatcherReap));
        _assertImplAndInit("SettlementDispatcherRain", address(settlementDispatcherRain));
        _assertImplAndInit("CashEventEmitter", address(cashEventEmitter));
        _assertImplAndInit("TopUpDest", address(topUpDest));
    }

    function _assertAddress(string memory name, address deployed, address expected) internal pure {
        if (deployed != expected) {
            console.log(string.concat("[MISMATCH] ", name));
            console.log("  deployed:", deployed);
            console.log("  expected:", expected);
            revert(string.concat(name, " address mismatch"));
        }
        console.log(string.concat("[OK] ", name), deployed);
    }

    function _assertImplAndInit(string memory name, address proxy) internal view {
        address impl = address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
        require(impl != address(0), string.concat(name, " impl is zero"));
        require(impl.code.length > 0, string.concat(name, " impl has no code"));

        bytes32 OZ_INIT_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
        uint256 initVersion = uint256(vm.load(proxy, OZ_INIT_SLOT));
        require(initVersion > 0, string.concat(name, " NOT initialized (version=0)"));

        bytes32 ROLE_REGISTRY_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;
        address storedRoleRegistry = address(uint160(uint256(vm.load(proxy, ROLE_REGISTRY_SLOT))));
        require(storedRoleRegistry == address(roleRegistry), string.concat(name, " roleRegistry mismatch - possible hijack!"));

        console.log(string.concat("[OK] ", name, " impl="), impl, string.concat(" init=", vm.toString(initVersion), " roleRegistry=OK"));
    }

    function _setupPriceProvider(address _roleRegistry) internal {
        PriceProvider.Config memory ethConfig = PriceProvider.Config({
            oracle: ethUsdOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(ethUsdOracle).decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });

        PriceProvider.Config memory wbtcConfig = PriceProvider.Config({
            oracle: wbtcUsdOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(wbtcUsdOracle).decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });

        PriceProvider.Config memory weETHConfig = PriceProvider.Config({
            oracle: weEthEthOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(weEthEthOracle).decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: true,
            isStableToken: false,
            isBaseTokenBtc: false
        });

        PriceProvider.Config memory usdcConfig = PriceProvider.Config({
            oracle: usdcUsdOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(usdcUsdOracle).decimals(),
            maxStaleness: 15 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: true,
            isBaseTokenBtc: false
        });

        PriceProvider.Config memory usdtConfig = PriceProvider.Config({
            oracle: usdtUsdOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(usdtUsdOracle).decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: true,
            isBaseTokenBtc: false
        });

        PriceProvider.Config memory opConfig = PriceProvider.Config({
            oracle: opUsdOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(opUsdOracle).decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });

        address[] memory initialTokens = new address[](7);
        initialTokens[0] = eth;
        initialTokens[1] = weth;
        initialTokens[2] = weeth;
        initialTokens[3] = usdc;
        initialTokens[4] = wbtc;
        initialTokens[5] = usdt;
        initialTokens[6] = op;

        PriceProvider.Config[] memory initialTokensConfig = new PriceProvider.Config[](7);
        initialTokensConfig[0] = ethConfig;
        initialTokensConfig[1] = ethConfig;
        initialTokensConfig[2] = weETHConfig;
        initialTokensConfig[3] = usdcConfig;
        initialTokensConfig[4] = wbtcConfig;
        initialTokensConfig[5] = usdtConfig;
        initialTokensConfig[6] = opConfig;

        address priceProviderImpl = deployCreate3(abi.encodePacked(type(PriceProvider).creationCode), SALT_PRICE_PROVIDER_IMPL);
        priceProvider = PriceProvider(deployCreate3(
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(priceProviderImpl, abi.encodeCall(PriceProvider.initialize, (_roleRegistry, initialTokens, initialTokensConfig)))),
            SALT_PRICE_PROVIDER_PROXY
        ));
    }

    function _setupCashbackDispatcher(address _roleRegistry, address _cashModule, address _priceProvider) internal {
        address cashbackDispatcherImpl = deployCreate3(abi.encodePacked(type(CashbackDispatcher).creationCode, abi.encode(address(dataProvider))), SALT_CASHBACK_DISPATCHER_IMPL);

        address[] memory cashbackTokens = new address[](2);
        cashbackTokens[0] = address(usdc);
        cashbackTokens[1] = address(weth);
        cashbackDispatcher = CashbackDispatcher(deployCreate3(
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(cashbackDispatcherImpl, abi.encodeCall(CashbackDispatcher.initialize, (_roleRegistry, _cashModule, _priceProvider, cashbackTokens)))),
            SALT_CASHBACK_DISPATCHER_PROXY
        ));
    }

    function _setupSettlementDispatchers(address _roleRegistry, address _dataProviderAddr) internal {
        address[] memory tokens = new address[](0);
        SettlementDispatcherV2.DestinationData[] memory destDatas = new SettlementDispatcherV2.DestinationData[](0);

        address settlementReapImpl = deployCreate3(abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.Reap, _dataProviderAddr)), SALT_SETTLEMENT_REAP_IMPL);
        settlementDispatcherReap = SettlementDispatcherV2(payable(deployCreate3(
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(settlementReapImpl, abi.encodeCall(SettlementDispatcherV2.initialize, (_roleRegistry, tokens, destDatas)))),
            SALT_SETTLEMENT_REAP_PROXY
        )));

        address settlementRainImpl = deployCreate3(abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.Rain, _dataProviderAddr)), SALT_SETTLEMENT_RAIN_IMPL);
        settlementDispatcherRain = SettlementDispatcherV2(payable(deployCreate3(
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(settlementRainImpl, abi.encodeCall(SettlementDispatcherV2.initialize, (_roleRegistry, tokens, destDatas)))),
            SALT_SETTLEMENT_RAIN_PROXY
        )));

        address settlementPixImpl = deployCreate3(abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.PIX, _dataProviderAddr)), SALT_SETTLEMENT_PIX_IMPL);
        settlementDispatcherPix = SettlementDispatcherV2(payable(deployCreate3(
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(settlementPixImpl, abi.encodeCall(SettlementDispatcherV2.initialize, (_roleRegistry, tokens, destDatas)))),
            SALT_SETTLEMENT_PIX_PROXY
        )));

        address settlementCardOrderImpl = deployCreate3(abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.CardOrder, _dataProviderAddr)), SALT_SETTLEMENT_CARD_ORDER_IMPL);
        settlementDispatcherCardOrder = SettlementDispatcherV2(payable(deployCreate3(
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(settlementCardOrderImpl, abi.encodeCall(SettlementDispatcherV2.initialize, (_roleRegistry, tokens, destDatas)))),
            SALT_SETTLEMENT_CARD_ORDER_PROXY
        )));
    }

    function _setupDebtManager(address _roleRegistry) internal {
        debtManagerCoreImpl = deployCreate3(abi.encodePacked(type(DebtManagerCore).creationCode, abi.encode(address(dataProvider))), SALT_DEBT_MANAGER_CORE_IMPL);
        debtManagerAdminImpl = deployCreate3(abi.encodePacked(type(DebtManagerAdmin).creationCode, abi.encode(address(dataProvider))), SALT_DEBT_MANAGER_ADMIN_IMPL);
        debtManagerInitializerImpl = deployCreate3(abi.encodePacked(type(DebtManagerInitializer).creationCode, abi.encode(address(dataProvider))), SALT_DEBT_MANAGER_INIT_IMPL);
        debtManager = IDebtManager(deployCreate3(
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(debtManagerInitializerImpl, abi.encodeCall(DebtManagerInitializer.initialize, (_roleRegistry)))),
            SALT_DEBT_MANAGER_PROXY
        ));
    }

    function _writeDeployments() internal {
        string memory parentObject = "parent object";
        string memory deployedAddresses = "addresses";

        vm.serializeAddress(deployedAddresses, "RoleRegistry", address(roleRegistry));
        vm.serializeAddress(deployedAddresses, "EtherFiDataProvider", address(dataProvider));
        vm.serializeAddress(deployedAddresses, "TopUpDest", address(topUpDest));
        vm.serializeAddress(deployedAddresses, "EtherFiSafeFactory", address(safeFactory));
        vm.serializeAddress(deployedAddresses, "EtherFiHook", address(hook));
        vm.serializeAddress(deployedAddresses, "DebtManager", address(debtManager));
        vm.serializeAddress(deployedAddresses, "PriceProvider", address(priceProvider));
        vm.serializeAddress(deployedAddresses, "OpenOceanSwapModule", address(openOceanSwapModule));
        vm.serializeAddress(deployedAddresses, "CashbackDispatcher", address(cashbackDispatcher));
        vm.serializeAddress(deployedAddresses, "CashModule", address(cashModule));
        vm.serializeAddress(deployedAddresses, "CashEventEmitter", address(cashEventEmitter));
        vm.serializeAddress(deployedAddresses, "CashLens", address(cashLens));
        vm.serializeAddress(deployedAddresses, "SettlementDispatcherReap", address(settlementDispatcherReap));
        vm.serializeAddress(deployedAddresses, "SettlementDispatcherRain", address(settlementDispatcherRain));
        vm.serializeAddress(deployedAddresses, "SettlementDispatcherPix", address(settlementDispatcherPix));
        string memory addressOutput = vm.serializeAddress(deployedAddresses, "SettlementDispatcherCardOrder", address(settlementDispatcherCardOrder));
        string memory finalJson = vm.serializeString(parentObject, deployedAddresses, addressOutput);

        writeDeploymentFile(finalJson);
    }
}
