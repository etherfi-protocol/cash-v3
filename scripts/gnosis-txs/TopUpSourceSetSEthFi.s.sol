// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import  "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import {TopUpFactory} from "../../src/top-up/TopUpFactory.sol";
import {Utils} from "../utils/Utils.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";

contract TopUpSourceSetSEthFi is Utils, GnosisHelpers, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address sETHFI = 0x86B5780b606940Eb59A062aA85a07959518c0161;
    address sETHFITeller = 0x35dD2463fA7a335b721400C5Ad8Ba40bD85c179b;

    TopUpFactory topUpFactory;
    address liquidBridgeAdapter; 
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

        liquidBridgeAdapter = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiLiquidBridgeAdapter")
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

        address[] memory tokens = new address[](1);
        TopUpFactory.TokenConfig[] memory tokenConfig = new TopUpFactory.TokenConfig[](1);

        tokens[0] = sETHFI;

        tokenConfig[0].recipientOnDestChain = topUpDest;
        tokenConfig[0].maxSlippageInBps = 50;
        tokenConfig[0].bridgeAdapter = liquidBridgeAdapter;
        tokenConfig[0].additionalData = abi.encode(sETHFITeller);
        
        string memory setTokenConfig = iToHex(abi.encodeWithSelector(TopUpFactory.setTokenConfig.selector, tokens, tokenConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(topUpFactory)), setTokenConfig, "0", true)));

        vm.createDir("./output", true);
        string memory path = string.concat("./output/TopUpSourceSetSEthFiConfig.json");
        vm.writeFile(path, txs);

        /// below here is just a test
        executeGnosisTransactionBundle(path);

        uint256 amount = 10 ether;
        deal(tokens[0], address(topUpFactory), amount);
        (, uint256 fee) = topUpFactory.getBridgeFee(tokens[0], amount);
        deal(address(vm.addr(1)), fee);
        vm.prank(address(vm.addr(1)));
        topUpFactory.bridge{value: fee}(tokens[0], amount);
    }  
}



