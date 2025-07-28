// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import "forge-std/Vm.sol";

import { UUPSProxy } from "../src/UUPSProxy.sol";
import {TopUpFactory} from "../src/top-up/TopUpFactory.sol";
import {Utils} from "./utils/Utils.sol";

struct TokenConfig {
    string token;
    string bridge;
    address recipient;
    uint256 slippage;
    address stargatePool;
    address oftAdapter;
}

contract AddUsdtSupportEth is Utils {
    TopUpFactory topUpFactory;
    address scrollERC20GatewayAdapter; 
    address topUpDest;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readTopUpSourceDeployment();
        string memory chainId = vm.toString(block.chainid);
        topUpFactory = TopUpFactory(
            payable(
                stdJson.readAddress(
                    deployments,
                    string.concat(".", "addresses", ".", "TopUpSourceFactory")
                )
            )
        );
        scrollERC20GatewayAdapter = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "ScrollERC20BridgeAdapter")
        );

        string memory dir = string.concat(vm.projectRoot(), string.concat("/deployments/", getEnv(), "/"));
        string memory chainDir = string.concat(scrollChainId, "/");
        string memory file = string.concat(dir, chainDir, "deployments", ".json");
        string memory scrollDeployments = vm.readFile(file);
        topUpDest = stdJson.readAddress(
            scrollDeployments,
            string.concat(".", "addresses", ".", "TopUpDest")
        );

        string memory fixturesFile = string.concat(vm.projectRoot(), string.concat("/deployments/", getEnv() ,"/fixtures/top-up-fixtures.json"));
        string memory fixtures = vm.readFile(fixturesFile);
        (address[] memory tokens, TopUpFactory.TokenConfig[] memory tokenConfig) = parseTokenConfigs(fixtures, chainId);
        topUpFactory.setTokenConfig(tokens, tokenConfig);

        vm.stopBroadcast();
    }   

    // Helper function to parse token configs from JSON
    function parseTokenConfigs(string memory jsonString, string memory chainId) internal view returns (address[] memory tokens, TopUpFactory.TokenConfig[] memory tokenConfig) {
        // Initialize arrays with size 1 since we only want ETHFI
        tokens = new address[](1);
        tokenConfig = new TopUpFactory.TokenConfig[](1);
        
        string memory base = string.concat(".", chainId, ".tokenConfigs[");
        uint256 ethfiIndex = 0;
        bool found = false;
        
        // Loop through configs to find ETHFI
        for (uint256 i = 0; i < 20; i++) {
            string memory tokenName = stdJson.readString(jsonString, string.concat(base, vm.toString(i), "].token"));
            if (keccak256(bytes(tokenName)) == keccak256(bytes("usdt"))) {
                ethfiIndex = i;
                found = true;
                break;
            }
        }
        
        if (!found) revert("usdt token config not found");
        
        base = string.concat(base, vm.toString(ethfiIndex), "]");

        address scrollGateway = stdJson.readAddress(jsonString, string.concat(base, ".scrollGatewayRouter"));
        uint256 gasLimit = stdJson.readUint(jsonString, string.concat(base, ".gasLimitForScrollGateway"));

        tokens[0] = stdJson.readAddress(jsonString, string.concat(base, ".address"));
        tokenConfig[0].recipientOnDestChain = topUpDest;
        tokenConfig[0].maxSlippageInBps = uint96(stdJson.readUint(jsonString, string.concat(base, ".maxSlippageInBps")));
        tokenConfig[0].bridgeAdapter = address(scrollERC20GatewayAdapter);
        tokenConfig[0].additionalData = abi.encode(scrollGateway, gasLimit);

        return (tokens, tokenConfig);
    }
    
}



