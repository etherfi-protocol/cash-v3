// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import {TopUpFactory} from "../../src/top-up/TopUpFactory.sol";
import {Utils} from "../utils/Utils.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";

struct TokenConfig {
    string token;
    string bridge;
    address recipient;
    uint256 slippage;
    address stargatePool;
    address oftAdapter;
}

contract TopUpSourceSetConfig is Utils, GnosisHelpers {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    TopUpFactory topUpFactory;
    address stargateAdapter;
    address scrollERC20BridgeAdapter;
    address etherFiOFTBridgeAdapter;
    address nttAdapter;
    address etherFiLiquidBridgeAdapter;
    
    function run() public {
        // uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast();
        
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

        stargateAdapter = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "StargateAdapter")
        );

        etherFiOFTBridgeAdapter = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiOFTBridgeAdapter")
        );
        nttAdapter = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "NTTAdapter")
        );

        if (block.chainid == 1) {
            etherFiLiquidBridgeAdapter = stdJson.readAddress(
                deployments,
                string.concat(".", "addresses", ".", "EtherFiLiquidBridgeAdapter")
            );

            scrollERC20BridgeAdapter = stdJson.readAddress(
                deployments,
                string.concat(".", "addresses", ".", "ScrollERC20BridgeAdapter")
            );
        }
        
        string memory fixturesFile = string.concat(vm.projectRoot(), string.concat("/deployments/", getEnv() ,"/fixtures/top-up-fixtures.json"));
        string memory fixtures = vm.readFile(fixturesFile);

        (address[] memory tokens, TopUpFactory.TokenConfig[] memory tokenConfig) = parseTokenConfigs(fixtures, vm.toString(block.chainid));

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));
        string memory setTokenConfig = iToHex(abi.encodeWithSelector(TopUpFactory.setTokenConfig.selector, tokens, tokenConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(topUpFactory)), setTokenConfig, "0", true)));
        
        vm.createDir("./output", true);
        string memory path = string.concat("./output/TopUpSetConfig-", chainId, ".json");
        vm.writeFile(path, txs);

        vm.stopBroadcast();

        /// below here is just a test
        executeGnosisTransactionBundle(path);
    }   

    // Helper function to parse token configs from JSON
    function parseTokenConfigs(string memory jsonString, string memory chainId) internal view returns (address[] memory tokens, TopUpFactory.TokenConfig[] memory tokenConfig) {
        uint256 count = getTokenConfigsLength(jsonString, chainId);
        tokens = new address[](count);
        tokenConfig = new TopUpFactory.TokenConfig[](count);

        (address topUpDest, address topUpDestNativeGateway) = getTopUpDestAndNativeGateway();
        address weth = stdJson.readAddress(jsonString, string.concat(".", chainId, ".weth"));
        
        for (uint256 i = 0; i < count; i++) {
            string memory base = string.concat(".", chainId, ".tokenConfigs[", vm.toString(i), "]");
            
            tokens[i] = stdJson.readAddress(jsonString, string.concat(base, ".address"));
            tokenConfig[i].recipientOnDestChain = (tokens[i] == weth) ? topUpDestNativeGateway : topUpDest;

            tokenConfig[i].maxSlippageInBps = uint96(stdJson.readUint(jsonString, string.concat(base, ".maxSlippageInBps")));
            string memory bridge = stdJson.readString(jsonString, string.concat(base, ".bridge"));

            if (keccak256(bytes(bridge)) == keccak256(bytes("stargate"))) {
                tokenConfig[i].bridgeAdapter = stargateAdapter;
                tokenConfig[i].additionalData = abi.encode(stdJson.readAddress(jsonString, string.concat(base, ".stargatePool")));
            } else if (keccak256(bytes(bridge)) == keccak256(bytes("oftBridgeAdapter"))) {
                tokenConfig[i].bridgeAdapter = etherFiOFTBridgeAdapter;
                tokenConfig[i].additionalData = abi.encode(stdJson.readAddress(jsonString, string.concat(base, ".oftAdapter")));
            } else if (keccak256(bytes(bridge)) == keccak256(bytes("nttAdapter"))) {
                tokenConfig[i].bridgeAdapter = nttAdapter;
                tokenConfig[i].additionalData = abi.encode(stdJson.readAddress(jsonString, string.concat(base, ".nttManager")), stdJson.readUint(jsonString, string.concat(base, ".dustDecimals")));
            } else if (block.chainid == 1 && keccak256(bytes(bridge)) == keccak256(bytes("liquidBridgeAdapter"))) {
                tokenConfig[i].bridgeAdapter = etherFiLiquidBridgeAdapter;
                tokenConfig[i].additionalData = abi.encode(stdJson.readAddress(jsonString, string.concat(base, ".teller")));
            } else if (block.chainid == 1 && keccak256(bytes(bridge)) == keccak256(bytes("scrollERC20BridgeAdapter"))) {
                tokenConfig[i].bridgeAdapter = scrollERC20BridgeAdapter;
                address scrollGateway = stdJson.readAddress(jsonString, string.concat(base, ".scrollGatewayRouter"));
                uint256 gasLimit = stdJson.readUint(jsonString, string.concat(base, ".gasLimitForScrollGateway"));
                tokenConfig[i].additionalData = abi.encode(scrollGateway, gasLimit);
            } else revert ("Unknown bridge");

            if (tokenConfig[i].recipientOnDestChain == address(0)) revert (string.concat("Invalid recipientOnDestChain for token ", stdJson.readString(jsonString, string.concat(base, ".token"))));
            if (tokenConfig[i].maxSlippageInBps > 10000) revert (string.concat("Invalid maxSlippageInBps for token ", stdJson.readString(jsonString, string.concat(base, ".token"))));
            if (tokenConfig[i].bridgeAdapter == address(0)) revert (string.concat("Invalid bridgeAdapter for token ", stdJson.readString(jsonString, string.concat(base, ".token"))));
        }
        
        return (tokens, tokenConfig);
    }

    function getTokenConfigsLength(string memory jsonString, string memory chainId) internal pure returns (uint256) {
        // First, let's try to parse the entire tokenConfigs array as raw bytes
        bytes memory arrayData = stdJson.parseRaw(jsonString, string.concat(".", chainId, ".tokenConfigs"));
        
        // Now we need to decode this. The array is ABI-encoded.
        // For an array of structs, it starts with the array length
        
        // Direct decode of the length
        // ABI encoding for dynamic types: first 32 bytes = offset, then at offset: 32 bytes = length
        uint256 arrayLength;
        assembly {
            // Skip the first 32 bytes (offset) and read the length
            arrayLength := mload(add(arrayData, 0x40))
        }
        
        return arrayLength;
    }

    function getValue(string memory jsonString, string memory path) external pure returns (address) {
        return stdJson.readAddress(jsonString, path);
    }

    function getTopUpDestAndNativeGateway() internal view returns (address, address) {
        string memory dir = string.concat(vm.projectRoot(), string.concat("/deployments/", getEnv(), "/"));
        string memory chainDir = string.concat(scrollChainId, "/");
        string memory file = string.concat(dir, chainDir, "deployments", ".json");

        if (!vm.exists(file)) revert ("Scroll deployment file not found");
        string memory deployments = vm.readFile(file);

        address topUpDest = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "TopUpDest")
        );
        address topUpDestNativeGateway = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "TopUpDestNativeGateway")
        );

        return (topUpDest, topUpDestNativeGateway);
    }
}
