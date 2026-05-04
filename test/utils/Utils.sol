// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

struct ChainConfig {
    // Core (required)
    address owner;
    string rpc;
    address usdc;
    address usdt;
    address weETH;
    address weth;
    // Oracles (required)
    address weEthWethOracle;
    address ethUsdcOracle;
    address usdcUsdOracle;
    // General (optional)
    address swapRouterOpenOcean;
    // Aave (optional)
    address aaveV3Pool;
    address aaveV3PoolDataProvider;
    address aaveV3IncentivesManager;
    address aaveWrappedTokenGateway;
    // Stargate / Settlement (optional)
    address stargateUsdcPool;
    address stargateEthPool;
    uint32 settlementDestEid;
    // EtherFi Stake (optional)
    address syncPool;
    // Midas (optional)
    address midasToken;
    address midasDepositVault;
    address midasRedemptionVault;
    // Frax (optional)
    address fraxusd;
    address fraxCustodian;
    address fraxRemoteHop;
    // EtherFi Liquid (optional)
    address ethfi;
    address sethfi;
    address sethfiTeller;
    address sethfiBoringQueue;
    address liquidEth;
    address liquidEthTeller;
    address liquidEthBoringQueue;
    address liquidUsd;
    address liquidUsdTeller;
    address liquidUsdBoringQueue;
    address liquidBtc;
    address liquidBtcTeller;
    address liquidBtcBoringQueue;
    address ebtc;
    address ebtcTeller;
    address ebtcBoringQueue;
}

contract Utils is Test {
    uint256 public constant HUNDRED_PERCENT = 100e18;
    uint256 public constant HUNDRED_PERCENT_IN_BPS = 10000;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant SIX_DECIMALS = 1e6;
    address eth = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function getChainConfig() internal view returns (ChainConfig memory) {
        string memory chainId = vm.envString("TEST_CHAIN");
        require(bytes(chainId).length > 0, "TEST_CHAIN env var must be set");
        return getChainConfig(chainId);
    }

    function getChainConfig(
        string memory chainId
    ) internal view returns (ChainConfig memory) {
        string memory file = string.concat(vm.projectRoot(), string(abi.encodePacked("/deployments/", getEnv(), "/fixtures/fixtures.json")));
        string memory json = vm.readFile(file);

        string memory base = string.concat(".", chainId, ".");

        ChainConfig memory config;

        // Required fields
        config.owner = stdJson.readAddress(json, string.concat(base, "owner"));
        config.rpc = stdJson.readString(json, string.concat(base, "rpc"));
        config.usdc = stdJson.readAddress(json, string.concat(base, "usdc"));
        config.usdt = stdJson.readAddress(json, string.concat(base, "usdt"));
        config.weETH = stdJson.readAddress(json, string.concat(base, "weETH"));
        config.weth = stdJson.readAddress(json, string.concat(base, "weth"));
        config.weEthWethOracle = stdJson.readAddress(json, string.concat(base, "weEthWethOracle"));
        config.ethUsdcOracle = stdJson.readAddress(json, string.concat(base, "ethUsdcOracle"));
        config.usdcUsdOracle = stdJson.readAddress(json, string.concat(base, "usdcUsdOracle"));

        // Optional fields
        config.swapRouterOpenOcean = _tryReadAddress(json, string.concat(base, "swapRouterOpenOcean"));
        config.aaveV3Pool = _tryReadAddress(json, string.concat(base, "aaveV3Pool"));
        config.aaveV3PoolDataProvider = _tryReadAddress(json, string.concat(base, "aaveV3PoolDataProvider"));
        config.aaveV3IncentivesManager = _tryReadAddress(json, string.concat(base, "aaveV3IncentivesManager"));
        config.aaveWrappedTokenGateway = _tryReadAddress(json, string.concat(base, "aaveWrappedTokenGateway"));
        config.stargateUsdcPool = _tryReadAddress(json, string.concat(base, "stargateUsdcPool"));
        config.stargateEthPool = _tryReadAddress(json, string.concat(base, "stargateEthPool"));
        config.settlementDestEid = _tryReadUint32(json, string.concat(base, "settlementDestEid"));
        config.syncPool = _tryReadAddress(json, string.concat(base, "syncPool"));
        config.midasToken = _tryReadAddress(json, string.concat(base, "midasToken"));
        config.midasDepositVault = _tryReadAddress(json, string.concat(base, "midasDepositVault"));
        config.midasRedemptionVault = _tryReadAddress(json, string.concat(base, "midasRedemptionVault"));
        config.fraxusd = _tryReadAddress(json, string.concat(base, "fraxusd"));
        config.fraxCustodian = _tryReadAddress(json, string.concat(base, "fraxCustodian"));
        config.fraxRemoteHop = _tryReadAddress(json, string.concat(base, "fraxRemoteHop"));
        config.ethfi = _tryReadAddress(json, string.concat(base, "ethfi"));
        config.sethfi = _tryReadAddress(json, string.concat(base, "sethfi"));
        config.sethfiTeller = _tryReadAddress(json, string.concat(base, "sethfiTeller"));
        config.sethfiBoringQueue = _tryReadAddress(json, string.concat(base, "sethfiBoringQueue"));
        config.liquidEth = _tryReadAddress(json, string.concat(base, "liquidEth"));
        config.liquidEthTeller = _tryReadAddress(json, string.concat(base, "liquidEthTeller"));
        config.liquidEthBoringQueue = _tryReadAddress(json, string.concat(base, "liquidEthBoringQueue"));
        config.liquidUsd = _tryReadAddress(json, string.concat(base, "liquidUsd"));
        config.liquidUsdTeller = _tryReadAddress(json, string.concat(base, "liquidUsdTeller"));
        config.liquidUsdBoringQueue = _tryReadAddress(json, string.concat(base, "liquidUsdBoringQueue"));
        config.liquidBtc = _tryReadAddress(json, string.concat(base, "liquidBtc"));
        config.liquidBtcTeller = _tryReadAddress(json, string.concat(base, "liquidBtcTeller"));
        config.liquidBtcBoringQueue = _tryReadAddress(json, string.concat(base, "liquidBtcBoringQueue"));
        config.ebtc = _tryReadAddress(json, string.concat(base, "ebtc"));
        config.ebtcTeller = _tryReadAddress(json, string.concat(base, "ebtcTeller"));
        config.ebtcBoringQueue = _tryReadAddress(json, string.concat(base, "ebtcBoringQueue"));

        return config;
    }

    function _tryReadAddress(string memory json, string memory key) internal view returns (address) {
        if (vm.keyExistsJson(json, key)) {
            return stdJson.readAddress(json, key);
        }
        return address(0);
    }

    function _tryReadUint32(string memory json, string memory key) internal view returns (uint32) {
        if (vm.keyExistsJson(json, key)) {
            return uint32(stdJson.readUint(json, key));
        }
        return 0;
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
