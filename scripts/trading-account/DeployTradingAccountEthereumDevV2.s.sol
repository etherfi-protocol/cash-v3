// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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

/// @notice Fresh DevV2 deployment and configuration of the Ethereum trading-account stack.
/// @dev With PRIVATE_KEY unset, fork simulations impersonate DEV_ADMIN. Real broadcasts must
///      provide the corresponding private key.
contract DeployTradingAccountEthereumDevV2 is Utils {
    using stdJson for string;

    EtherFiDeployer private constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);
    address private constant DEV_ADMIN = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;
    address private constant DEV_RECOVERY_SIGNER = 0x7fEd99d0aA90423de55e238Eb5F9416FF7Cc58eF;
    address private constant DEV_THIRD_PARTY_RECOVERY_SIGNER = 0x24e311DA50784Cf9DB1abE59725e4A1A110220FA;
    bytes32 private constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address private dataProviderProxy;
    address private factoryProxy;
    address private acrossProxy;
    address private ensoProxy;
    address private roleRegistryProxy;
    address private priceProviderProxy;
    address private tradingSafeImpl;
    address private lensProxy;
    address private topUpFactory;
    address private topUpFactoryImpl;
    address private topUpImpl;

    function run() external {
        require(block.chainid == 1, "must run on Ethereum");
        require(DEPLOYER.isDeployer(DEV_ADMIN), "dev admin is not an EtherFiDeployer");

        dataProviderProxy = _predict("TradingAccount.DevV2.DataProviderProxy");
        factoryProxy = _predict("TradingAccount.DevV2.TradingSafeFactoryProxy");
        acrossProxy = _predict("TradingAccount.DevV2.AcrossSwapModuleProxy");
        ensoProxy = _predict("TradingAccount.DevV2.EnsoSwapModuleProxy");

        string memory topUpDeployments = readTopUpSourceDeployment();
        topUpFactory = topUpDeployments.readAddress(".addresses.TopUpSourceFactory");
        address topUpRoleRegistry = topUpDeployments.readAddress(".addresses.RoleRegistry");

        _startBroadcast();
        _deployCore();
        _deployFactoryAndLens();
        _deployDataProviderAndModules();
        _upgradeAndWireTopUp(topUpRoleRegistry);
        _configureTradingStack();
        vm.stopBroadcast();

        _assertConfigured(topUpRoleRegistry);
        _writeManifest();
    }

    function _deployCore() private {
        address roleRegistryImpl = _deploy("TradingAccount.DevV2.RoleRegistryImpl", type(RoleRegistry).creationCode, abi.encode(dataProviderProxy));
        roleRegistryProxy = _deployProxy("TradingAccount.DevV2.RoleRegistryProxy", roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, DEV_ADMIN));

        address priceProviderImpl = _deploy("TradingAccount.DevV2.PriceProviderImpl", type(PriceProviderV2).creationCode, "");
        address[] memory noTokens = new address[](0);
        PriceProviderV2.Config[] memory noConfigs = new PriceProviderV2.Config[](0);
        priceProviderProxy = _deployProxy("TradingAccount.DevV2.PriceProviderProxy", priceProviderImpl, abi.encodeWithSelector(PriceProviderV2.initialize.selector, roleRegistryProxy, noTokens, noConfigs));
    }

    function _deployFactoryAndLens() private {
        tradingSafeImpl = _deploy("TradingAccount.DevV2.TradingSafeImpl", type(TradingSafe).creationCode, abi.encode(dataProviderProxy));
        address factoryImpl = _deploy("TradingAccount.DevV2.TradingSafeFactoryImpl", type(TradingSafeFactory).creationCode, "");
        require(_deployProxy("TradingAccount.DevV2.TradingSafeFactoryProxy", factoryImpl, abi.encodeWithSelector(TradingSafeFactory.initialize.selector, roleRegistryProxy, tradingSafeImpl)) == factoryProxy, "factory prediction mismatch");

        address lensImpl = _deploy("TradingAccount.DevV2.TradingLensImpl", type(TradingLens).creationCode, abi.encode(priceProviderProxy));
        lensProxy = _deployProxy("TradingAccount.DevV2.TradingLensProxy", lensImpl, abi.encodeWithSelector(TradingLens.initialize.selector, roleRegistryProxy));
    }

    function _deployDataProviderAndModules() private {
        address[] memory modules = new address[](2);
        modules[0] = acrossProxy;
        modules[1] = ensoProxy;

        address dataProviderImpl = _deploy("TradingAccount.DevV2.DataProviderImpl", type(EtherFiDataProvider).creationCode, "");
        require(
            _deployProxy(
                "TradingAccount.DevV2.DataProviderProxy",
                dataProviderImpl,
                abi.encodeWithSelector(EtherFiDataProvider.initialize.selector, EtherFiDataProvider.InitParams({ _roleRegistry: roleRegistryProxy, _cashModule: address(0), _cashLens: address(0), _modules: modules, _defaultModules: modules, _hook: address(0), _etherFiSafeFactory: factoryProxy, _priceProvider: priceProviderProxy, _etherFiRecoverySigner: DEV_RECOVERY_SIGNER, _thirdPartyRecoverySigner: DEV_THIRD_PARTY_RECOVERY_SIGNER, _refundWallet: DEV_ADMIN }))
            ) == dataProviderProxy,
            "data provider prediction mismatch"
        );

        address acrossImpl = _deploy("TradingAccount.DevV2.AcrossSwapModuleImpl", type(AcrossSwapModule).creationCode, abi.encode(dataProviderProxy));
        require(_deployProxy("TradingAccount.DevV2.AcrossSwapModuleProxy", acrossImpl, abi.encodeWithSelector(AcrossSwapModule.initialize.selector, roleRegistryProxy, Prod.ETH_SPOKE_POOL, Prod.MULTICALL_HANDLER)) == acrossProxy, "Across prediction mismatch");

        address ensoImpl = _deploy("TradingAccount.DevV2.EnsoSwapModuleImpl", type(EnsoSwapModule).creationCode, abi.encode(dataProviderProxy));
        require(_deployProxy("TradingAccount.DevV2.EnsoSwapModuleProxy", ensoImpl, abi.encodeWithSelector(EnsoSwapModule.initialize.selector, roleRegistryProxy, Prod.ENSO_ROUTER)) == ensoProxy, "Enso prediction mismatch");
    }

    function _upgradeAndWireTopUp(address topUpRoleRegistry) private {
        topUpFactoryImpl = _deploy("TradingAccount.DevV2.TopUpFactoryImpl", type(TopUpFactory).creationCode, "");
        topUpImpl = _deploy("TradingAccount.DevV2.TopUpImpl", type(TopUp).creationCode, abi.encode(Prod.ETH_WETH));

        TopUpFactory(payable(topUpFactory)).upgradeToAndCall(topUpFactoryImpl, "");
        TopUpFactory(payable(topUpFactory)).upgradeBeaconImplementation(topUpImpl);
        TopUpFactory(payable(topUpFactory)).setTradingSafeFactory(factoryProxy);
        RoleRegistry(topUpRoleRegistry).grantRole(keccak256("TOPUP_FACTORY_REDIRECT_ROLE"), DEV_ADMIN);
    }

    function _configureTradingStack() private {
        RoleRegistry registry = RoleRegistry(roleRegistryProxy);
        TradingSafeFactory factory = TradingSafeFactory(factoryProxy);
        TradingLens lens = TradingLens(lensProxy);

        registry.grantRole(factory.TRADING_SAFE_FACTORY_ADMIN_ROLE(), DEV_ADMIN);
        registry.grantRole(factory.TRADING_SAFE_REDIRECT_ROLE(), DEV_ADMIN);
        registry.grantRole(lens.TRADING_LENS_ADMIN_ROLE(), DEV_ADMIN);
        registry.grantRole(EtherFiDataProvider(dataProviderProxy).DATA_PROVIDER_ADMIN_ROLE(), DEV_ADMIN);
        registry.grantRole(PriceProviderV2(priceProviderProxy).PRICE_PROVIDER_ADMIN_ROLE(), DEV_ADMIN);
        registry.grantRole(AcrossSwapModule(acrossProxy).ACROSS_SWAP_MODULE_ADMIN_ROLE(), DEV_ADMIN);
        registry.grantRole(EnsoSwapModule(ensoProxy).ENSO_SWAP_MODULE_ADMIN_ROLE(), DEV_ADMIN);

        AcrossSwapModule(acrossProxy).setPeriphery(Prod.ACROSS_PERIPHERY);
        factory.setTopUpFactory(topUpFactory);
        factory.setTradingLens(lensProxy);

        address[] memory tokens = Prod.supportedTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            lens.addSupportedToken(tokens[i]);
        }
    }

    function _assertConfigured(address topUpRoleRegistry) private view {
        RoleRegistry registry = RoleRegistry(roleRegistryProxy);
        TradingSafeFactory factory = TradingSafeFactory(factoryProxy);
        TradingLens lens = TradingLens(lensProxy);
        EtherFiDataProvider provider = EtherFiDataProvider(dataProviderProxy);
        PriceProviderV2 priceProvider = PriceProviderV2(priceProviderProxy);
        AcrossSwapModule across = AcrossSwapModule(acrossProxy);
        EnsoSwapModule enso = EnsoSwapModule(ensoProxy);

        require(registry.owner() == DEV_ADMIN, "trading RoleRegistry owner mismatch");
        require(address(uint160(uint256(vm.load(topUpFactory, EIP1967_IMPL_SLOT)))) == topUpFactoryImpl, "TopUpFactory implementation mismatch");
        address beacon = TopUpFactory(payable(topUpFactory)).beacon();
        require(UpgradeableBeacon(beacon).implementation() == topUpImpl, "TopUp implementation mismatch");
        require(TopUpFactory(payable(topUpFactory)).tradingSafeFactory() == factoryProxy, "TopUp factory link mismatch");
        require(factory.topUpFactory() == topUpFactory, "trading factory TopUp link mismatch");
        require(factory.tradingLens() == lensProxy, "trading lens link mismatch");
        require(UpgradeableBeacon(factory.beacon()).implementation() == tradingSafeImpl, "TradingSafe implementation mismatch");
        require(RoleRegistry(topUpRoleRegistry).hasRole(keccak256("TOPUP_FACTORY_REDIRECT_ROLE"), DEV_ADMIN), "missing TopUp redirect role");
        require(registry.hasRole(factory.TRADING_SAFE_FACTORY_ADMIN_ROLE(), DEV_ADMIN), "missing factory role");
        require(registry.hasRole(factory.TRADING_SAFE_REDIRECT_ROLE(), DEV_ADMIN), "missing trading redirect role");
        require(registry.hasRole(lens.TRADING_LENS_ADMIN_ROLE(), DEV_ADMIN), "missing lens admin role");
        require(registry.hasRole(provider.DATA_PROVIDER_ADMIN_ROLE(), DEV_ADMIN), "missing data provider admin role");
        require(registry.hasRole(priceProvider.PRICE_PROVIDER_ADMIN_ROLE(), DEV_ADMIN), "missing price provider admin role");
        require(registry.hasRole(across.ACROSS_SWAP_MODULE_ADMIN_ROLE(), DEV_ADMIN), "missing Across admin role");
        require(registry.hasRole(enso.ENSO_SWAP_MODULE_ADMIN_ROLE(), DEV_ADMIN), "missing Enso admin role");
        require(provider.isDefaultModule(acrossProxy), "Across not default");
        require(provider.isDefaultModule(ensoProxy), "Enso not default");
        require(provider.getEtherFiSafeFactory() == factoryProxy, "safe factory mismatch");
        require(provider.getPriceProvider() == priceProviderProxy, "price provider mismatch");
        require(provider.getEtherFiRecoverySigner() == DEV_RECOVERY_SIGNER, "recovery signer mismatch");
        require(provider.getThirdPartyRecoverySigner() == DEV_THIRD_PARTY_RECOVERY_SIGNER, "third-party recovery signer mismatch");
        require(provider.getRefundWallet() == DEV_ADMIN, "refund wallet mismatch");
        require(across.getPeriphery() == Prod.ACROSS_PERIPHERY, "Across periphery mismatch");

        address[] memory tokens = Prod.supportedTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            require(lens.isSupportedToken(tokens[i]), "supported token missing");
            require(priceProvider.tokenConfig(tokens[i]).oracle == address(0), "unexpected oracle");
        }
    }

    function _writeManifest() private {
        string memory key = "trading-account-dev-v2";
        vm.serializeAddress(key, "RoleRegistry", roleRegistryProxy);
        vm.serializeAddress(key, "PriceProvider", priceProviderProxy);
        vm.serializeAddress(key, "TradingSafeImpl", tradingSafeImpl);
        vm.serializeAddress(key, "TradingSafeFactory", factoryProxy);
        vm.serializeAddress(key, "TradingLens", lensProxy);
        vm.serializeAddress(key, "EtherFiDataProvider", dataProviderProxy);
        vm.serializeAddress(key, "AcrossSwapModule", acrossProxy);
        vm.serializeAddress(key, "EnsoSwapModule", ensoProxy);
        vm.serializeAddress(key, "TopUpFactoryImpl", topUpFactoryImpl);
        string memory json = vm.serializeAddress(key, "TopUpImpl", topUpImpl);
        string memory path = "./deployments/dev/1/trading-account-v2.json";
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

    function _predict(string memory saltName) private view returns (address) {
        return DEPLOYER.getDeterministicAddress(getSalt(saltName));
    }

    function _deploy(string memory saltName, bytes memory creationCode, bytes memory constructorArgs) private returns (address) {
        return DEPLOYER.deploy(getSalt(saltName), abi.encodePacked(creationCode, constructorArgs));
    }

    function _deployProxy(string memory saltName, address implementation, bytes memory initData) private returns (address) {
        return _deploy(saltName, type(UUPSProxy).creationCode, abi.encode(implementation, initData));
    }
}
