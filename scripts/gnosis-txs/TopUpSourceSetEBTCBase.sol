// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import  "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import {TopUpFactory} from "../../src/top-up/TopUpFactory.sol";
import {Utils} from "../utils/Utils.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";

contract TopUpSourceSetEBTCBase is Utils, GnosisHelpers, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address ebtc = 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;
    address ebtcTeller = 0x6Ee3aaCcf9f2321E49063C4F8da775DdBd407268;

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

        tokens[0] = ebtc;

        tokenConfig[0].recipientOnDestChain = topUpDest;
        tokenConfig[0].maxSlippageInBps = 50;
        tokenConfig[0].bridgeAdapter = liquidBridgeAdapter;
        tokenConfig[0].additionalData = abi.encode(ebtcTeller);
        
        string memory setTokenConfig = iToHex(abi.encodeWithSelector(TopUpFactory.setTokenConfig.selector, tokens, tokenConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(topUpFactory)), setTokenConfig, "0", true)));

        vm.createDir("./output", true);
        string memory path = string.concat("./output/TopUpSourceSetEBTCBase.json");
        vm.writeFile(path, txs);

        /// below here is just a test
        executeGnosisTransactionBundle(path);

        deal(tokens[0], address(topUpFactory), 1e8);
        (, uint256 fee) = topUpFactory.getBridgeFee(tokens[0]);
        deal(address(vm.addr(1)), fee);
        vm.prank(address(vm.addr(1)));
        topUpFactory.bridge{value: fee}(tokens[0]);
    }  
}



