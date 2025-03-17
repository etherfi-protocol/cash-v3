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

    string internal TOP_UP_SOURCE_FACTORY_PROXY = "Dev1:TopUpSourceFactoryProxy";
    string internal TOP_UP_SOURCE_FACTORY_IMPL = "Dev1:TopUpSourceFactoryImpl";
    string internal TOP_UP_SOURCE_IMPL = "Dev1:TopUpSourceImpl";
    string internal ROLE_REGISTRY_PROXY = "Dev1:RoleRegistryProxy";
    string internal ROLE_REGISTRY_IMPL = "Dev1:RoleRegistryImpl";
    string internal ETHER_FI_OFT_BRIDGE_ADAPTER = "Dev1:EtherFiOFTBridgeAdapter";
    string internal STARGATE_ADAPTER = "Dev1:StargateAdapter";

    string internal ETHER_FI_SAFE_IMPL = "Dev1:EtherFiSafeImpl";
    string internal ETHER_FI_SAFE_FACTORY_IMPL = TOP_UP_SOURCE_FACTORY_IMPL;
    string internal ETHER_FI_SAFE_FACTORY_PROXY = TOP_UP_SOURCE_FACTORY_PROXY;
    string internal ETHER_FI_DATA_PROVIDER_IMPL = "Dev1:EtherFiDataProviderImpl";
    string internal ETHER_FI_DATA_PROVIDER_PROXY = "Dev1:EtherFiDataProviderProxy";
    string internal ETHER_FI_HOOK_IMPL = "Dev1:EtherFiHookImpl";
    string internal ETHER_FI_HOOK_PROXY = "Dev1:EtherFiHookProxy";
    string internal TOP_UP_DEST_IMPL = "Dev1:TopUpDestImpl";
    string internal TOP_UP_DEST_PROXY = "Dev1:TopUpDestProxy";
    string internal AAVE_MODULE = "Dev1:AaveV3Module";
    string internal CASH_MODULE_SETTERS_IMPL = "Dev1:CashModuleSettersImpl";
    string internal CASH_MODULE_CORE_IMPL = "Dev1:CashModuleCoreImpl";
    string internal CASH_MODULE_PROXY = "Dev1:CashModuleProxy";
    string internal CASH_LENS_IMPL = "Dev1:CashLensImpl";
    string internal CASH_LENS_PROXY = "Dev1:CashLensProxy";
    string internal OPEN_OCEAN_SWAP_MODULE = "Dev1:OpenOceanSwapModule";

    string internal CASH_EVENT_EMITTER_IMPL = "Dev1:CashEventEmitterImpl";
    string internal CASH_EVENT_EMITTER_PROXY = "Dev1:CashEventEmitterProxy";
    string internal PRICE_PROVIDER_IMPL = "Dev1:PriceProviderImpl";
    string internal PRICE_PROVIDER_PROXY = "Dev1:PriceProviderProxy";
    string internal CASHBACK_DISPATCHER_IMPL = "Dev1:CashbackDispatcherImpl";
    string internal CASHBACK_DISPATCHER_PROXY = "Dev1:CashbackDispatcherProxy";
    string internal SETTLEMENT_DISPATCHER_IMPL = "Dev1:SettlementDispatcherImpl";
    string internal SETTLEMENT_DISPATCHER_PROXY = "Dev1:SettlementDispatcherProxy";
    string internal DEBT_MANAGER_ADMIN_IMPL = "Dev1:DebtManagerAdminImpl";
    string internal DEBT_MANAGER_CORE_IMPL = "Dev1:DebtManagerCoreImpl";
    string internal DEBT_MANAGER_INITIALIZER_IMPL = "Dev1:DebtManagerInitializerImpl";
    string internal DEBT_MANAGER_PROXY = "Dev1:DebtManagerProxy";

    function getChainConfig(
        string memory chainId
    ) internal view returns (ChainConfig memory) {
        string memory file = string.concat(vm.projectRoot(), "/deployments/fixtures/fixtures.json");
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
        string memory dir = string.concat(vm.projectRoot(), "/deployments/");
        string memory chainDir = string.concat(vm.toString(block.chainid), "/");
        string memory file = string.concat("deployments", ".json");
        return vm.readFile(string.concat(dir, chainDir, file));
    }

    function writeDeploymentFile(string memory output) internal {
        string memory dir = string.concat(vm.projectRoot(), "/deployments/");
        string memory chainDir = string.concat(vm.toString(block.chainid), "/");
        string memory file = string.concat("deployments", ".json");
        vm.writeJson(output, string.concat(dir, chainDir, file));
    }

    function writeUserSafeDeploymentFile(string memory output) internal {
        string memory dir = string.concat(vm.projectRoot(), "/deployments/");
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
}