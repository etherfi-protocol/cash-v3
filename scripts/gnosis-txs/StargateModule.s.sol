// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import { StargateModule } from "../../src/modules/stargate/StargateModule.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract DeployAndWhitelistStargateModule is GnosisHelpers, Utils {
    address safe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address weETH = 0x01f0a31698C4d065659b9bdC21B3610292a1c506;
    address usdc = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;

    address usdcStargatePool = 0x3Fc69CC4A842838bCDC9499178740226062b14E4;
    
    StargateModule stargateModule;

    function run() public {
        vm.startBroadcast();

        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();
        address dataProvider = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider"))
        );

        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(weETH);

        StargateModule.AssetConfig[] memory assetConfigs = new StargateModule.AssetConfig[](2);

        assetConfigs[0] = StargateModule.AssetConfig({
            isOFT: false,
            pool: usdcStargatePool
        });
        assetConfigs[1] = StargateModule.AssetConfig({
            isOFT: true,
            pool: address(weETH)
        });

        stargateModule = new StargateModule(assets, assetConfigs, dataProvider);

        address[] memory modules = new address[](1);
        modules[0] = address(stargateModule);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        string memory txs = _getGnosisHeader(chainId, addressToHex(safe));
        
        string memory addStargateModule = iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, modules, shouldWhitelist));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(dataProvider), addStargateModule, "0", true)));

        vm.stopBroadcast();

        vm.createDir("./output", true);
        string memory path = "./output/AddStargateModule.json";
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);
    }

}
