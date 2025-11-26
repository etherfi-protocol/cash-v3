// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { Test, console } from "forge-std/Test.sol";

import { UUPSProxy } from "../src/UUPSProxy.sol";
import { BinSponsor, SettlementDispatcher } from "../src/settlement-dispatcher/SettlementDispatcher.sol";
import { SettlementDispatcherV2 } from "../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { CashModuleSetters } from "../src/modules/cash/CashModuleSetters.sol";
import { Utils } from "./utils/Utils.sol";

contract DeploySettlementDispatcherV2 is Utils, Test {
    function run() public {
        string memory deployments = readDeploymentFile();
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        address roleRegistry = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "RoleRegistry")
        );
        address cashModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModule")
        );
        address dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );

        SettlementDispatcherV2 settlementDispatcherV2Impl = new SettlementDispatcherV2(
            BinSponsor.CardOrder,
            dataProvider
        );

        // Token addresses for Scroll dev
        address usdc = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
        address usdt = 0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df;

        address[] memory tokens = new address[](2);
        tokens[0] = usdc;
        tokens[1] = usdt;

        SettlementDispatcher.DestinationData[] memory destDatas = new SettlementDispatcher.DestinationData[](2);
        
        // Configure USDC destination data (canonical bridge to Ethereum)
        destDatas[0] = SettlementDispatcher.DestinationData({
            destEid: 0,
            destRecipient: 0x6f7F522075AA5483d049dF0Ef81FcdD3b0ace7f4, // Update with correct recipient address
            stargate: address(0),
            useCanonicalBridge: true,
            minGasLimit: 200_000
        });

        // Configure USDT destination data (canonical bridge to Ethereum)
        destDatas[1] = SettlementDispatcher.DestinationData({
            destEid: 0,
            destRecipient: 0x6f7F522075AA5483d049dF0Ef81FcdD3b0ace7f4, // Update with correct recipient address
            stargate: address(0),
            useCanonicalBridge: true,
            minGasLimit: 200_000
        });

        // Deploy proxy with initialization
        UUPSProxy settlementDispatcherV2Proxy = new UUPSProxy(
            address(settlementDispatcherV2Impl),
            abi.encodeWithSelector(
                SettlementDispatcherV2.initialize.selector,
                roleRegistry,
                tokens,
                destDatas
            )
        );

        CashModuleSetters(cashModule).setSettlementDispatcher(
            BinSponsor.CardOrder,
            address(settlementDispatcherV2Proxy)
        );

        // Optional: Set liquid asset withdraw queue if needed
        // address liquidUsd = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
        // address liquidUsdBoringQueue = 0x38FC1BA73b7ED289955a07d9F11A85b6E388064A;
        // SettlementDispatcherV2(address(settlementDispatcherV2Proxy)).setLiquidAssetWithdrawQueue(
        //     liquidUsd,
        //     liquidUsdBoringQueue
        // );

        console.log("SettlementDispatcherV2 Implementation:", address(settlementDispatcherV2Impl));
        console.log("SettlementDispatcherV2 Proxy:", address(settlementDispatcherV2Proxy));

        vm.stopBroadcast();
    }
}

