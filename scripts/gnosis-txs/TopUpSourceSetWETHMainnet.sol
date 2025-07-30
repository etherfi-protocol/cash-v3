// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import  "forge-std/Vm.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import {TopUpFactory} from "../../src/top-up/TopUpFactory.sol";
import {Utils} from "../utils/Utils.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import {Test} from "forge-std/Test.sol";

struct TokenConfig {
    string token;
    string bridge;
    address recipient;
    uint256 slippage;
    address stargatePool;
    address oftAdapter;
}

interface IFactory {
    function bridge(address token) external payable;
    function getBridgeFee(address token) external view returns (address _token, uint256 _amount); 
}

contract TopUpSourceSetWETHConfig is Utils, GnosisHelpers, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    TopUpFactory topUpFactory;
    address scrollERC20BridgeAdapter; 
    address topUpDest;
    function run() public {

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
        scrollERC20BridgeAdapter = stdJson.readAddress(
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

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));
        
        string memory fixturesFile = string.concat(vm.projectRoot(), string.concat("/deployments/", getEnv() ,"/fixtures/top-up-fixtures.json"));
        string memory fixtures = vm.readFile(fixturesFile);
        (address[] memory tokens, TopUpFactory.TokenConfig[] memory tokenConfig) = parseTokenConfigs(fixtures, chainId);
        string memory setTokenConfig = iToHex(abi.encodeWithSelector(TopUpFactory.setTokenConfig.selector, tokens, tokenConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(topUpFactory)), setTokenConfig, "0", true)));

        vm.createDir("./output", true);
        string memory path = string.concat("./output/TopUpWETHSetConfig-", chainId, ".json");
        vm.writeFile(path, txs);


        /// below here is just a test
        executeGnosisTransactionBundle(path);

        deal(tokens[0], address(topUpFactory), 1 ether);
        (, uint256 fee) = IFactory(address(topUpFactory)).getBridgeFee(tokens[0]);
        deal(address(vm.addr(1)), fee);
        vm.prank(address(vm.addr(1)));
        IFactory(address(topUpFactory)).bridge{value: fee}(tokens[0]);

        
    }   

    // Helper function to parse token configs from JSON
    function parseTokenConfigs(string memory jsonString, string memory chainId) internal view returns (address[] memory tokens, TopUpFactory.TokenConfig[] memory tokenConfig) {
        // Initialize arrays with size 1 since we only want ETHFI
        tokens = new address[](1);
        tokenConfig = new TopUpFactory.TokenConfig[](1);
        
        string memory base = string.concat(".", chainId, ".tokenConfigs[");
        uint256 wethIndex = 0;
        bool found = false;
        
        // Loop through configs to find ETHFI
        for (uint256 i = 0; i < 20; i++) {
            string memory tokenName = stdJson.readString(jsonString, string.concat(base, vm.toString(i), "].token"));
            if (keccak256(bytes(tokenName)) == keccak256(bytes("weth"))) {
                wethIndex = i;
                found = true;
                break;
            }
        }
        
        if (!found) revert("WETH token config not found");
        
        base = string.concat(base, vm.toString(wethIndex), "]");
        
        tokens[0] = stdJson.readAddress(jsonString, string.concat(base, ".address"));
        tokenConfig[0].recipientOnDestChain = topUpDest;
        tokenConfig[0].maxSlippageInBps = uint96(stdJson.readUint(jsonString, string.concat(base, ".maxSlippageInBps")));
        tokenConfig[0].bridgeAdapter = address(scrollERC20BridgeAdapter);

        address scrollGateway = stdJson.readAddress(jsonString, string.concat(base, ".scrollGatewayRouter"));
        uint256 gasLimit = stdJson.readUint(jsonString, string.concat(base, ".gasLimitForScrollGateway"));
        tokenConfig[0].additionalData = abi.encode(scrollGateway, gasLimit);

        return (tokens, tokenConfig);
    }
    
}



