// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import { OpenOceanSwapModule } from "../../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract RemoveOldOpenOceanModule is GnosisHelpers, Utils {
    address safe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    
    address oldOpenOceanSwapModule = 0x38Ce1a31e69f3A6E4CfB6b2E47726e67d31A2Ef4;

    function run() public { 
        string memory deployments = readDeploymentFile();

        string memory chainId = vm.toString(block.chainid);

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address dataProvider = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider"))
        );

        vm.startBroadcast(deployerPrivateKey);

        address[] memory modules = new address[](1);
        modules[0] = address(oldOpenOceanSwapModule);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = false;

        string memory txs = _getGnosisHeader(chainId, addressToHex(safe));
        
        string memory removeOpenOceanModules = iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureModules.selector, modules, shouldWhitelist));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(dataProvider), removeOpenOceanModules, "0", true)));

        vm.stopBroadcast();

        vm.createDir("./output", true);
        string memory path = "./output/RemoveOldOpenOceanModule.json";
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);
    }
}