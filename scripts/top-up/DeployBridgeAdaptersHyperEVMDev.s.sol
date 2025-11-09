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


    // Base/mainnet production deployments (used to ensure we don't collide when dev salts are missing)
    address constant EXPECTED_CCTP_ADAPTER_PROD = 0x53A327cce6eDD6A887169Fa658271ff3588a383e;
    address constant EXPECTED_OFT_ADAPTER_PROD = 0x3E0ccbce6c3beC4826397005c877BE66C39D9912;
    address constant EXPECTED_OFT_ADAPTER_MAINNET_PROD = 0x6dB93653C1617ec32764020DbB7521BB7c7294b0;

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

