// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Utils} from "../utils/Utils.sol";
import {CCTPAdapter} from "../../src/top-up/bridge/CCTPAdapter.sol";
import {EtherFiOFTBridgeAdapter} from "../../src/top-up/bridge/EtherFiOFTBridgeAdapter.sol";
import {EtherFiOFTBridgeAdapterMainnet} from "../../src/top-up/bridge/EtherFiOFTBridgeAdapterMainnet.sol";

/**
 * @title DeployBridgeAdaptersHyperEVMDev
 * @notice Deploys bridge adapters on HyperEVM for the dev environment using dedicated CREATE3 salts
 * @dev Deploys CCTPAdapter, EtherFiOFTBridgeAdapter, and EtherFiOFTBridgeAdapterMainnet
 */
contract DeployBridgeAdaptersHyperEVMDev is Utils {
    CCTPAdapter public cctpAdapter;
    EtherFiOFTBridgeAdapter public oftBridgeAdapter;
    EtherFiOFTBridgeAdapterMainnet public oftBridgeAdapterMainnet;

    // Base dev deployments (only known entries enforced)
    address constant EXPECTED_OFT_ADAPTER_DEV = 0x6C6C72B148f76DD10fE61956b058e5f356907640;

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

        // Enforce address determinism when we have recorded dev deployments
        require(
            address(oftBridgeAdapter) == EXPECTED_OFT_ADAPTER_DEV,
            "OFTBridgeAdapter dev address mismatch"
        );



        vm.stopBroadcast();
    }
}

