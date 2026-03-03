// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { BinSponsor } from "../../src/settlement-dispatcher/SettlementDispatcher.sol";
import { SettlementDispatcherV2 } from "../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { Utils } from "../utils/Utils.sol";

contract DeploySettlementDispatcherV2Implementations is Utils {
    function run() public {
        string memory deployments = readDeploymentFile();

        address dataProvider = stdJson.readAddress(deployments, string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider")));

        vm.startBroadcast();

        SettlementDispatcherV2 reapImpl = new SettlementDispatcherV2(BinSponsor.Reap, dataProvider);
        SettlementDispatcherV2 rainImpl = new SettlementDispatcherV2(BinSponsor.Rain, dataProvider);
        SettlementDispatcherV2 pixImpl = new SettlementDispatcherV2(BinSponsor.PIX, dataProvider);
        SettlementDispatcherV2 cardOrderImpl = new SettlementDispatcherV2(BinSponsor.CardOrder, dataProvider);

        console.log("SettlementDispatcherV2 Reap Implementation:", address(reapImpl));
        console.log("SettlementDispatcherV2 Rain Implementation:", address(rainImpl));
        console.log("SettlementDispatcherV2 PIX Implementation:", address(pixImpl));
        console.log("SettlementDispatcherV2 CardOrder Implementation:", address(cardOrderImpl));

        vm.stopBroadcast();
    }
}
