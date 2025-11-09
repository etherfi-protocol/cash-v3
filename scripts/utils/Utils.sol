// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

struct ChainConfig {
    address owner;
    string rpc;
    address usdc;
    address weETH;
    address scr;
    address weth;
    address weEthWethOracle;
    address ethUsdcOracle;
    address scrUsdOracle;
    address usdcUsdOracle;
    address swapRouterOpenOcean;
    address aaveV3Pool;
    address aaveV3PoolDataProvider;
    address stargateUsdcPool;
}

contract Utils is Script {
    address eth = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    string scrollChainId = "534352";
    string mainnetChainId = "1";

    string internal TOP_UP_SOURCE_FACTORY_PROXY = "TopUpSourceFactoryProxy";
    string internal TOP_UP_SOURCE_FACTORY_IMPL = "TopUpSourceFactoryImpl";
    string internal TOP_UP_SOURCE_FACTORY_PROXY_DEV = "TopUpSourceFactoryProxyDev";
    string internal TOP_UP_SOURCE_FACTORY_IMPL_DEV = "TopUpSourceFactoryImplDev";
    string internal TOP_UP_SOURCE_IMPL = "TopUpSourceImpl";
    string internal TOP_UP_SOURCE_IMPL_DEV = "TopUpSourceImplDev";
    string internal ROLE_REGISTRY_PROXY = "RoleRegistryProxy";
    string internal ROLE_REGISTRY_PROXY_DEV = "RoleRegistryProxyDev";
    string internal ROLE_REGISTRY_IMPL = "RoleRegistryImpl";
    string internal ROLE_REGISTRY_IMPL_DEV = "RoleRegistryImplDev";
    string internal ETHER_FI_OFT_BRIDGE_ADAPTER = "EtherFiOFTBridgeAdapter";
    string internal ETHER_FI_OFT_BRIDGE_ADAPTER_DEV = "EtherFiOFTBridgeAdapterDev";
    string internal ETHER_FI_OFT_BRIDGE_ADAPTER_MAINNET = "EtherFiOFTBridgeAdapterMainnet";
    string internal ETHER_FI_OFT_BRIDGE_ADAPTER_MAINNET_DEV = "EtherFiOFTBridgeAdapterMainnetDev";
    string internal ETHER_FI_LIQUID_BRIDGE_ADAPTER = "EtherFiLiquidBridgeAdapter";
    string internal STARGATE_ADAPTER = "StargateAdapter";
    string internal NTT_ADAPTER = "NTTAdapterSalt";
    string internal CCTP_ADAPTER = "CCTPAdapter";
    string internal CCTP_ADAPTER_DEV = "CCTPAdapterDev";
    string internal SCROLL_ERC20_BRIDGE_ADAPTER_DEV = "ScrollERC20BridgeAdapterDev";
    string internal SCROLL_ERC20_BRIDGE_ADAPTER_PROD = "ScrollERC20BridgeAdapterProd";
    string internal BASE_WITHDRAW_ERC20_BRIDGE_ADAPTER = "BaseWithdrawERC20BridgeAdapter";
    string internal BASE_WITHDRAW_ERC20_BRIDGE_ADAPTER_DEV = "BaseWithdrawERC20BridgeAdapterDev";

    string internal ETHER_FI_SAFE_IMPL = "EtherFiSafeImpl";
    string internal ETHER_FI_SAFE_FACTORY_IMPL = TOP_UP_SOURCE_FACTORY_IMPL;
    string internal ETHER_FI_SAFE_FACTORY_PROXY = TOP_UP_SOURCE_FACTORY_PROXY;
    string internal ETHER_FI_DATA_PROVIDER_IMPL = "EtherFiDataProviderImpl";
    string internal ETHER_FI_DATA_PROVIDER_PROXY = "EtherFiDataProviderProxy";
    string internal ETHER_FI_HOOK_IMPL = "EtherFiHookImpl";
    string internal ETHER_FI_HOOK_PROXY = "EtherFiHookProxy";
    string internal TOP_UP_DEST_IMPL = "TopUpDestImpl";
    string internal TOP_UP_DEST_PROXY = "TopUpDestProxy";
    string internal AAVE_MODULE = "AaveV3Module";
    string internal CASH_MODULE_SETTERS_IMPL = "CashModuleSettersImpl";
    string internal CASH_MODULE_CORE_IMPL = "CashModuleCoreImpl";
    string internal CASH_MODULE_PROXY = "CashModuleProxy";
    string internal CASH_LENS_IMPL = "CashLensImpl";
    string internal CASH_LENS_PROXY = "CashLensProxy";
    string internal OPEN_OCEAN_SWAP_MODULE = "OpenOceanSwapModule";

    string internal CASH_EVENT_EMITTER_IMPL = "CashEventEmitterImpl";
    string internal CASH_EVENT_EMITTER_PROXY = "CashEventEmitterProxy";
    string internal PRICE_PROVIDER_IMPL = "PriceProviderImpl";
    string internal PRICE_PROVIDER_PROXY = "PriceProviderProxy";
    string internal CASHBACK_DISPATCHER_IMPL = "CashbackDispatcherImpl";
    string internal CASHBACK_DISPATCHER_PROXY = "CashbackDispatcherProxy";
    string internal SETTLEMENT_DISPATCHER_IMPL = "SettlementDispatcherImpl";
    string internal SETTLEMENT_DISPATCHER_PROXY = "SettlementDispatcherProxy";
    string internal SETTLEMENT_DISPATCHER_RAIN_IMPL = "ProdSettlementDispatcherRainImpl";
    string internal SETTLEMENT_DISPATCHER_RAIN_PROXY = "ProdSettlementDispatcherRainProxy";
    string internal DEBT_MANAGER_ADMIN_IMPL = "DebtManagerAdminImpl";
    string internal DEBT_MANAGER_CORE_IMPL = "DebtManagerCoreImpl";
    string internal DEBT_MANAGER_INITIALIZER_IMPL = "DebtManagerInitializerImpl";
    string internal DEBT_MANAGER_PROXY = "DebtManagerProxy";

    function getChainConfig(
        string memory chainId
    ) internal view returns (ChainConfig memory) {
        string memory file = string.concat(vm.projectRoot(), string(abi.encodePacked("/deployments/", getEnv(), "/fixtures/fixtures.json")));
        string memory inputJson = vm.readFile(file);

        ChainConfig memory config;

        config.owner = stdJson.readAddress(
            inputJson,
            string.concat(".", chainId, ".", "owner")
        );

        config.rpc = stdJson.readString(
            inputJson,
            string.concat(".", chainId, ".", "rpc")
        );

        config.usdc = stdJson.readAddress(
            inputJson,
            string.concat(".", chainId, ".", "usdc")
        );

        config.weETH = stdJson.readAddress(
            inputJson,
            string.concat(".", chainId, ".", "weETH")
        );

        config.scr = stdJson.readAddress(
            inputJson,
            string.concat(".", chainId, ".", "scr")
        );

        config.weth = stdJson.readAddress(
            inputJson,
            string.concat(".", chainId, ".", "weth")
        );

        config.scr = stdJson.readAddress(
            inputJson,
            string.concat(".", chainId, ".", "scr")
        );

        config.weEthWethOracle = stdJson.readAddress(
            inputJson,
            string.concat(".", chainId, ".", "weEthWethOracle")
        );

        config.ethUsdcOracle = stdJson.readAddress(
            inputJson,
            string.concat(".", chainId, ".", "ethUsdcOracle")
        );

        config.scrUsdOracle = stdJson.readAddress(
            inputJson,
            string.concat(".", chainId, ".", "scrUsdOracle")
        );

        config.usdcUsdOracle = stdJson.readAddress(
            inputJson,
            string.concat(".", chainId, ".", "usdcUsdOracle")
        );

        config.usdcUsdOracle = stdJson.readAddress(
            inputJson,
            string.concat(".", chainId, ".", "usdcUsdOracle")
        );

        config.swapRouterOpenOcean = stdJson.readAddress(
            inputJson,
            string.concat(".", chainId, ".", "swapRouterOpenOcean")
        );

        config.aaveV3Pool = stdJson.readAddress(
            inputJson,
            string.concat(".", chainId, ".", "aaveV3Pool")
        );

        config.aaveV3PoolDataProvider = stdJson.readAddress(
            inputJson,
            string.concat(".", chainId, ".", "aaveV3PoolDataProvider")
        );

        config.stargateUsdcPool = stdJson.readAddress(
            inputJson,
            string.concat(".", chainId, ".", "stargateUsdcPool")
        );

        return config;
    }

    function readDeploymentFile() internal view returns (string memory) {
        string memory dir = string.concat(vm.projectRoot(), string(abi.encodePacked("/deployments/", getEnv(), "/")));
        string memory chainDir = string.concat(vm.toString(block.chainid), "/");
        string memory file = string.concat("deployments", ".json");
        return vm.readFile(string.concat(dir, chainDir, file));
    }

    function readTopUpSourceDeployment() internal view returns (string memory) {
        string memory dir = string.concat(vm.projectRoot(), string(abi.encodePacked("/deployments/", getEnv(), "/")));
        string memory chainDir = string.concat(vm.toString(block.chainid), "/");
        string memory file = string.concat(dir, chainDir, "deployments", ".json");
        string memory deployments = vm.readFile(file);

        return deployments;
    }

    function writeDeploymentFile(string memory output) internal {
        string memory dir = string.concat(vm.projectRoot(), string(abi.encodePacked("/deployments/", getEnv(), "/")));
        string memory chainDir = string.concat(vm.toString(block.chainid), "/");
        string memory file = string.concat("deployments", ".json");
        vm.writeJson(output, string.concat(dir, chainDir, file));
    }

    function writeUserSafeDeploymentFile(string memory output) internal {
        string memory dir = string.concat(vm.projectRoot(), string(abi.encodePacked("/deployments/", getEnv(), "/")));
        string memory chainDir = string.concat(vm.toString(block.chainid), "/");
        string memory file = string.concat("safe", ".json");
        vm.writeJson(output, string.concat(dir, chainDir, file));
    }

    function isFork(string memory chainId) internal pure returns (bool) {
        if (keccak256(bytes(chainId)) == keccak256(bytes("local"))) return false;
        else return true;
    }

    function getSalt(string memory contractName) internal pure returns (bytes32) {
        return keccak256(bytes(contractName));
    }


    function deployWithCreate3(bytes memory creationCode, bytes32 salt) internal returns (address) {
        return CREATE3.deployDeterministic(creationCode, salt);
    }

    function getEnv() internal view returns (string memory) {
        try vm.envString("ENV") returns (string memory env) {
            if (bytes(env).length == 0) env = "mainnet";
            if (!isEqualString(env, "mainnet") && !isEqualString(env, "dev")) revert ("ENV can only be \"mainnet\" or \"dev\"");
            return env;
        } catch {
            return "mainnet";
        }

    }

    function isEqualString(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
