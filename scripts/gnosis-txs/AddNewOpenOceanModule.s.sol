// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import { OpenOceanSwapModule } from "../../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract AddNewOpenOceanModule is GnosisHelpers, Utils {
    address safe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    
    address openOceanSwapRouter = 0x6352a56caadC4F1E25CD6c75970Fa768A3304e64;
    OpenOceanSwapModule openOceanSwapModule;

    function run() public { 
        string memory deployments = readDeploymentFile();

        string memory chainId = vm.toString(block.chainid);

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address dataProvider = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider"))
        );

        vm.startBroadcast(deployerPrivateKey);

        openOceanSwapModule = new OpenOceanSwapModule(openOceanSwapRouter, dataProvider);

        address[] memory defaultModules = new address[](1);
        defaultModules[0] = address(openOceanSwapModule);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        string memory txs = _getGnosisHeader(chainId, addressToHex(safe));
        
        string memory addDefaultModules = iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, defaultModules, shouldWhitelist));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(dataProvider), addDefaultModules, "0", true)));

        vm.stopBroadcast();

        vm.createDir("./output", true);
        string memory path = "./output/AddNewOpenOceanModule.json";
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);
    }
}