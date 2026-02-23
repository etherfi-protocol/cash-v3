// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Utils} from "../utils/Utils.sol";
import {CCTPAdapter} from "../../src/top-up/bridge/CCTPAdapter.sol";

/**
 * @title DeployCCTPAdapterArbitrum
 * @notice Deploys CCTP adapter on Arbitrum using CREATE3 for deterministic addresses
 * @dev Deployment-only script, configuration is handled separately
 */
contract DeployCCTPAdapterArbitrum is Utils {
    CCTPAdapter public cctpAdapter;

    function run() public {

        vm.startBroadcast();

        cctpAdapter = CCTPAdapter(
            deployWithCreate3(
                abi.encodePacked(type(CCTPAdapter).creationCode), 
                getSalt(CCTP_ADAPTER)
            )
        );

        vm.stopBroadcast();
    }
}

