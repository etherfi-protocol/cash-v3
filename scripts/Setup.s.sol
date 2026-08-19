// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { UUPSProxy } from "../src/UUPSProxy.sol";
import {TopUpDest} from "../src/top-up/TopUpDest.sol";
import {RoleRegistry} from "../src/role-registry/RoleRegistry.sol";
import {EtherFiDataProvider} from "../src/data-provider/EtherFiDataProvider.sol";
import {EtherFiSafe} from "../src/safe/EtherFiSafe.sol";
import {EtherFiSafeFactory} from "../src/safe/EtherFiSafeFactory.sol";
import {EtherFiHook} from "../src/hook/EtherFiHook.sol";
import {ICashModule, BinSponsor} from "../src/interfaces/ICashModule.sol";
import {AaveV3Module} from "../src/modules/aave-v3/AaveV3Module.sol";
import {CashLens} from "../src/modules/cash/CashLens.sol";
import {Utils, ChainConfig} from "./utils/Utils.sol";
import {IDebtManager} from "../src/interfaces/IDebtManager.sol";
import {ICashbackDispatcher} from "../src/interfaces/ICashbackDispatcher.sol";
import {IPriceProvider} from "../src/interfaces/IPriceProvider.sol";
import {CashEventEmitter} from "../src/modules/cash/CashEventEmitter.sol";
import {CashModuleSetters} from "../src/modules/cash/CashModuleSetters.sol";
import {CashModuleCore} from "../src/modules/cash/CashModuleCore.sol";
import { DebtManagerInitializer } from "../src/debt-manager/DebtManagerInitializer.sol";
import { DebtManagerCore } from "../src/debt-manager/DebtManagerCore.sol";
import { DebtManagerAdmin } from "../src/debt-manager/DebtManagerAdmin.sol";
import { CashbackDispatcher } from "../src/cashback-dispatcher/CashbackDispatcher.sol";
import { PriceProvider, IAggregatorV3 } from "../src/oracle/PriceProvider.sol";
import { SettlementDispatcher } from "../src/settlement-dispatcher/SettlementDispatcher.sol";
import { OpenOceanSwapModule } from "../src/modules/openocean-swap/OpenOceanSwapModule.sol";


contract Setup is Utils {
    address owner;
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
    address debtManagerInitializer;

    address etherFiRecoverySigner = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address thirdPartyRecoverySigner = 0x4F5eB42edEce3285B97245f56b64598191b5A58E;
    address etherFiWallet = 0xdC45DB93c3fC37272f40812bBa9C4Bad91344b46;

    address usdcScroll = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    address weETHScroll = 0x01f0a31698C4d065659b9bdC21B3610292a1c506;
    address scrToken = 0xd29687c813D741E2F938F4aC377128810E217b1b;

    address weEthWethOracle;
    address ethUsdcOracle;
    address usdcUsdOracle;
    address scrUsdOracle;

    uint80 ltv = 50e18; // 50%
    uint80 liquidationThreshold = 80e18; // 80%
    uint96 liquidationBonus = 1e18; // 1%
    uint64 borrowApyPerSecond = 1; // 10% / (365 days in seconds)
    ChainConfig chainConfig;
    uint256 supplyCap = 1 ether;
    uint128 minShares;

    // https://docs.layerzero.network/v2/developers/evm/technical-reference/deployed-contracts
    uint32 optimismDestEid = 30111;
    address rykiOpAddress = 0x6f7F522075AA5483d049dF0Ef81FcdD3b0ace7f4;
    // https://stargateprotocol.gitbook.io/stargate/v/v2-developer-docs/technical-reference/mainnet-contracts#scroll
    address stargateUsdcPool = 0x3Fc69CC4A842838bCDC9499178740226062b14E4;
    address stargateEthPool = 0xC2b638Cb5042c1B3c5d5C969361fB50569840583;
    address openOceanSwapRouter = 0x6352a56caadC4F1E25CD6c75970Fa768A3304e64;

    bytes32 public DEBT_MANAGER_ADMIN_ROLE = keccak256("DEBT_MANAGER_ADMIN_ROLE");

    function run() public {
        // uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = 0x8D5AAc5d3d5cda4c404fA7ee31B0822B648Bb150;

        vm.startBroadcast();

        chainConfig = getChainConfig(vm.toString(block.chainid));

        owner = chainConfig.owner;
        weEthWethOracle = chainConfig.weEthWethOracle;
        ethUsdcOracle = chainConfig.ethUsdcOracle;
        scrUsdOracle = chainConfig.scrUsdOracle;
        usdcUsdOracle = chainConfig.usdcUsdOracle;

        address dataProviderImpl = deployWithCreate3(abi.encodePacked(type(EtherFiDataProvider).creationCode), getSalt(ETHER_FI_DATA_PROVIDER_IMPL));
        dataProvider = EtherFiDataProvider(deployWithCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(dataProviderImpl, "")), getSalt(ETHER_FI_DATA_PROVIDER_PROXY)));

        address roleRegistryImpl = deployWithCreate3(abi.encodePacked(type(RoleRegistry).creationCode, abi.encode(address(dataProvider))), getSalt(ROLE_REGISTRY_IMPL));
        roleRegistry = RoleRegistry(deployWithCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(roleRegistryImpl, "")), getSalt(ROLE_REGISTRY_PROXY)));
        roleRegistry.initialize(deployer);

        address cashModuleSettersImpl = deployWithCreate3(abi.encodePacked(type(CashModuleSetters).creationCode, abi.encode(address(dataProvider))), getSalt(CASH_MODULE_SETTERS_IMPL));
        address cashModuleCoreImpl = deployWithCreate3(abi.encodePacked(type(CashModuleCore).creationCode, abi.encode(address(dataProvider))), getSalt(CASH_MODULE_CORE_IMPL));
        cashModule = ICashModule(deployWithCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(cashModuleCoreImpl, "")), getSalt(CASH_MODULE_PROXY)));

        _setupPriceProvider();
        _setupCashbackDispatcher();

        address cashLensImpl = deployWithCreate3(abi.encodePacked(type(CashLens).creationCode, abi.encode(address(cashModule), address(dataProvider))), getSalt(CASH_LENS_IMPL));
        cashLens = CashLens(deployWithCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(cashLensImpl, "")), getSalt(CASH_LENS_PROXY)));
        cashLens.initialize(address(roleRegistry));

        address hookImpl = deployWithCreate3(abi.encodePacked(type(EtherFiHook).creationCode, abi.encode(address(dataProvider))), getSalt(ETHER_FI_HOOK_IMPL));
        hook = EtherFiHook(deployWithCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(hookImpl, "")), getSalt(ETHER_FI_HOOK_PROXY)));
        hook.initialize(address(roleRegistry));

        openOceanSwapModule = OpenOceanSwapModule(deployWithCreate3(abi.encodePacked(type(OpenOceanSwapModule).creationCode, abi.encode(openOceanSwapRouter, address(dataProvider))), getSalt(OPEN_OCEAN_SWAP_MODULE)));

        safeImpl = EtherFiSafe(payable(deployWithCreate3(abi.encodePacked(type(EtherFiSafe).creationCode, abi.encode(address(dataProvider))), getSalt(ETHER_FI_SAFE_IMPL))));
        address safeFactoryImpl = deployWithCreate3(abi.encodePacked(type(EtherFiSafeFactory).creationCode, ""), getSalt(ETHER_FI_SAFE_FACTORY_IMPL));
        safeFactory = EtherFiSafeFactory(deployWithCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(safeFactoryImpl, "")), getSalt(ETHER_FI_SAFE_FACTORY_PROXY)));
        safeFactory.initialize(address(roleRegistry), address(safeImpl));

        address[] memory modules = new address[](2);
        modules[0] = address(cashModule);
        modules[1] = address(openOceanSwapModule);

        dataProvider.initialize(address(roleRegistry), address(cashModule), address(cashLens), modules, address(hook), address(safeFactory), address(priceProvider), etherFiRecoverySigner, thirdPartyRecoverySigner);

        _setupDebtManager();
        _setupSettlementDispatcher();

        address cashEventEmitterImpl = deployWithCreate3(abi.encodePacked(type(CashEventEmitter).creationCode, abi.encode(address(cashModule))), getSalt(CASH_EVENT_EMITTER_IMPL));
        cashEventEmitter = CashEventEmitter(deployWithCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(cashEventEmitterImpl, "")), getSalt(CASH_EVENT_EMITTER_PROXY)));
        cashEventEmitter.initialize(address(roleRegistry));

        cashModule.initialize(
            address(roleRegistry),
            address(debtManager),
            address(settlementDispatcherReap),
            address(settlementDispatcherRain),
            address(cashbackDispatcher),
            address(cashEventEmitter),
            cashModuleSettersImpl
        );

        address topUpDestImpl = deployWithCreate3(abi.encodePacked(type(TopUpDest).creationCode,abi.encode(address(dataProvider))), getSalt(TOP_UP_DEST_IMPL));

        topUpDest = TopUpDest(deployWithCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(topUpDestImpl, "")), getSalt(TOP_UP_DEST_PROXY)));
        topUpDest.initialize(address(roleRegistry));

        _configureWithdrawTokens();

        _grantRoles();
        _configureDebtManager();

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
        string memory finalJson = vm.serializeString(
            parentObject,
            deployedAddresses,
            addressOutput
        );

        roleRegistry.revokeRole(DEBT_MANAGER_ADMIN_ROLE, deployer);
        if (deployer != owner) roleRegistry.transferOwnership(owner);

        writeDeploymentFile(finalJson);

        vm.stopBroadcast();
    }

    function _configureWithdrawTokens() internal {
        roleRegistry.grantRole(cashModule.CASH_MODULE_CONTROLLER_ROLE(), deployer);
        address[] memory tokens = new address[](3);
        tokens[0] = address(usdcScroll);
        tokens[1] = address(weETHScroll);
        tokens[2] = address(scrToken);

        bool[] memory shouldWhitelist = new bool[](3);
        shouldWhitelist[0] = true;
        shouldWhitelist[1] = true;
        shouldWhitelist[2] = true;

        cashModule.configureWithdrawAssets(tokens, shouldWhitelist);

        roleRegistry.revokeRole(cashModule.CASH_MODULE_CONTROLLER_ROLE(), deployer);
    }

    function _grantRoles() internal {
        roleRegistry.grantRole(roleRegistry.PAUSER(), owner);
        roleRegistry.grantRole(roleRegistry.UNPAUSER(), owner);
        roleRegistry.grantRole(dataProvider.DATA_PROVIDER_ADMIN_ROLE(), owner);
        roleRegistry.grantRole(cashModule.CASH_MODULE_CONTROLLER_ROLE(), owner);
        roleRegistry.grantRole(priceProvider.PRICE_PROVIDER_ADMIN_ROLE(), owner);
        roleRegistry.grantRole(cashbackDispatcher.CASHBACK_DISPATCHER_ADMIN_ROLE(), owner);
        roleRegistry.grantRole(DEBT_MANAGER_ADMIN_ROLE, owner);
        roleRegistry.grantRole(DEBT_MANAGER_ADMIN_ROLE, deployer);
        roleRegistry.grantRole(settlementDispatcher.SETTLEMENT_DISPATCHER_BRIDGER_ROLE(), owner);
        roleRegistry.grantRole(topUpDest.TOP_UP_DEPOSITOR_ROLE(), owner);

        roleRegistry.grantRole(cashModule.ETHER_FI_WALLET_ROLE(), etherFiWallet);
        roleRegistry.grantRole(safeFactory.ETHERFI_SAFE_FACTORY_ADMIN_ROLE(), etherFiWallet);
        // if (deployer != owner) roleRegistry.transferOwnership(owner);
    }

    function _setupPriceProvider() internal {
        PriceProvider.Config memory weETHConfig = PriceProvider.Config({
            oracle: weEthWethOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(weEthWethOracle).decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: true,
            isStableToken: false
        });

        PriceProvider.Config memory ethConfig = PriceProvider.Config({
            oracle: ethUsdcOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(ethUsdcOracle).decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: false
        });

        PriceProvider.Config memory usdcConfig = PriceProvider.Config({
            oracle: usdcUsdOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(usdcUsdOracle).decimals(),
            maxStaleness: 15 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: true
        });

        PriceProvider.Config memory scrollConfig = PriceProvider.Config({
            oracle: scrUsdOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(scrUsdOracle).decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: false
        });

        address[] memory initialTokens = new address[](4);
        initialTokens[0] = address(weETHScroll);
        initialTokens[1] = eth;
        initialTokens[2] = address(usdcScroll);
        initialTokens[3] = address(scrToken);

        PriceProvider.Config[] memory initialTokensConfig = new PriceProvider.Config[](4);
        initialTokensConfig[0] = weETHConfig;
        initialTokensConfig[1] = ethConfig;
        initialTokensConfig[2] = usdcConfig;
        initialTokensConfig[3] = scrollConfig;

        address priceProviderImpl = deployWithCreate3(abi.encodePacked(type(PriceProvider).creationCode), getSalt(PRICE_PROVIDER_IMPL));
        priceProvider = PriceProvider(deployWithCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(priceProviderImpl, "")), getSalt(PRICE_PROVIDER_PROXY)));
        priceProvider.initialize(address(roleRegistry), initialTokens, initialTokensConfig);
    }

    function _setupCashbackDispatcher() internal {
        address cashbackDispatcherImpl = deployWithCreate3(abi.encodePacked(type(CashbackDispatcher).creationCode, abi.encode(address(dataProvider))), getSalt(CASHBACK_DISPATCHER_IMPL));
        cashbackDispatcher = CashbackDispatcher(deployWithCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(cashbackDispatcherImpl, "")), getSalt(CASHBACK_DISPATCHER_PROXY)));
        cashbackDispatcher.initialize(address(roleRegistry), address(cashModule), address(priceProvider), address(scrToken));
    }

    function _setupSettlementDispatcher() internal {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);

        SettlementDispatcher.DestinationData[] memory destDatas = new SettlementDispatcher.DestinationData[](1);
        destDatas[0] = SettlementDispatcher.DestinationData({
            destEid: optimismDestEid,
            destRecipient: rykiOpAddress,
            stargate: stargateUsdcPool
        });

        address settlementDispatcherReapImpl = deployWithCreate3(abi.encodePacked(type(SettlementDispatcher).creationCode, abi.encode(BinSponsor.Reap)), getSalt(SETTLEMENT_DISPATCHER_IMPL));
        settlementDispatcherReap = SettlementDispatcher(payable(deployWithCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(settlementDispatcherReapImpl, "")), getSalt(SETTLEMENT_DISPATCHER_PROXY))));
        settlementDispatcherReap.initialize(address(roleRegistry), tokens, destDatas);
        
        address settlementDispatcherRainImpl = deployWithCreate3(abi.encodePacked(type(SettlementDispatcher).creationCode, abi.encode(BinSponsor.Rain)), getSalt(SETTLEMENT_DISPATCHER_RAIN_IMPL));
        settlementDispatcherRain = SettlementDispatcher(payable(deployWithCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(settlementDispatcherRainImpl, "")), getSalt(SETTLEMENT_DISPATCHER_RAIN_PROXY))));
        settlementDispatcherRain.initialize(address(roleRegistry), tokens, destDatas);
    }

    function _setupDebtManager() internal {
        debtManagerCoreImpl = deployWithCreate3(abi.encodePacked(type(DebtManagerCore).creationCode, abi.encode(address(dataProvider))), getSalt(DEBT_MANAGER_CORE_IMPL));
        debtManagerAdminImpl = deployWithCreate3(abi.encodePacked(type(DebtManagerAdmin).creationCode, abi.encode(address(dataProvider))), getSalt(DEBT_MANAGER_ADMIN_IMPL));
        debtManagerInitializer = deployWithCreate3(abi.encodePacked(type(DebtManagerInitializer).creationCode, abi.encode(debtManagerInitializer, address(dataProvider))), getSalt(DEBT_MANAGER_INITIALIZER_IMPL));
        debtManager = IDebtManager(deployWithCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(debtManagerInitializer, "")), getSalt(DEBT_MANAGER_PROXY)));
        DebtManagerInitializer(address(debtManager)).initialize(address(roleRegistry));
    }

    function _configureDebtManager() internal {
        // for usdc
        IDebtManager.CollateralTokenConfig memory usdcCollateralTokenConfig = IDebtManager.CollateralTokenConfig({
            ltv: 90e18, // 90%
            liquidationThreshold: 95e18, // 95%
            liquidationBonus: 1e18 // 1%
        });

        // for non stable tokens
        IDebtManager.CollateralTokenConfig memory nonStableCollateralTokenConfig = IDebtManager.CollateralTokenConfig({
            ltv: ltv, // 90%
            liquidationThreshold: liquidationThreshold, // 95%
            liquidationBonus: liquidationBonus // 1%
        });

        UUPSUpgradeable(address(debtManager)).upgradeToAndCall(debtManagerCoreImpl, "");
        debtManager.setAdminImpl(debtManagerAdminImpl);

        debtManager.supportCollateralToken(address(usdcScroll), usdcCollateralTokenConfig);
        debtManager.supportCollateralToken(address(weETHScroll), nonStableCollateralTokenConfig);
        debtManager.supportCollateralToken(address(scrToken), nonStableCollateralTokenConfig);

        minShares = uint128(10 * 10 ** IERC20Metadata(address(usdcScroll)).decimals());
        debtManager.supportBorrowToken(address(usdcScroll), borrowApyPerSecond, minShares);
    }
}
