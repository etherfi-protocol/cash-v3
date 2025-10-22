// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";

import { Utils, ChainConfig } from "../utils/Utils.sol";
import { WormholeModule } from "../../src/modules/wormhole/WormholeModule.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";

contract EthfiCrosschain is GnosisHelpers, Utils {
    WormholeModule wormholeModule;

    address safe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address ethfi = 0x056A5FA5da84ceb7f93d36e545C5905607D8bD81;
    address ethfiNttManager = 0x552c09b224ec9146442767C0092C2928b61f62A1;
    uint8 dustDecimals = 10;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();
        address dataProvider = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider"))
        );
        address cashModule = stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "CashModule"))
        );

        address[] memory assets = new address[](1);
        assets[0] = address(ethfi);

        WormholeModule.AssetConfig[] memory assetConfigs = new WormholeModule.AssetConfig[](1);
        assetConfigs[0] = WormholeModule.AssetConfig({
            nttManager: ethfiNttManager,
            dustDecimals: dustDecimals
        });

        wormholeModule = new WormholeModule(assets, assetConfigs, dataProvider);

        address[] memory modules = new address[](1);
        modules[0] = address(wormholeModule);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(safe));

        string memory configureWormholeModule = iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, modules, shouldWhitelist));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(dataProvider), configureWormholeModule, "0", false)));

        string memory configureCashModule = iToHex(abi.encodeWithSelector(ICashModule.configureModulesCanRequestWithdraw.selector, modules, shouldWhitelist));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), configureCashModule, "0", true)));

        vm.stopBroadcast();

        vm.createDir("./output", true);
        string memory path = "./output/EthfiCrosschain.json";
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);
    }
}