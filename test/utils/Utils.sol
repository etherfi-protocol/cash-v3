// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

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

contract Utils is Test {
    uint256 public constant HUNDRED_PERCENT = 100e18;
    uint256 public constant HUNDRED_PERCENT_IN_BPS = 10000;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant SIX_DECIMALS = 1e6;
    address eth = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    string scrollChainId = "534352";
    
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
