// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { FraxModule } from "../../src/modules/frax/FraxModule.sol";
import { Utils } from "../utils/Utils.sol";

contract DeployFraxModule is Utils {
    address fraxusd = 0x397F939C3b91A74C321ea7129396492bA9Cdce82;
    address usdc = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    address custodian = 0x05bF905356fbeA7E59500f904b908402dB7A53DD;
    address remoteHop = 0xF6f45CCB5E85D1400067ee66F9e168f83e86124E;

    function run() public {
        string memory deployments = readDeploymentFile();

        address dataProvider = stdJson.readAddress(deployments, string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider")));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy frax module
        FraxModule fraxModule = new FraxModule(dataProvider, fraxusd, custodian, remoteHop);

        console.log("FraxModule deployed at:", address(fraxModule));

        vm.stopBroadcast();
    }
}
