// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import {Utils} from "../utils/Utils.sol";
import {BeaconFactory, TopUpFactory} from "../../src/top-up/TopUpFactory.sol";
import {TopUp} from "../../src/top-up/TopUp.sol";

contract UpgradeTopUps is Utils {
    UUPSUpgradeable factory;

    address wethEthereum = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address wethBase = 0x4200000000000000000000000000000000000006;
    address wethArbitrum = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        
        string memory deployments = readTopUpSourceDeployment();

        factory = UUPSUpgradeable(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "TopUpSourceFactory")
        ));
        
        address factoryImpl = address(new TopUpFactory());

        address weth;
        if (block.chainid == 1) weth = wethEthereum;
        else if (block.chainid == 8453) weth = wethBase;
        else if (block.chainid == 42161) weth = wethArbitrum;
        else revert ("bad chain ID");

        factory.upgradeToAndCall(address(factoryImpl), "");

        address payable topup = payable(address(new TopUp(weth)));

        BeaconFactory(address(factory)).upgradeBeaconImplementation(topup);

        vm.stopBroadcast();
    }
}