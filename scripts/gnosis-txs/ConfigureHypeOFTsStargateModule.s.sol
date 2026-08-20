// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { StargateModule } from "../../src/modules/stargate/StargateModule.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";

import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract ConfigureHypeOFTsStargateModule is GnosisHelpers, Utils, Test {
    
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address public beHYPE;
    address public wHYPE;

    address stargateModule;
    address cashModule;
    address roleRegistry;
    
    function run() public {
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();

        stargateModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "StargateModule")
        );

        cashModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModule")
        );

        roleRegistry = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "RoleRegistry")
        );

        string memory fixturesFile = string.concat(vm.projectRoot(), string.concat("/deployments/", getEnv() ,"/fixtures/fixtures.json"));
        string memory fixtures = vm.readFile(fixturesFile);

        beHYPE = stdJson.readAddress(
            fixtures,
            string.concat(".", chainId, ".", "beHYPE")
        );

        wHYPE = stdJson.readAddress(
            fixtures,
            string.concat(".", chainId, ".", "wHYPE")
        );

        address[] memory assets = new address[](2);
        assets[0] = wHYPE;
        assets[1] = beHYPE;

        StargateModule.AssetConfig[] memory assetConfigs = new StargateModule.AssetConfig[](2);
        
        assetConfigs[0] = StargateModule.AssetConfig({
            isOFT: true,
            pool: wHYPE
        });
        
        assetConfigs[1] = StargateModule.AssetConfig({
            isOFT: true,
            pool: beHYPE
        });

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        bytes32 stargateModuleAdminRole = keccak256("STARGATE_MODULE_ADMIN_ROLE");
        string memory grantRoleData = iToHex(abi.encodeWithSelector(
            IRoleRegistry.grantRole.selector,
            stargateModuleAdminRole,
            cashControllerSafe
        ));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(roleRegistry), grantRoleData, "0", false)));

        string memory setAssetConfig = iToHex(abi.encodeWithSelector(
            StargateModule.setAssetConfig.selector, 
            assets, 
            assetConfigs
        ));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(stargateModule), setAssetConfig, "0", false)));

        string memory revokeRoleData = iToHex(abi.encodeWithSelector(
            IRoleRegistry.revokeRole.selector,
            stargateModuleAdminRole,
            cashControllerSafe
        ));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(roleRegistry), revokeRoleData, "0", true)));
        
        vm.createDir("./output", true);
        string memory path = "./output/ConfigureHypeOFTsStargateModule.json";
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);
    }
}

