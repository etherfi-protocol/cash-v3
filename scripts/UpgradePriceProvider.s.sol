// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {PriceProvider} from "../src/oracle/PriceProvider.sol";
import {Utils, ChainConfig} from "./utils/Utils.sol";

contract UpgradePriceProvider is Utils {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();

        UUPSUpgradeable priceProvider = UUPSUpgradeable(stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "PriceProvider"))
        ));

        address priceProviderImpl = address(new PriceProvider());
        priceProvider.upgradeToAndCall(address(priceProviderImpl), "");

        vm.stopBroadcast();
    }
}