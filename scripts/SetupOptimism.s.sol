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
import { SettlementDispatcher } from "../src/settlement-dispatcher/SettlementDispatcher.sol";
import { OpenOceanSwapModule } from "../src/modules/openocean-swap/OpenOceanSwapModule.sol";

contract SetupOptimism is Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    bytes32 constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    bytes32 constant SALT_DATA_PROVIDER_IMPL         = 0xa4406dc7aeac30333ad8d05173e94223a0cd6dcf1160428e53cab38425ecba39;
    bytes32 constant SALT_ROLE_REGISTRY_IMPL          = 0x2460801a69e117b026fd3dca86328e4fc8efee57882c83dae34318e84ee193f2;
    bytes32 constant SALT_CASH_MODULE_SETTERS_IMPL    = 0x604cbe9f0c5e269acf20e7ffb5106329bcc63f2fd3f19df9f9291ed8d51505b8;
    bytes32 constant SALT_CASH_MODULE_CORE_IMPL       = 0x8cf4c1e8eb9d1e4dbdf7fd35446a4ca6dd300d22f6a8c8afbc172862cb4b609d;
    bytes32 constant SALT_PRICE_PROVIDER_IMPL         = 0x60901529accbbd24b9d12f5d59e2c48edd343d8b6484507a94903c7458e8600d;
    bytes32 constant SALT_CASHBACK_DISPATCHER_IMPL    = 0xcbbc8be508477132f50f97b120874f2ec8368c7e7897a0c38cd4d0db5e358e98;
    bytes32 constant SALT_CASH_LENS_IMPL              = 0xde14b0ecaf40feaa0a35edd4317aed842e03ec5e9da261a4426016c8f5319e83;
    bytes32 constant SALT_HOOK_IMPL                   = 0xbca8f42b58187e4dff4ac93700828d882fd3519342b9de0237782fa4c3a2c4df;
    bytes32 constant SALT_OPEN_OCEAN_SWAP_MODULE      = 0x2c83f0671c068732a0a6b531e7250ff22610a70733488e069ad4f3a1a65d638e;
    bytes32 constant SALT_SAFE_IMPL                   = 0x46c5c6bcff9d7a0c52cab6e0c76f094300cb0d93a9ee3b69b5f18d2f51217458;
    bytes32 constant SALT_SAFE_FACTORY_IMPL           = 0xc8e64830043c6ed113c4b9f1ff41f8a859a0a99b497a8ea4468021dc5ddf717f;
    bytes32 constant SALT_DEBT_MANAGER_CORE_IMPL      = 0x624ac20f374ff391eedce09021ed1872855b76a768afa0be0177446fec8b9642;
    bytes32 constant SALT_DEBT_MANAGER_ADMIN_IMPL     = 0x3b5522288f73896141980fdc40080584d79373c521fd98560618f2a0b4b1dcdc;
    bytes32 constant SALT_DEBT_MANAGER_INIT_IMPL      = 0xd1d9da2bdc5a4ec73577b8728fc02071f50071c78f6bb0e8bdc431e27630c82a;
    bytes32 constant SALT_SETTLEMENT_REAP_IMPL        = 0x53cc8746ae5f1e9821d68d5f8eae14ea5d831472bfe417d64de99c8b1684b819;
    bytes32 constant SALT_CASH_EVENT_EMITTER_IMPL     = 0x9ca300c7f4d1e01fa8540b4d9279af35d45d2d29fd2e9272fa2f1bf02c29d491;
    bytes32 constant SALT_TOP_UP_DEST_IMPL            = 0xd6e0f3dff1e6b57da9a5b9f51414e3baab167d7a769529037dfdd132c1e6edda;

    bytes32 constant SALT_DATA_PROVIDER_PROXY         = 0x12756470399fa18f8fbc9af45a37ba7d31dde0c8fd0715241f8ff2e046417c2c;
    bytes32 constant SALT_ROLE_REGISTRY_PROXY         = 0x2cdd3a5a6d32bd8202f57f7d2c7a12505bd3ce5d4bf788c5d881fd2dd2e2f06a;
    bytes32 constant SALT_CASH_MODULE_PROXY           = 0xbaf660fd24b8d8bdb911b0ca60943986301c17940bc5011932c21fd4a4e7ddeb;
    bytes32 constant SALT_PRICE_PROVIDER_PROXY        = 0x5c8d4815aed009d88848a6292ae18869899701468cf02041809e28d40d7b0ebc;
    bytes32 constant SALT_CASHBACK_DISPATCHER_PROXY   = 0x8838c47680344e86ed68aeb9b77d373bb43d174de265465168f9c206a962c35c;
    bytes32 constant SALT_CASH_LENS_PROXY             = 0xd8558e3a695bf91456ca5997e608e4800b927b163af922c4c72302b90ebede71;
    bytes32 constant SALT_HOOK_PROXY                  = 0x53c7a897163b62814b8a00524fb7b61755bf01677c591123ca1f0b738a701018;
    bytes32 constant SALT_SAFE_FACTORY_PROXY          = 0xf8a17770967b5e97224007959b54d404185c01430bf45f1048077170756cf305;
    bytes32 constant SALT_DEBT_MANAGER_PROXY          = 0x6bb51c61406caa6f5e821cb2aca689b90be61e4d1386263495f9d89b211fbb02;
    bytes32 constant SALT_SETTLEMENT_REAP_PROXY       = 0x804b0c2c04ff79cd5ff386f276e9e37d37454befe4b01a7ad12209e739a81ee3;
    bytes32 constant SALT_CASH_EVENT_EMITTER_PROXY    = 0x276ea1733ce557251802d66595bc7ce861572497d3e71fa31d4e59d390694fb1;
    bytes32 constant SALT_TOP_UP_DEST_PROXY           = 0x0ed2551704b4d5019a19a153edce9bcf071e7733e0dde8a350ade2d8d61f83ad;
    bytes32 constant SALT_SETTLEMENT_RAIN_PROXY       = 0x6286357743f998d86948ecf201ef64dd0781165a9eaf4a60c859cc8fc01da2b1;

    address deployer;
    EtherFiSafeFactory safeFactory;
    EtherFiSafe safeImpl;
    EtherFiDataProvider dataProvider;
    RoleRegistry roleRegistry;
    EtherFiHook hook;
    TopUpDest topUpDest;
    ICashModule cashModule;
    CashLens cashLens;
    PriceProvider priceProvider;
    SettlementDispatcher settlementDispatcherReap;
    SettlementDispatcher settlementDispatcherRain;
    IDebtManager debtManager;
    CashbackDispatcher cashbackDispatcher;
    CashEventEmitter cashEventEmitter;
    OpenOceanSwapModule openOceanSwapModule;

    address debtManagerCoreImpl;
    address debtManagerAdminImpl;
    address debtManagerInitializerImpl;
    address cashModuleSettersImpl;

    address constant etherFiRecoverySigner = 0x7fEd99d0aA90423de55e238Eb5F9416FF7Cc58eF;
    address constant thirdPartyRecoverySigner = 0x24e311DA50784Cf9DB1abE59725e4A1A110220FA;
    address constant etherFiWallet = 0x2e0BE8D3D9f1833fbACf9A5e9f2d470817Ff0c00;

    address constant usdc = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant weETH = 0x5A7fACB970D094B6C7FF1df0eA68D99E6e73CBFF;
    address constant weth = 0x4200000000000000000000000000000000000006;

    address constant weEthWethOracle = 0xb4479d436DDa5c1A79bD88D282725615202406E3;
    address constant ethUsdOracle = 0x13e3Ee699D1909E989722E753853AE30b17e08c5;
    address constant usdcUsdOracle = 0x16a9FA2FDa030272Ce99B29CF780dFA30361E0f3;

    address constant openOceanSwapRouter = 0x6352a56caadC4F1E25CD6c75970Fa768A3304e64;
    address constant stargateUsdcPool = 0xcE8CcA271Ebc0533920C83d39F417ED6A0abB7D0;

    uint80 constant ltv = 50e18;
    uint80 constant liquidationThreshold = 80e18;
    uint96 constant liquidationBonus = 1e18;
    uint64 constant borrowApyPerSecond = 1;
    bytes32 public constant DEBT_MANAGER_ADMIN_ROLE = keccak256("DEBT_MANAGER_ADMIN_ROLE");

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
        p.cashEventEmitter = CREATE3.predictDeterministicAddress(SALT_CASH_EVENT_EMITTER_PROXY, NICKS_FACTORY);
        p.openOceanSwap = CREATE3.predictDeterministicAddress(SALT_OPEN_OCEAN_SWAP_MODULE, NICKS_FACTORY);
        p.topUpDest = CREATE3.predictDeterministicAddress(SALT_TOP_UP_DEST_PROXY, NICKS_FACTORY);
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);

        Predicted memory p = _predictAll();
        console.log("Predicted CashModule:", p.cashModule);
        console.log("Predicted DebtManager:", p.debtManager);

        vm.startBroadcast(deployerPrivateKey);

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
                    _refundWallet: deployer
                }))
            );
            dataProvider = EtherFiDataProvider(deployCreate3(
                abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(dataProviderImpl, dpInitData)),
                SALT_DATA_PROVIDER_PROXY
            ));
        }

        console.log("Deploying RoleRegistry...");
        address roleRegistryImpl = deployCreate3(abi.encodePacked(type(RoleRegistry).creationCode, abi.encode(p.dataProvider)), SALT_ROLE_REGISTRY_IMPL);
        roleRegistry = RoleRegistry(deployCreate3(
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(roleRegistryImpl, abi.encodeCall(RoleRegistry.initialize, (deployer)))),
            SALT_ROLE_REGISTRY_PROXY
        ));

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
        address cashLensImpl = deployCreate3(abi.encodePacked(type(CashLens).creationCode, abi.encode(p.cashModule, p.dataProvider, address(0))), SALT_CASH_LENS_IMPL);
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

        console.log("Configuring...");
        _configureWithdrawTokens();
        _grantRoles();
        _configureDebtManager();

        _assertAddresses();

        _writeDeployments();

        roleRegistry.revokeRole(DEBT_MANAGER_ADMIN_ROLE, deployer);

        vm.stopBroadcast();
    }

    function _assertAddresses() internal view {
        _assertAddress("RoleRegistry", address(roleRegistry), 0xa322a04d1e2Cb44672473740F9F35B057FA29CFB);
        _assertAddress("EtherFiDataProvider", address(dataProvider), 0x4a9c44c97BBf6079db37C4769AebE425bBcDD09a);
        _assertAddress("EtherFiHook", address(hook), 0xD517Cd9196a4F71Fe80178E96E5faF73B60bD764);
        _assertAddress("EtherFiSafeFactory", address(safeFactory), 0xDe69649e21DDceeC86738211dCe6f7Bb4DEcd27B);
        _assertAddress("PriceProvider", address(priceProvider), 0x7d7947D1ace9088048AaB067cF2F54eA1F762a4f);
        _assertAddress("CashbackDispatcher", address(cashbackDispatcher), 0x88758BDA231b8d989AFA0B408FfFD1dF67021F10);
        _assertAddress("CashModule", address(cashModule), 0xA4F3A3229FDFBfc7A30FEAC42337d931E85Dc969);
        _assertAddress("CashEventEmitter", address(cashEventEmitter), 0x357b440CfcD9677A99f2f85D5297c141B8837A9b);
        _assertAddress("CashLens", address(cashLens), 0xdFa3089466fD8Ce1c55E998cA3FdffC3371bc106);
        _assertAddress("DebtManager", address(debtManager), 0x92adCa2e95Eb9aCcA65a7dBa1A03ad5246d8f4F4);
        _assertAddress("TopUpDest", address(topUpDest), 0x06fe42Cf3C63412f1955758ce2798709476a38fd);
        _assertAddress("SettlementDispatcherReap", address(settlementDispatcherReap), 0xea6e574886797A65eD22CcF2307e48a83C355771);
        _assertAddress("SettlementDispatcherRain", address(settlementDispatcherRain), 0x26d90676C6aeF2a09Cf383af499cc67E9D6ad7CA);

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

    /// @notice Verify proxy has: valid impl, initialized > 0, AND roleRegistry points to OUR RoleRegistry
    function _assertImplAndInit(string memory name, address proxy) internal view {
        // Check EIP-1967 impl slot
        address impl = address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
        require(impl != address(0), string.concat(name, " impl is zero"));
        require(impl.code.length > 0, string.concat(name, " impl has no code"));

        // Check OZ Initializable storage slot — must be > 0 (initialized)
        bytes32 OZ_INIT_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
        uint256 initVersion = uint256(vm.load(proxy, OZ_INIT_SLOT));
        require(initVersion > 0, string.concat(name, " NOT initialized (version=0)"));

        // Check UpgradeableProxy.roleRegistry points to OUR RoleRegistry (not an attacker's)
        // Storage slot: 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500
        bytes32 ROLE_REGISTRY_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;
        address storedRoleRegistry = address(uint160(uint256(vm.load(proxy, ROLE_REGISTRY_SLOT))));
        require(storedRoleRegistry == address(roleRegistry), string.concat(name, " roleRegistry mismatch - possible hijack!"));

        console.log(string.concat("[OK] ", name, " impl="), impl, string.concat(" init=", vm.toString(initVersion), " roleRegistry=OK"));
    }

    function _setupPriceProvider(address _roleRegistry) internal {
        PriceProvider.Config memory weETHConfig = PriceProvider.Config({
            oracle: weEthWethOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(weEthWethOracle).decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: true,
            isStableToken: false,
            isBaseTokenBtc: false
        });

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

        address[] memory initialTokens = new address[](3);
        initialTokens[0] = weETH;
        initialTokens[1] = eth;
        initialTokens[2] = usdc;

        PriceProvider.Config[] memory initialTokensConfig = new PriceProvider.Config[](3);
        initialTokensConfig[0] = weETHConfig;
        initialTokensConfig[1] = ethConfig;
        initialTokensConfig[2] = usdcConfig;

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
        SettlementDispatcher.DestinationData[] memory destDatas = new SettlementDispatcher.DestinationData[](0);

        address settlementReapImpl = deployCreate3(abi.encodePacked(type(SettlementDispatcher).creationCode, abi.encode(BinSponsor.Reap, _dataProviderAddr)), SALT_SETTLEMENT_REAP_IMPL);
        settlementDispatcherReap = SettlementDispatcher(payable(deployCreate3(
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(settlementReapImpl, abi.encodeCall(SettlementDispatcher.initialize, (_roleRegistry, tokens, destDatas)))),
            SALT_SETTLEMENT_REAP_PROXY
        )));

        address settlementRainImpl = address(new SettlementDispatcher(BinSponsor.Rain, _dataProviderAddr));
        settlementDispatcherRain = SettlementDispatcher(payable(deployCreate3(
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(settlementRainImpl, abi.encodeCall(SettlementDispatcher.initialize, (_roleRegistry, tokens, destDatas)))),
            SALT_SETTLEMENT_RAIN_PROXY
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

    function _configureWithdrawTokens() internal {
        roleRegistry.grantRole(cashModule.CASH_MODULE_CONTROLLER_ROLE(), deployer);

        address[] memory tokens = new address[](2);
        tokens[0] = usdc;
        tokens[1] = weETH;

        bool[] memory shouldWhitelist = new bool[](2);
        shouldWhitelist[0] = true;
        shouldWhitelist[1] = true;

        cashModule.configureWithdrawAssets(tokens, shouldWhitelist);
        roleRegistry.revokeRole(cashModule.CASH_MODULE_CONTROLLER_ROLE(), deployer);
    }

    function _grantRoles() internal {
        roleRegistry.grantRole(roleRegistry.PAUSER(), deployer);
        roleRegistry.grantRole(roleRegistry.UNPAUSER(), deployer);
        roleRegistry.grantRole(dataProvider.DATA_PROVIDER_ADMIN_ROLE(), deployer);
        roleRegistry.grantRole(cashModule.CASH_MODULE_CONTROLLER_ROLE(), deployer);
        roleRegistry.grantRole(priceProvider.PRICE_PROVIDER_ADMIN_ROLE(), deployer);
        roleRegistry.grantRole(cashbackDispatcher.CASHBACK_DISPATCHER_ADMIN_ROLE(), deployer);
        roleRegistry.grantRole(DEBT_MANAGER_ADMIN_ROLE, deployer);
        roleRegistry.grantRole(settlementDispatcherReap.SETTLEMENT_DISPATCHER_BRIDGER_ROLE(), deployer);
        roleRegistry.grantRole(settlementDispatcherRain.SETTLEMENT_DISPATCHER_BRIDGER_ROLE(), deployer);
        roleRegistry.grantRole(topUpDest.TOP_UP_DEPOSITOR_ROLE(), deployer);

        roleRegistry.grantRole(cashModule.ETHER_FI_WALLET_ROLE(), etherFiWallet);
        roleRegistry.grantRole(safeFactory.ETHERFI_SAFE_FACTORY_ADMIN_ROLE(), etherFiWallet);
    }

    function _configureDebtManager() internal {
        IDebtManager.CollateralTokenConfig memory usdcCollateralTokenConfig = IDebtManager.CollateralTokenConfig({
            ltv: 90e18,
            liquidationThreshold: 95e18,
            liquidationBonus: 1e18
        });

        IDebtManager.CollateralTokenConfig memory nonStableCollateralTokenConfig = IDebtManager.CollateralTokenConfig({
            ltv: ltv,
            liquidationThreshold: liquidationThreshold,
            liquidationBonus: liquidationBonus
        });

        UUPSUpgradeable(address(debtManager)).upgradeToAndCall(debtManagerCoreImpl, "");
        debtManager.setAdminImpl(debtManagerAdminImpl);

        debtManager.supportCollateralToken(usdc, usdcCollateralTokenConfig);
        debtManager.supportCollateralToken(weETH, nonStableCollateralTokenConfig);

        uint128 minShares = uint128(10 * 10 ** IERC20Metadata(usdc).decimals());
        debtManager.supportBorrowToken(usdc, borrowApyPerSecond, minShares);
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
        string memory addressOutput = vm.serializeAddress(deployedAddresses, "SettlementDispatcherRain", address(settlementDispatcherRain));
        string memory finalJson = vm.serializeString(parentObject, deployedAddresses, addressOutput);

        writeDeploymentFile(finalJson);
    }
}
