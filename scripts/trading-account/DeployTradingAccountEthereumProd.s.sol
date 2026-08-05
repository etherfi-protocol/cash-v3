// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
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
import { TradingAccountCreate3, TradingAccountProdConfig as C } from "./TradingAccountProdConfig.sol";

/// @notice Permissionlessly predeploys the Ethereum production trading stack via Nick's CREATE3 factory.
/// @dev This script only deploys and atomically initializes new proxies. Run the separate Gnosis script
///      to upgrade the existing TopUp stack and perform all privileged configuration.
contract DeployTradingAccountEthereumProd is Script, TradingAccountCreate3 {
    address private dataProviderProxy;
    address private factoryProxy;
    address private acrossProxy;
    address private ensoProxy;
    address private roleRegistryImpl;
    address private roleRegistryProxy;
    address private priceProviderImpl;
    address private priceProviderProxy;
    address private tradingSafeImpl;
    address private factoryImpl;
    address private lensImpl;
    address private lensProxy;
    address private dataProviderImpl;
    address private acrossImpl;
    address private ensoImpl;
    address private topUpFactoryImpl;
    address private topUpImpl;

    function run() external {
        require(block.chainid == 1, "must run on Ethereum");
        require(C.NICKS_FACTORY.code.length > 0, "Nick's factory not deployed");

        dataProviderProxy = _predict(C.SALT_DATA_PROVIDER_PROXY);
        factoryProxy = _predict(C.SALT_TRADING_SAFE_FACTORY_PROXY);
        acrossProxy = _predict(C.SALT_ACROSS_PROXY);
        ensoProxy = _predict(C.SALT_ENSO_PROXY);

        vm.startBroadcast();
        _deployCore();
        _deployFactoryAndLens();
        _deployDataProviderAndModules();
        _deployTopUpImplementations();
        vm.stopBroadcast();

        _writeManifest();
    }

    function _deployCore() private {
        roleRegistryImpl = _deployCreate3(abi.encodePacked(type(RoleRegistry).creationCode, abi.encode(dataProviderProxy)), C.SALT_ROLE_REGISTRY_IMPL);
        roleRegistryProxy = _deployProxy(C.SALT_ROLE_REGISTRY_PROXY, roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, C.OPERATING_SAFE));

        priceProviderImpl = _deployCreate3(type(PriceProviderV2).creationCode, C.SALT_PRICE_PROVIDER_IMPL);
        address[] memory noTokens = new address[](0);
        PriceProviderV2.Config[] memory noConfigs = new PriceProviderV2.Config[](0);
        priceProviderProxy = _deployProxy(C.SALT_PRICE_PROVIDER_PROXY, priceProviderImpl, abi.encodeWithSelector(PriceProviderV2.initialize.selector, roleRegistryProxy, noTokens, noConfigs));
    }

    function _deployFactoryAndLens() private {
        tradingSafeImpl = _deployCreate3(abi.encodePacked(type(TradingSafe).creationCode, abi.encode(dataProviderProxy)), C.SALT_TRADING_SAFE_IMPL);
        factoryImpl = _deployCreate3(type(TradingSafeFactory).creationCode, C.SALT_TRADING_SAFE_FACTORY_IMPL);
        address deployedFactoryProxy = _deployProxy(C.SALT_TRADING_SAFE_FACTORY_PROXY, factoryImpl, abi.encodeWithSelector(TradingSafeFactory.initialize.selector, roleRegistryProxy, tradingSafeImpl));
        require(deployedFactoryProxy == factoryProxy, "factory prediction mismatch");

        lensImpl = _deployCreate3(abi.encodePacked(type(TradingLens).creationCode, abi.encode(priceProviderProxy)), C.SALT_TRADING_LENS_IMPL);
        lensProxy = _deployProxy(C.SALT_TRADING_LENS_PROXY, lensImpl, abi.encodeWithSelector(TradingLens.initialize.selector, roleRegistryProxy));
    }

    function _deployDataProviderAndModules() private {
        dataProviderImpl = _deployCreate3(type(EtherFiDataProvider).creationCode, C.SALT_DATA_PROVIDER_IMPL);
        address[] memory modules = new address[](2);
        modules[0] = acrossProxy;
        modules[1] = ensoProxy;
        address deployedDataProviderProxy = _deployProxy(
            C.SALT_DATA_PROVIDER_PROXY,
            dataProviderImpl,
            abi.encodeWithSelector(EtherFiDataProvider.initialize.selector, EtherFiDataProvider.InitParams({ _roleRegistry: roleRegistryProxy, _cashModule: address(0), _cashLens: address(0), _modules: modules, _defaultModules: modules, _hook: address(0), _etherFiSafeFactory: factoryProxy, _priceProvider: priceProviderProxy, _etherFiRecoverySigner: C.ETHERFI_RECOVERY_SIGNER, _thirdPartyRecoverySigner: C.THIRD_PARTY_RECOVERY_SIGNER, _refundWallet: C.REFUND_WALLET }))
        );
        require(deployedDataProviderProxy == dataProviderProxy, "data provider prediction mismatch");

        acrossImpl = _deployCreate3(abi.encodePacked(type(AcrossSwapModule).creationCode, abi.encode(dataProviderProxy)), C.SALT_ACROSS_IMPL);
        address deployedAcrossProxy = _deployProxy(C.SALT_ACROSS_PROXY, acrossImpl, abi.encodeWithSelector(AcrossSwapModule.initialize.selector, roleRegistryProxy, C.ETH_SPOKE_POOL, C.MULTICALL_HANDLER));
        require(deployedAcrossProxy == acrossProxy, "Across prediction mismatch");

        ensoImpl = _deployCreate3(abi.encodePacked(type(EnsoSwapModule).creationCode, abi.encode(dataProviderProxy)), C.SALT_ENSO_IMPL);
        address deployedEnsoProxy = _deployProxy(C.SALT_ENSO_PROXY, ensoImpl, abi.encodeWithSelector(EnsoSwapModule.initialize.selector, roleRegistryProxy, C.ENSO_ROUTER));
        require(deployedEnsoProxy == ensoProxy, "Enso prediction mismatch");
    }

    function _deployTopUpImplementations() private {
        topUpFactoryImpl = _deployCreate3(type(TopUpFactory).creationCode, C.SALT_TOPUP_FACTORY_IMPL);
        topUpImpl = _deployCreate3(abi.encodePacked(type(TopUp).creationCode, abi.encode(C.ETH_WETH)), C.SALT_TOPUP_IMPL);
    }

    function _deployProxy(bytes32 salt, address implementation, bytes memory initData) private returns (address) {
        return _deployCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(implementation, initData)), salt);
    }

    function _writeManifest() private {
        string memory key = "trading-account-prod";
        vm.serializeAddress(key, "RoleRegistryImpl", roleRegistryImpl);
        vm.serializeAddress(key, "RoleRegistry", roleRegistryProxy);
        vm.serializeAddress(key, "PriceProviderImpl", priceProviderImpl);
        vm.serializeAddress(key, "PriceProvider", priceProviderProxy);
        vm.serializeAddress(key, "TradingSafeImpl", tradingSafeImpl);
        vm.serializeAddress(key, "TradingSafeFactoryImpl", factoryImpl);
        vm.serializeAddress(key, "TradingSafeFactory", factoryProxy);
        vm.serializeAddress(key, "TradingLensImpl", lensImpl);
        vm.serializeAddress(key, "TradingLens", lensProxy);
        vm.serializeAddress(key, "EtherFiDataProviderImpl", dataProviderImpl);
        vm.serializeAddress(key, "EtherFiDataProvider", dataProviderProxy);
        vm.serializeAddress(key, "AcrossSwapModuleImpl", acrossImpl);
        vm.serializeAddress(key, "AcrossSwapModule", acrossProxy);
        vm.serializeAddress(key, "EnsoSwapModuleImpl", ensoImpl);
        vm.serializeAddress(key, "EnsoSwapModule", ensoProxy);
        vm.serializeAddress(key, "TopUpFactoryImpl", topUpFactoryImpl);
        string memory json = vm.serializeAddress(key, "TopUpImpl", topUpImpl);

        string memory path = "./deployments/mainnet/1/trading-account.json";
        vm.writeJson(json, path);
        console2.log("Wrote", path);
    }
}
