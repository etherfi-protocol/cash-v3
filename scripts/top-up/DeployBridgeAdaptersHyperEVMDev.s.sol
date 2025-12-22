// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Utils} from "../utils/Utils.sol";
import {CCTPAdapter} from "../../src/top-up/bridge/CCTPAdapter.sol";
import {EtherFiOFTBridgeAdapter} from "../../src/top-up/bridge/EtherFiOFTBridgeAdapter.sol";
import {EtherFiOFTBridgeAdapterMainnet} from "../../src/top-up/bridge/EtherFiOFTBridgeAdapterMainnet.sol";

contract DeployBridgeAdaptersHyperEVMDev is Utils {
    CCTPAdapter public cctpAdapter;
    EtherFiOFTBridgeAdapter public oftBridgeAdapter;
    EtherFiOFTBridgeAdapterMainnet public oftBridgeAdapterMainnet;


    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        cctpAdapter = CCTPAdapter(
            deployWithCreate3(
                abi.encodePacked(type(CCTPAdapter).creationCode),
                getSalt(CCTP_ADAPTER_DEV)
            )
        );

        oftBridgeAdapter = EtherFiOFTBridgeAdapter(
            deployWithCreate3(
                abi.encodePacked(type(EtherFiOFTBridgeAdapter).creationCode),
                getSalt(ETHER_FI_OFT_BRIDGE_ADAPTER_DEV)
            )
        );

        oftBridgeAdapterMainnet = EtherFiOFTBridgeAdapterMainnet(
            deployWithCreate3(
                abi.encodePacked(type(EtherFiOFTBridgeAdapterMainnet).creationCode),
                getSalt(ETHER_FI_OFT_BRIDGE_ADAPTER_MAINNET_DEV)
            )
        );

        vm.stopBroadcast();
    }
}

