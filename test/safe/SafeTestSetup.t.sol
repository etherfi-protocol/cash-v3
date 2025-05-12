// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";
import { IModule } from "../../src/interfaces/IModule.sol";
import { ModuleBase } from "../../src/modules/ModuleBase.sol";
import { ICashEventEmitter } from "../../src/interfaces/ICashEventEmitter.sol";
import { ICashModule, BinSponsor } from "../../src/interfaces/ICashModule.sol";
import { ICashbackDispatcher } from "../../src/interfaces/ICashbackDispatcher.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { IPriceProvider } from "../../src/interfaces/IPriceProvider.sol";
import { ModuleBase } from "../../src/modules/ModuleBase.sol";
import { CashLens } from "../../src/modules/cash/CashLens.sol";
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { ArrayDeDupLib, EtherFiSafe, EtherFiSafeBase, EtherFiSafeErrors } from "../../src/safe/EtherFiSafe.sol";
import { EtherFiSafeFactory } from "../../src/safe/EtherFiSafeFactory.sol";
import { DebtManagerInitializer } from "../../src/debt-manager/DebtManagerInitializer.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { DebtManagerAdmin } from "../../src/debt-manager/DebtManagerAdmin.sol";
import { CashbackDispatcher } from "../../src/cashback-dispatcher/CashbackDispatcher.sol";
import { PriceProvider, IAggregatorV3 } from "../../src/oracle/PriceProvider.sol";
import { SettlementDispatcher } from "../../src/settlement-dispatcher/SettlementDispatcher.sol";
import { Utils, ChainConfig } from "../utils/Utils.sol";

contract SafeTestSetup is Utils {
    using MessageHashUtils for bytes32;

    EtherFiSafeFactory public safeFactory;
    EtherFiSafe public safe;
    EtherFiDataProvider public dataProvider;
    RoleRegistry public roleRegistry;
    EtherFiHook public hook;

    PriceProvider priceProvider;
    SettlementDispatcher settlementDispatcherRain;
    SettlementDispatcher settlementDispatcherReap;
    IDebtManager debtManager;
    CashbackDispatcher cashbackDispatcher;
    ICashEventEmitter cashEventEmitter;

    address owner;
    uint256 owner1Pk;
    uint256 owner2Pk;
    uint256 owner3Pk;
    uint256 notOwnerPk;
    address public owner1;
    address public owner2;
    address public owner3;
    address public notOwner;
    address public pauser;
    address public unpauser;

    uint8 threshold;

    address public module1;
    address public module2;
    ICashModule public cashModule;
    CashLens public cashLens;

    address public etherFiWallet = makeAddr("etherFiWallet");
    
    uint256 public etherFiRecoverySignerPk;
    address public etherFiRecoverySigner;
    uint256 public thirdPartyRecoverySignerPk;
    address public thirdPartyRecoverySigner;

    IERC20 public usdcScroll = IERC20(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
    IERC20 public weETHScroll = IERC20(0x01f0a31698C4d065659b9bdC21B3610292a1c506);
    IERC20 public scrToken = IERC20(0xd29687c813D741E2F938F4aC377128810E217b1b);

    address weEthWethOracle;
    address ethUsdcOracle;
    address usdcUsdOracle;
    address scrUsdOracle;

    uint256 dailyLimitInUsd = 10_000e6;
    uint256 monthlyLimitInUsd = 100_000e6;
    uint80 ltv = 50e18; // 50%
    uint80 liquidationThreshold = 60e18; // 60%
    uint96 liquidationBonus = 5e18; // 5%
    uint64 borrowApyPerSecond = 317097919837; // 10% / (365 days in seconds)
    ChainConfig chainConfig;
    uint256 supplyCap = 10000 ether;
    int256 timezoneOffset = 4 * 60 * 60; // Dubai timezone
    uint128 minShares;

    // https://docs.layerzero.network/v2/developers/evm/technical-reference/deployed-contracts
    uint32 optimismDestEid = 30111;
    // https://stargateprotocol.gitbook.io/stargate/v/v2-developer-docs/technical-reference/mainnet-contracts#scroll
    address stargateUsdcPool = 0x3Fc69CC4A842838bCDC9499178740226062b14E4;
    address stargateEthPool = 0xC2b638Cb5042c1B3c5d5C969361fB50569840583;

    bytes32 public DEBT_MANAGER_ADMIN_ROLE = keccak256("DEBT_MANAGER_ADMIN_ROLE");

    // User recovery signers
    address userRecoverySigner1;
    address userRecoverySigner2;
    uint256 userRecoverySigner1Pk;
    uint256 userRecoverySigner2Pk;

    // Override recovery signers
    address overriddenEtherFiSigner;
    address overriddenThirdPartySigner;
    uint256 overriddenEtherFiSignerPk;
    uint256 overriddenThirdPartySignerPk;

    function setUp() public virtual {
        string memory scrollRpc = vm.envString("SCROLL_RPC");
        if (bytes(scrollRpc).length == 0) scrollRpc = "https://rpc.scroll.io"; 
        vm.createSelectFork(scrollRpc);
        
        pauser = makeAddr("pauser");
        unpauser = makeAddr("unpauser");
        owner = makeAddr("owner");
        (owner1, owner1Pk) = makeAddrAndKey("owner1");
        (owner2, owner2Pk) = makeAddrAndKey("owner2");
        (owner3, owner3Pk) = makeAddrAndKey("owner3");
        (notOwner, notOwnerPk) = makeAddrAndKey("notOwner");
        (etherFiRecoverySigner, etherFiRecoverySignerPk) = makeAddrAndKey("etherFiRecoverySigner");
        (thirdPartyRecoverySigner, thirdPartyRecoverySignerPk) = makeAddrAndKey("thirdPartyRecoverySigner");

        vm.startPrank(owner);

        chainConfig = getChainConfig(vm.toString(block.chainid));
        weEthWethOracle = chainConfig.weEthWethOracle;
        ethUsdcOracle = chainConfig.ethUsdcOracle;
        scrUsdOracle = chainConfig.scrUsdOracle;
        usdcUsdOracle = chainConfig.usdcUsdOracle;

        address dataProviderImpl = address(new EtherFiDataProvider());
        dataProvider = EtherFiDataProvider(address(new UUPSProxy(dataProviderImpl, "")));

        address roleRegistryImpl = address(new RoleRegistry(address(dataProvider)));
        roleRegistry = RoleRegistry(address(new UUPSProxy(roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));
        roleRegistry.grantRole(roleRegistry.PAUSER(), pauser);
        roleRegistry.grantRole(roleRegistry.UNPAUSER(), unpauser);

        roleRegistry.grantRole(dataProvider.DATA_PROVIDER_ADMIN_ROLE(), owner);

        address cashModuleSettersImpl = address(new CashModuleSetters(address(dataProvider)));
        address cashModuleCoreImpl = address(new CashModuleCore(address(dataProvider)));
        cashModule = ICashModule(address(new UUPSProxy(cashModuleCoreImpl, "")));

        _setupPriceProvider();
        _setupCashbackDispatcher();

        module1 = address(new ModuleBase(address(dataProvider)));
        module2 = address(new ModuleBase(address(dataProvider)));

        address[] memory modules = new address[](2);
        modules[0] = module1;
        modules[1] = module2;

        address[] memory defaultModules = new address[](1);
        defaultModules[0] = address(cashModule);

        address safeImpl = address(new EtherFiSafe(address(dataProvider)));
        address safeFactoryImpl = address(new EtherFiSafeFactory());
        safeFactory = EtherFiSafeFactory(address(new UUPSProxy(safeFactoryImpl, abi.encodeWithSelector(EtherFiSafeFactory.initialize.selector, address(roleRegistry), safeImpl))));

        address hookImpl = address(new EtherFiHook(address(dataProvider)));
        hook = EtherFiHook(address(new UUPSProxy(hookImpl, abi.encodeWithSelector(EtherFiHook.initialize.selector, address(roleRegistry)))));

        address cashLensImpl = address(new CashLens(address(cashModule), address(dataProvider)));
        cashLens = CashLens(address(new UUPSProxy(cashLensImpl, abi.encodeWithSelector(CashLens.initialize.selector, address(roleRegistry)))));

        dataProvider.initialize(EtherFiDataProvider.InitParams(address(roleRegistry), address(cashModule), address(cashLens), modules, defaultModules, address(hook), address(safeFactory), address(priceProvider), etherFiRecoverySigner, thirdPartyRecoverySigner));

        _setupDebtManager();
        _setupSettlementDispatcher();

        _setupCashEventEmitter();

        CashModuleCore(address(cashModule)).initialize(
            address(roleRegistry), 
            address(debtManager), 
            address(settlementDispatcherReap), 
            address(settlementDispatcherRain), 
            address(cashbackDispatcher), 
            address(cashEventEmitter), 
            cashModuleSettersImpl
        );

        roleRegistry.grantRole(cashModule.ETHER_FI_WALLET_ROLE(), etherFiWallet);
        roleRegistry.grantRole(cashModule.CASH_MODULE_CONTROLLER_ROLE(), owner);

        _setupWithdrawTokenWhitelist();

        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;

        threshold = 2;


        bytes[] memory moduleSetupData = new bytes[](2);

        roleRegistry.grantRole(safeFactory.ETHERFI_SAFE_FACTORY_ADMIN_ROLE(), owner);
        safeFactory.deployEtherFiSafe(keccak256("safe"), owners, modules, moduleSetupData, threshold);
        safe = EtherFiSafe(payable(safeFactory.getDeterministicAddress(keccak256("safe"))));

        vm.stopPrank();
    }

    function _setupWithdrawTokenWhitelist() internal {
        address[] memory tokens = new address[](3);
        tokens[0] = address(usdcScroll);
        tokens[1] = address(weETHScroll);
        tokens[2] = address(scrToken);

        bool[] memory whitelist = new bool[](3);
        whitelist[0] = true;
        whitelist[1] = true;
        whitelist[2] = true;
    
        cashModule.configureWithdrawAssets(tokens, whitelist);
    }

    function _setupCashEventEmitter() internal {
        address cashEventEmitterImpl = address(new CashEventEmitter(address(cashModule)));
        cashEventEmitter = ICashEventEmitter(address(new UUPSProxy(cashEventEmitterImpl, abi.encodeWithSelector(CashEventEmitter.initialize.selector, address(roleRegistry)))));
    }

    function _setupPriceProvider() internal {
        PriceProvider.Config memory weETHConfig = PriceProvider.Config({
            oracle: weEthWethOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(weEthWethOracle).decimals(),
            maxStaleness: type(uint24).max,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: true,
            isStableToken: false,
            isBaseTokenBtc: false
        });
        
        PriceProvider.Config memory ethConfig = PriceProvider.Config({
            oracle: ethUsdcOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(ethUsdcOracle).decimals(),
            maxStaleness: type(uint24).max,
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
            maxStaleness: type(uint24).max,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: true,
            isBaseTokenBtc: false
        });
        
        PriceProvider.Config memory scrollConfig = PriceProvider.Config({
            oracle: scrUsdOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(scrUsdOracle).decimals(),
            maxStaleness: type(uint24).max,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
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

        priceProvider = PriceProvider(address(new UUPSProxy(
            address(new PriceProvider()), 
            abi.encodeWithSelector(
                PriceProvider.initialize.selector,
                address(roleRegistry),
                initialTokens,
                initialTokensConfig
            )
        )));
        roleRegistry.grantRole(priceProvider.PRICE_PROVIDER_ADMIN_ROLE(), owner);
    }
    
    function _setupCashbackDispatcher() internal {
        address cashbackDispatcherImpl = address(new CashbackDispatcher(address(dataProvider)));
        cashbackDispatcher = CashbackDispatcher(
            address(
                new UUPSProxy(
                    cashbackDispatcherImpl, 
                    abi.encodeWithSelector(
                        CashbackDispatcher.initialize.selector,
                        address(roleRegistry),
                        address(cashModule),
                        address(priceProvider),
                        address(scrToken)
                    )
                )
            )
        );

        deal(address(scrToken), address(cashbackDispatcher), 100000 ether);

        roleRegistry.grantRole(cashbackDispatcher.CASHBACK_DISPATCHER_ADMIN_ROLE(), owner);
    }

    function _setupSettlementDispatcher() internal {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);

        SettlementDispatcher.DestinationData[] memory destDatas = new SettlementDispatcher.DestinationData[](1);
        destDatas[0] = SettlementDispatcher.DestinationData({
            destEid: optimismDestEid,
            destRecipient: owner,
            stargate: stargateUsdcPool
        });

        address settlementDispatcherRainImpl = address(new SettlementDispatcher(BinSponsor.Rain));
        settlementDispatcherRain = SettlementDispatcher(
            payable(address(new UUPSProxy(
                settlementDispatcherRainImpl, 
                abi.encodeWithSelector(SettlementDispatcher.initialize.selector, address(roleRegistry), tokens, destDatas)
            )))
        );

        roleRegistry.grantRole(settlementDispatcherRain.SETTLEMENT_DISPATCHER_BRIDGER_ROLE(), owner);

        address settlementDispatcherReapImpl = address(new SettlementDispatcher(BinSponsor.Reap));
        settlementDispatcherReap = SettlementDispatcher(
            payable(address(new UUPSProxy(
                settlementDispatcherReapImpl, 
                abi.encodeWithSelector(SettlementDispatcher.initialize.selector, address(roleRegistry), tokens, destDatas)
            )))
        );

        roleRegistry.grantRole(settlementDispatcherReap.SETTLEMENT_DISPATCHER_BRIDGER_ROLE(), owner);
    }

    function _setupDebtManager() internal {
        address[] memory collateralTokens = new address[](2);
        collateralTokens[0] = address(weETHScroll);
        collateralTokens[1] = address(usdcScroll);
        address[] memory borrowTokens = new address[](1);
        borrowTokens[0] = address(usdcScroll);

        IDebtManager.CollateralTokenConfig[] memory collateralTokenConfig = new IDebtManager.CollateralTokenConfig[](2);

        collateralTokenConfig[0].ltv = ltv;
        collateralTokenConfig[0].liquidationThreshold = liquidationThreshold;
        collateralTokenConfig[0].liquidationBonus = liquidationBonus;
        
        collateralTokenConfig[1].ltv = ltv;
        collateralTokenConfig[1].liquidationThreshold = liquidationThreshold;
        collateralTokenConfig[1].liquidationBonus = liquidationBonus;

        address debtManagerCoreImpl = address(new DebtManagerCore(address(dataProvider)));
        address debtManagerAdminImpl = address(new DebtManagerAdmin(address(dataProvider)));
        address debtManagerInitializer = address(new DebtManagerInitializer(address(dataProvider)));
        address debtManagerProxy = address(new UUPSProxy(debtManagerInitializer, abi.encodeWithSelector(DebtManagerInitializer.initialize.selector, address(roleRegistry))));

        roleRegistry.grantRole(DEBT_MANAGER_ADMIN_ROLE, owner);

        UUPSUpgradeable(debtManagerProxy).upgradeToAndCall(debtManagerCoreImpl, "");
        debtManager = IDebtManager(address(debtManagerProxy));
        debtManager.setAdminImpl(debtManagerAdminImpl);

        debtManager.supportCollateralToken(address(weETHScroll), collateralTokenConfig[0]);
        debtManager.supportCollateralToken(address(usdcScroll), collateralTokenConfig[1]);
        
        minShares = uint128(10 * 10 ** IERC20Metadata(address(usdcScroll)).decimals());
        debtManager.supportBorrowToken(
            address(usdcScroll), 
            borrowApyPerSecond, 
            minShares
        );

        deal(address(usdcScroll), address(owner), 1 ether);
        usdcScroll.approve(address(debtManager), 100000e6);
        debtManager.supply(address(owner), address(usdcScroll), 100000e6);
    }

    function _configureModules(address[] memory modules, bool[] memory shouldWhitelist, bytes[] memory setupData) internal {
        // Hash each bytes element in setupData individually
        uint256 len = setupData.length;
        bytes32[] memory dataHashes = new bytes32[](len);
        for (uint256 i = 0; i < len; ) {
            dataHashes[i] = keccak256(setupData[i]);
            unchecked {
                ++i;
            }
        }
        
        // Concatenate the hashes and hash again
        bytes32 setupDataHash = keccak256(abi.encodePacked(dataHashes));

        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_MODULES_TYPEHASH(), keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), setupDataHash, safe.nonce()));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        _sendConfigureModules(modules, shouldWhitelist, setupData, abi.encodePacked(r1, s1, v1), abi.encodePacked(r2, s2, v2));
    }

    function _sendConfigureModules(address[] memory modules, bool[] memory shouldWhitelist, bytes[] memory setupData, bytes memory sig1, bytes memory sig2) internal {
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = sig1;
        signatures[1] = sig2;

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        safe.configureModules(modules, shouldWhitelist, setupData, signers, signatures);
    }

    function _configureAdmins(address[] memory accounts, bool[] memory shouldAdd) internal {
        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_ADMIN_TYPEHASH(), keccak256(abi.encodePacked(accounts)), keccak256(abi.encodePacked(shouldAdd)), safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        vm.expectEmit(true, true, true, true);
        emit EtherFiSafeBase.AdminsConfigured(accounts, shouldAdd);
        safe.configureAdmins(accounts, shouldAdd, signers, signatures);
    }

    function _cancelNonce() internal {
        uint256 nonce = safe.nonce();
        bytes32 structHash = keccak256(abi.encode(safe.CANCEL_NONCE_TYPEHASH(), nonce));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        vm.expectEmit(true, true, true, true);
        emit EtherFiSafeBase.NonceCancelled(nonce);
        safe.cancelNonce(signers, signatures);
    }

    function _configureOwners(address[] memory owners, bool[] memory shouldAdd, uint8 newThreshold) internal {
        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_OWNERS_TYPEHASH(), keccak256(abi.encodePacked(owners)), keccak256(abi.encodePacked(shouldAdd)), newThreshold, safe.nonce()));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        safe.configureOwners(owners, shouldAdd, newThreshold, signers, signatures);
    }

    function _setThreshold(uint8 newThreshold) internal {
        bytes32 structHash = keccak256(abi.encode(safe.SET_THRESHOLD_TYPEHASH(), newThreshold, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        safe.setThreshold(newThreshold, signers, signatures);
    }

        function _setUserRecoverySigners(address[] memory signers, bool[] memory shouldAdd) internal {
        bytes32 structHash = keccak256(abi.encode(safe.SET_USER_RECOVERY_SIGNERS_TYPEHASH(), keccak256(abi.encodePacked(signers)), keccak256(abi.encodePacked(shouldAdd)), safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory ownerSigners = new address[](2);
        ownerSigners[0] = owner1;
        ownerSigners[1] = owner2;

        safe.setUserRecoverySigners(signers, shouldAdd, ownerSigners, signatures);
    }

    function _setRecoveryThreshold(uint8 recoveryThreshold) internal {
        bytes32 structHash = keccak256(abi.encode(safe.SET_RECOVERY_THRESHOLD_TYPEHASH(), recoveryThreshold, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        safe.setRecoveryThreshold(recoveryThreshold, signers, signatures);
    }

    function _toggleRecoveryEnabled(bool shouldEnable) internal {
        bytes32 structHash = keccak256(abi.encode(safe.TOGGLE_RECOVERY_ENABLED_TYPEHASH(), shouldEnable, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        safe.toggleRecoveryEnabled(shouldEnable, signers, signatures);
    }

    function _overrideRecoverySigners(address[2] memory newSigners) internal {
        bytes32 structHash = keccak256(abi.encode(safe.OVERRIDE_RECOVERY_SIGNERS_TYPEHASH(), keccak256(abi.encodePacked(newSigners)), safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        safe.overrideRecoverySigners(newSigners, signers, signatures);
    }

    function _recoverSafe(address newOwner, address[] memory recoverySigners, bytes[] memory signatures) internal {
        safe.recoverSafe(newOwner, recoverySigners, signatures);
    }

    function _recoverSafeWithSigners(address newOwner, address[] memory recoverySigners) internal {
        bytes32 structHash = keccak256(abi.encode(safe.RECOVER_SAFE_TYPEHASH(), newOwner, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        
        bytes[] memory signatures = new bytes[](recoverySigners.length);
        
        for (uint i = 0; i < recoverySigners.length; i++) {
            uint256 signerKey;
            
            if (recoverySigners[i] == etherFiRecoverySigner) signerKey = etherFiRecoverySignerPk;
            else if (recoverySigners[i] == thirdPartyRecoverySigner) signerKey = thirdPartyRecoverySignerPk;
            else if (recoverySigners[i] == userRecoverySigner1) signerKey = userRecoverySigner1Pk;
            else if (recoverySigners[i] == userRecoverySigner2) signerKey = userRecoverySigner2Pk;
            else if (recoverySigners[i] == overriddenEtherFiSigner) signerKey = overriddenEtherFiSignerPk;
            else if (recoverySigners[i] == overriddenThirdPartySigner) signerKey = overriddenThirdPartySignerPk;
            else revert("Unknown recovery signer in test");
            
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digestHash);
            signatures[i] = abi.encodePacked(r, s, v);
        }
        
        safe.recoverSafe(newOwner, recoverySigners, signatures);
    }

    function _cancelRecovery() internal {
        bytes32 structHash = keccak256(abi.encode(safe.CANCEL_RECOVERY_TYPEHASH(), safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        safe.cancelRecovery(signers, signatures);
    }

    // Helper function for signing with new owner after recovery
    function _signWithNewOwner(uint256 newOwnerPk, bytes32 message) internal pure returns (bytes memory signature) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(newOwnerPk, message);
        return abi.encodePacked(r, s, v);
    }
}
