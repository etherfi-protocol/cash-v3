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
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
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
import {Utils, ChainConfig} from "../utils/Utils.sol";

contract SafeTestSetup is Test {
    using MessageHashUtils for bytes32;

    EtherFiSafeFactory public safeFactory;
    EtherFiSafe public safe;
    EtherFiDataProvider public dataProvider;
    RoleRegistry public roleRegistry;
    EtherFiHook public hook;

    // IDebtManager debtManager = IDebtManager(0x8f9d2Cd33551CE06dD0564Ba147513F715c2F4a0);
    // ICashbackDispatcher cashbackDispatcher = ICashbackDispatcher(0x7d372C3ca903CA2B6ecd8600D567eb6bAfC5e6c9);
    // ICashEventEmitter cashEventEmitter = ICashEventEmitter(0x5423885B376eBb4e6104b8Ab1A908D350F6A162e);
    IPriceProvider priceProvider = IPriceProvider(0x8B4C8c403fc015C46061A8702799490FD616E3bf);
    address settlementDispatcher = 0x4Dca5093E0bB450D7f7961b5Df0A9d4c24B24786;
    IDebtManager debtManager;
    ICashbackDispatcher cashbackDispatcher;
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

    bytes32 public DEBT_MANAGER_ADMIN_ROLE = keccak256("DEBT_MANAGER_ADMIN_ROLE");


    function setUp() public virtual {
        vm.createSelectFork("https://rpc.scroll.io");

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

        address cashbackDispatcherImpl = address(new CashbackDispatcher(address(dataProvider)));
        cashbackDispatcher = ICashbackDispatcher(
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


        module1 = address(new ModuleBase(address(dataProvider)));
        module2 = address(new ModuleBase(address(dataProvider)));

        address[] memory modules = new address[](2);
        modules[0] = module1;
        modules[1] = module2;

        address safeImpl = address(new EtherFiSafe(address(dataProvider)));
        address safeFactoryImpl = address(new EtherFiSafeFactory());
        safeFactory = EtherFiSafeFactory(address(new UUPSProxy(safeFactoryImpl, abi.encodeWithSelector(EtherFiSafeFactory.initialize.selector, address(roleRegistry), safeImpl))));

        address hookImpl = address(new EtherFiHook(address(dataProvider)));
        hook = EtherFiHook(address(new UUPSProxy(hookImpl, abi.encodeWithSelector(EtherFiHook.initialize.selector, address(roleRegistry)))));

        address cashLensImpl = address(new CashLens(address(cashModule), address(dataProvider)));
        cashLens = CashLens(address(new UUPSProxy(cashLensImpl, abi.encodeWithSelector(CashLens.initialize.selector, address(roleRegistry)))));

        dataProvider.initialize(address(roleRegistry), address(cashModule), address(cashLens), modules, address(hook), address(safeFactory), address(priceProvider), etherFiRecoverySigner, thirdPartyRecoverySigner);

        _setupDebtManager();

        address cashEventEmitterImpl = address(new CashEventEmitter(address(cashModule)));
        cashEventEmitter = ICashEventEmitter(address(new UUPSProxy(cashEventEmitterImpl, abi.encodeWithSelector(CashEventEmitter.initialize.selector, address(roleRegistry)))));

        CashModuleCore(address(cashModule)).initialize(
            address(roleRegistry), 
            address(debtManager), 
            settlementDispatcher, 
            address(cashbackDispatcher), 
            address(cashEventEmitter), 
            cashModuleSettersImpl
        );

        roleRegistry.grantRole(cashModule.ETHER_FI_WALLET_ROLE(), etherFiWallet);
        roleRegistry.grantRole(cashModule.CASH_MODULE_CONTROLLER_ROLE(), owner);

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

    function _setupDebtManager() internal {
        address[] memory collateralTokens = new address[](2);
        collateralTokens[0] = address(weETHScroll);
        collateralTokens[1] = address(usdcScroll);
        address[] memory borrowTokens = new address[](1);
        borrowTokens[0] = address(usdcScroll);

        DebtManagerCore.CollateralTokenConfig[]
            memory collateralTokenConfig = new DebtManagerCore.CollateralTokenConfig[](
                2
            );

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

        DebtManagerAdmin(address(debtManager)).supportCollateralToken(address(weETHScroll), collateralTokenConfig[0]);
        DebtManagerAdmin(address(debtManager)).supportCollateralToken(address(usdcScroll), collateralTokenConfig[1]);
        
        minShares = uint128(10 * 10 ** IERC20Metadata(address(usdcScroll)).decimals());
        DebtManagerAdmin(address(debtManager)).supportBorrowToken(
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

    function _configureOwners(address[] memory owners, bool[] memory shouldAdd) internal {
        bytes32 structHash = keccak256(abi.encode(safe.CONFIGURE_OWNERS_TYPEHASH(), keccak256(abi.encodePacked(owners)), keccak256(abi.encodePacked(shouldAdd)), safe.nonce()));

        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        safe.configureOwners(owners, shouldAdd, signers, signatures);
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
}
