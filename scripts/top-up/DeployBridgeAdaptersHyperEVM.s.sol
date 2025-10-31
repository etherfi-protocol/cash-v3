// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Utils} from "../utils/Utils.sol";
import {CCTPAdapter} from "../../src/top-up/bridge/CCTPAdapter.sol";
import {EtherFiOFTBridgeAdapter} from "../../src/top-up/bridge/EtherFiOFTBridgeAdapter.sol";
import {EtherFiOFTBridgeAdapterMainnet} from "../../src/top-up/bridge/EtherFiOFTBridgeAdapterMainnet.sol";

/**
 * @title DeployBridgeAdaptersHyperEVM
 * @notice Deploys bridge adapters on HyperEVM using CREATE3 for deterministic addresses
 * @dev Deploys CCTPAdapter and EtherFiOFTBridgeAdapter
 */
contract DeployBridgeAdaptersHyperEVM is Utils {
    CCTPAdapter public cctpAdapter;
    EtherFiOFTBridgeAdapter public oftBridgeAdapter;
    EtherFiOFTBridgeAdapterMainnet public oftBridgeAdapterMainnet;

    // Expected addresses from Base deployment
    address constant EXPECTED_CCTP_ADAPTER = 0x53A327cce6eDD6A887169Fa658271ff3588a383e;
    address constant EXPECTED_OFT_ADAPTER = 0x3E0ccbce6c3beC4826397005c877BE66C39D9912;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // cctpAdapter = CCTPAdapter(
        //     deployWithCreate3(
        //         abi.encodePacked(type(CCTPAdapter).creationCode), 
        //         getSalt(CCTP_ADAPTER)
        //     )
        // );

        // oftBridgeAdapter = EtherFiOFTBridgeAdapter(
        //     deployWithCreate3(
        //         abi.encodePacked(type(EtherFiOFTBridgeAdapter).creationCode), 
        //         getSalt(ETHER_FI_OFT_BRIDGE_ADAPTER)
        //     )
        // );

        oftBridgeAdapterMainnet = EtherFiOFTBridgeAdapterMainnet(
            deployWithCreate3(
                abi.encodePacked(type(EtherFiOFTBridgeAdapterMainnet).creationCode), 
                getSalt(ETHER_FI_OFT_BRIDGE_ADAPTER_MAINNET)
            )
        );

        // require(
        //     address(cctpAdapter) == EXPECTED_CCTP_ADAPTER,
        //     "CCTPAdapter address mismatch"
        // );
        // require(
        //     address(oftBridgeAdapter) == EXPECTED_OFT_ADAPTER,
        //     "OFTBridgeAdapter address mismatch"
        // );

        vm.stopBroadcast();
    }
}

