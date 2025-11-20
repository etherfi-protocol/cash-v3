// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";

import {EscrowSettlementDispatcher} from "../src/settlement-dispatcher/EscrowSettlementDispatcher.sol";
import {UUPSProxy} from "../src/UUPSProxy.sol";
import {Utils, ChainConfig} from "./utils/Utils.sol";

/**
 * @title DeployEscrowSettlementDispatcher
 * @notice Script to deploy EscrowSettlementDispatcher contract
 */
contract DeployEscrowSettlementDispatcher is Utils {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();
        
        address dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );
        
        address roleRegistry = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "RoleRegistry")
        );

        // Deploy implementation
        address escrowImpl = deployWithCreate3(
            abi.encodePacked(
                type(EscrowSettlementDispatcher).creationCode,
                abi.encode(dataProvider)
            ),
            getSalt("ESCROW_SETTLEMENT_DISPATCHER_IMPL")
        );

        // Deploy proxy
        address escrowProxy = deployWithCreate3(
            abi.encodePacked(
                type(UUPSProxy).creationCode,
                abi.encode(escrowImpl, "")
            ),
            getSalt("ESCROW_SETTLEMENT_DISPATCHER_PROXY")
        );

        // Initialize the contract
        EscrowSettlementDispatcher escrow = EscrowSettlementDispatcher(escrowProxy);
        escrow.initialize(roleRegistry);

        console.log("EscrowSettlementDispatcher Implementation:", escrowImpl);
        console.log("EscrowSettlementDispatcher Proxy:", escrowProxy);

        vm.stopBroadcast();
    }
}

