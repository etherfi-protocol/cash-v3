// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console2 } from "forge-std/console2.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { AcrossSwapModule } from "../../src/across/AcrossSwapModule.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { EnsoSwapModule } from "../../src/enso/EnsoSwapModule.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUp } from "../../src/top-up/TopUp.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { TradingLens } from "../../src/trading-safe/TradingLens.sol";
import { TradingSafe } from "../../src/trading-safe/TradingSafe.sol";
import { TradingSafeFactory } from "../../src/trading-safe/TradingSafeFactory.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";
import { Utils } from "../utils/Utils.sol";
import { TradingAccountProdConfig as Prod } from "./TradingAccountProdConfig.sol";

/// @notice In-place upgrade of the existing Ethereum dev trading stack.
/// @dev Preserves the canonical proxy identities recorded in
///      `deployments/dev/1/trading-account.json` — RoleRegistry, PriceProvider, DataProvider,
///      TradingSafeFactory, and TradingLens — by upgrading their implementations (and the
///      TradingSafe beacon) rather than redeploying. Fresh Across/Enso module proxies are
///      deployed additively and left alongside the old modules so an in-flight backend
///      transition never orphans state. With PRIVATE_KEY unset, fork simulations impersonate
///      DEV_ADMIN; real broadcasts must provide the corresponding private key.
contract DeployTradingAccountEthereumDevV2 is Utils {
    using stdJson for string;

    EtherFiDeployer private constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);
    address private constant DEV_ADMIN = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;
    bytes32 private constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // Canonical proxies preserved across the upgrade (loaded from the dev manifest).
    address private roleRegistryProxy;
    address private priceProviderProxy;
    address private dataProviderProxy;
    address private factoryProxy;
    address private lensProxy;

    // Freshly deployed implementations bound to the canonical proxy addresses.
    address private roleRegistryImpl;
    address private priceProviderImpl;
    address private dataProviderImpl;
    address private factoryImpl;
    address private lensImpl;
    address private tradingSafeImpl;

    // Freshly deployed module proxies (added additively; old modules stay authorized).
    address private acrossProxy;
    address private ensoProxy;

    // TopUp source stack (shared with the cash deployment).
    address private topUpFactory;
    address private topUpRoleRegistry;

    // Recovery / refund config captured before the upgrade to assert it is preserved.
    address private priorRecoverySigner;
    address private priorThirdPartyRecoverySigner;
    address private priorRefundWallet;

    function run() external {
        require(block.chainid == 1, "must run on Ethereum");
        require(DEPLOYER.isDeployer(DEV_ADMIN), "dev admin is not an EtherFiDeployer");

        string memory trading = _readTradingManifest();
        roleRegistryProxy = trading.readAddress(".RoleRegistry");
        priceProviderProxy = trading.readAddress(".PriceProvider");
        dataProviderProxy = trading.readAddress(".EtherFiDataProvider");
        factoryProxy = trading.readAddress(".TradingSafeFactory");
        lensProxy = trading.readAddress(".TradingLens");

        string memory topUpDeployments = readTopUpSourceDeployment();
        topUpFactory = topUpDeployments.readAddress(".addresses.TopUpSourceFactory");
        topUpRoleRegistry = topUpDeployments.readAddress(".addresses.RoleRegistry");

        require(RoleRegistry(roleRegistryProxy).owner() == DEV_ADMIN, "dev admin is not trading RoleRegistry owner");
        require(RoleRegistry(topUpRoleRegistry).owner() == DEV_ADMIN, "dev admin is not TopUp RoleRegistry owner");
        require(EtherFiDataProvider(dataProviderProxy).getCashModule() == address(0), "unexpected cash module on trading stack");

        EtherFiDataProvider provider = EtherFiDataProvider(dataProviderProxy);
        priorRecoverySigner = provider.getEtherFiRecoverySigner();
        priorThirdPartyRecoverySigner = provider.getThirdPartyRecoverySigner();
        priorRefundWallet = provider.getRefundWallet();

        _startBroadcast();
        _deployImplementations();
        _upgradeCoreStack();
        _deployModules();
        _configureTradingStack();
        _wireTopUp();
        _configureSupportedTokens();
        vm.stopBroadcast();

        _assertConfigured();
        _writeManifest();
    }

    /// @dev Implementations are deployed with the CANONICAL proxy addresses as immutable
    ///      constructor bindings so the upgraded proxies keep pointing at the same data
    ///      provider / price provider they were initialised with.
    function _deployImplementations() private {
        roleRegistryImpl = _deploy("TradingAccount.DevRestore.RoleRegistryImpl", type(RoleRegistry).creationCode, abi.encode(dataProviderProxy));
        priceProviderImpl = _deploy("TradingAccount.DevRestore.PriceProviderImpl", type(PriceProviderV2).creationCode, "");
        dataProviderImpl = _deploy("TradingAccount.DevRestore.DataProviderImpl", type(EtherFiDataProvider).creationCode, "");
        factoryImpl = _deploy("TradingAccount.DevRestore.TradingSafeFactoryImpl", type(TradingSafeFactory).creationCode, "");
        lensImpl = _deploy("TradingAccount.DevRestore.TradingLensImpl", type(TradingLens).creationCode, abi.encode(priceProviderProxy));
        tradingSafeImpl = _deploy("TradingAccount.DevRestore.TradingSafeImpl", type(TradingSafe).creationCode, abi.encode(dataProviderProxy));
    }

    /// @dev Upgrades implementations without re-initializing — all proxy storage (roles,
    ///      modules, signers, factory links, supported tokens, deployed-safe records) is
    ///      preserved so existing safe identities, mappings, and balances survive.
    function _upgradeCoreStack() private {
        UUPSUpgradeable(dataProviderProxy).upgradeToAndCall(dataProviderImpl, "");
        UUPSUpgradeable(priceProviderProxy).upgradeToAndCall(priceProviderImpl, "");
        UUPSUpgradeable(roleRegistryProxy).upgradeToAndCall(roleRegistryImpl, "");
        UUPSUpgradeable(lensProxy).upgradeToAndCall(lensImpl, "");
        UUPSUpgradeable(factoryProxy).upgradeToAndCall(factoryImpl, "");
        TradingSafeFactory(factoryProxy).upgradeBeaconImplementation(tradingSafeImpl);
    }

    /// @dev Deploys fresh module proxies bound to the canonical data provider and registers
    ///      them as default modules additively. The pre-existing modules stay whitelisted and
    ///      default so a backend cutover can drain them before they are retired separately.
    function _deployModules() private {
        address acrossImpl = _deploy("TradingAccount.DevRestore.AcrossSwapModuleImpl", type(AcrossSwapModule).creationCode, abi.encode(dataProviderProxy));
        acrossProxy = _deployProxy("TradingAccount.DevRestore.AcrossSwapModuleProxy", acrossImpl, abi.encodeWithSelector(AcrossSwapModule.initialize.selector, roleRegistryProxy, Prod.ETH_SPOKE_POOL, Prod.MULTICALL_HANDLER));

        address ensoImpl = _deploy("TradingAccount.DevRestore.EnsoSwapModuleImpl", type(EnsoSwapModule).creationCode, abi.encode(dataProviderProxy));
        ensoProxy = _deployProxy("TradingAccount.DevRestore.EnsoSwapModuleProxy", ensoImpl, abi.encodeWithSelector(EnsoSwapModule.initialize.selector, roleRegistryProxy, Prod.ENSO_ROUTER));
    }

    function _configureTradingStack() private {
        RoleRegistry registry = RoleRegistry(roleRegistryProxy);
        TradingSafeFactory factory = TradingSafeFactory(factoryProxy);
        TradingLens lens = TradingLens(lensProxy);
        EtherFiDataProvider provider = EtherFiDataProvider(dataProviderProxy);

        // grantRole is idempotent, so re-granting roles the original deployment already set is safe.
        registry.grantRole(factory.TRADING_SAFE_FACTORY_ADMIN_ROLE(), DEV_ADMIN);
        registry.grantRole(factory.TRADING_SAFE_REDIRECT_ROLE(), DEV_ADMIN);
        registry.grantRole(lens.ADMIN_ROLE(), DEV_ADMIN);
        registry.grantRole(provider.ADMIN_TIMELOCK_ROLE(), DEV_ADMIN);
        registry.grantRole(PriceProviderV2(priceProviderProxy).ADMIN_TIMELOCK_ROLE(), DEV_ADMIN);
        registry.grantRole(AcrossSwapModule(acrossProxy).ADMIN_TIMELOCK_ROLE(), DEV_ADMIN);
        registry.grantRole(EnsoSwapModule(ensoProxy).ADMIN_TIMELOCK_ROLE(), DEV_ADMIN);

        AcrossSwapModule(acrossProxy).setPeriphery(Prod.ACROSS_PERIPHERY);

        address[] memory modules = new address[](2);
        modules[0] = acrossProxy;
        modules[1] = ensoProxy;
        bool[] memory enable = new bool[](2);
        enable[0] = true;
        enable[1] = true;
        provider.configureDefaultModules(modules, enable);
    }

    /// @dev Repoints the shared TopUp source factory back at the canonical TradingSafeFactory
    ///      (a prior parallel-stack run left it pointing elsewhere) and re-affirms the
    ///      Safe -> TopUp redirect wiring. All setters are idempotent when already correct.
    function _wireTopUp() private {
        TradingSafeFactory factory = TradingSafeFactory(factoryProxy);
        factory.setTopUpFactory(topUpFactory);
        factory.setTradingLens(lensProxy);
        TopUpFactory(payable(topUpFactory)).setTradingSafeFactory(factoryProxy);
        RoleRegistry(topUpRoleRegistry).grantRole(keccak256("TOPUP_FACTORY_REDIRECT_ROLE"), DEV_ADMIN);
    }

    /// @dev Adds the wrapped-xStock trading tokens conditionally; existing entries (including
    ///      any legacy rebasing tokens) are left untouched so safes still holding them keep
    ///      recovery/redirect support until balances are migrated off-chain.
    function _configureSupportedTokens() private {
        TradingLens lens = TradingLens(lensProxy);
        address[] memory tokens = Prod.supportedTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (!lens.isSupportedToken(tokens[i])) lens.addSupportedToken(tokens[i]);
        }
    }

    function _assertConfigured() private view {
        RoleRegistry registry = RoleRegistry(roleRegistryProxy);
        TradingSafeFactory factory = TradingSafeFactory(factoryProxy);
        TradingLens lens = TradingLens(lensProxy);
        EtherFiDataProvider provider = EtherFiDataProvider(dataProviderProxy);
        PriceProviderV2 priceProvider = PriceProviderV2(priceProviderProxy);
        AcrossSwapModule across = AcrossSwapModule(acrossProxy);
        EnsoSwapModule enso = EnsoSwapModule(ensoProxy);

        // Implementations were swapped in place; proxy addresses are unchanged.
        require(_implOf(roleRegistryProxy) == roleRegistryImpl, "RoleRegistry implementation mismatch");
        require(_implOf(priceProviderProxy) == priceProviderImpl, "PriceProvider implementation mismatch");
        require(_implOf(dataProviderProxy) == dataProviderImpl, "DataProvider implementation mismatch");
        require(_implOf(factoryProxy) == factoryImpl, "TradingSafeFactory implementation mismatch");
        require(_implOf(lensProxy) == lensImpl, "TradingLens implementation mismatch");
        require(UpgradeableBeacon(factory.beacon()).implementation() == tradingSafeImpl, "TradingSafe implementation mismatch");

        // Immutable bindings resolve to the canonical proxies.
        require(address(registry.etherFiDataProvider()) == dataProviderProxy, "RoleRegistry data provider binding mismatch");
        require(address(lens.priceProvider()) == priceProviderProxy, "TradingLens price provider binding mismatch");
        require(address(across.etherFiDataProvider()) == dataProviderProxy, "Across data provider binding mismatch");
        require(address(enso.etherFiDataProvider()) == dataProviderProxy, "Enso data provider binding mismatch");
        require(address(across.cashModule()) == address(0), "Across cash module should be unset");
        require(address(enso.cashModule()) == address(0), "Enso cash module should be unset");

        // Preserved identity / configuration on the data provider.
        require(registry.owner() == DEV_ADMIN, "trading RoleRegistry owner mismatch");
        require(provider.getEtherFiSafeFactory() == factoryProxy, "safe factory binding mismatch");
        require(provider.getPriceProvider() == priceProviderProxy, "price provider binding mismatch");
        require(provider.getEtherFiRecoverySigner() == priorRecoverySigner, "recovery signer changed");
        require(provider.getThirdPartyRecoverySigner() == priorThirdPartyRecoverySigner, "third-party recovery signer changed");
        require(provider.getRefundWallet() == priorRefundWallet, "refund wallet changed");

        // TopUp <-> trading wiring restored to the canonical factory.
        require(factory.topUpFactory() == topUpFactory, "factory TopUp link mismatch");
        require(factory.tradingLens() == lensProxy, "factory lens link mismatch");
        require(TopUpFactory(payable(topUpFactory)).tradingSafeFactory() == factoryProxy, "TopUp factory link mismatch");
        require(RoleRegistry(topUpRoleRegistry).hasRole(keccak256("TOPUP_FACTORY_REDIRECT_ROLE"), DEV_ADMIN), "missing TopUp redirect role");

        // Roles.
        require(registry.hasRole(factory.TRADING_SAFE_FACTORY_ADMIN_ROLE(), DEV_ADMIN), "missing factory admin role");
        require(registry.hasRole(factory.TRADING_SAFE_REDIRECT_ROLE(), DEV_ADMIN), "missing trading redirect role");
        require(registry.hasRole(lens.ADMIN_ROLE(), DEV_ADMIN), "missing lens admin role");
        require(registry.hasRole(provider.ADMIN_TIMELOCK_ROLE(), DEV_ADMIN), "missing data provider admin role");
        require(registry.hasRole(priceProvider.ADMIN_TIMELOCK_ROLE(), DEV_ADMIN), "missing price provider admin role");
        require(registry.hasRole(across.ADMIN_TIMELOCK_ROLE(), DEV_ADMIN), "missing Across admin role");
        require(registry.hasRole(enso.ADMIN_TIMELOCK_ROLE(), DEV_ADMIN), "missing Enso admin role");

        // New modules configured and default; init constants pinned.
        require(provider.isDefaultModule(acrossProxy), "new Across not default");
        require(provider.isDefaultModule(ensoProxy), "new Enso not default");
        require(across.getSpokePool() == Prod.ETH_SPOKE_POOL, "Across spoke pool mismatch");
        require(across.getMulticallHandler() == Prod.MULTICALL_HANDLER, "Across multicall handler mismatch");
        require(across.getPeriphery() == Prod.ACROSS_PERIPHERY, "Across periphery mismatch");
        require(enso.getEnsoRouter() == Prod.ENSO_ROUTER, "Enso router mismatch");

        // Supported tokens present; PriceProvider intentionally left without oracles.
        address[] memory tokens = Prod.supportedTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            require(lens.isSupportedToken(tokens[i]), "supported token missing");
            require(priceProvider.tokenConfig(tokens[i]).oracle == address(0), "unexpected oracle");
        }
    }

    function _writeManifest() private {
        string memory key = "trading-account-dev";
        // Canonical proxies (unchanged) recorded as the backend identities.
        vm.serializeAddress(key, "RoleRegistry", roleRegistryProxy);
        vm.serializeAddress(key, "PriceProvider", priceProviderProxy);
        vm.serializeAddress(key, "EtherFiDataProvider", dataProviderProxy);
        vm.serializeAddress(key, "TradingSafeFactory", factoryProxy);
        vm.serializeAddress(key, "TradingLens", lensProxy);
        // New module proxies the backend should route to after cutover.
        vm.serializeAddress(key, "AcrossSwapModule", acrossProxy);
        vm.serializeAddress(key, "EnsoSwapModule", ensoProxy);
        // Freshly deployed implementations for auditing.
        vm.serializeAddress(key, "RoleRegistryImpl", roleRegistryImpl);
        vm.serializeAddress(key, "PriceProviderImpl", priceProviderImpl);
        vm.serializeAddress(key, "EtherFiDataProviderImpl", dataProviderImpl);
        vm.serializeAddress(key, "TradingSafeFactoryImpl", factoryImpl);
        vm.serializeAddress(key, "TradingLensImpl", lensImpl);
        string memory json = vm.serializeAddress(key, "TradingSafeImpl", tradingSafeImpl);
        string memory path = "./deployments/dev/1/trading-account.json";
        vm.writeJson(json, path);
        console2.log("Wrote", path);
    }

    function _readTradingManifest() private view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/deployments/dev/1/trading-account.json"));
    }

    function _implOf(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
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

    function _deploy(string memory saltName, bytes memory creationCode, bytes memory constructorArgs) private returns (address) {
        return DEPLOYER.deploy(getSalt(saltName), abi.encodePacked(creationCode, constructorArgs));
    }

    function _deployProxy(string memory saltName, address implementation, bytes memory initData) private returns (address) {
        return _deploy(saltName, type(UUPSProxy).creationCode, abi.encode(implementation, initData));
    }
}
