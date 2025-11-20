// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import {Utils, ChainConfig} from "./utils/Utils.sol";
import {CashModuleSetters} from "../src/modules/cash/CashModuleSetters.sol";
import {BinSponsor} from "../src/interfaces/ICashModule.sol";

/**
 * @title SetEscrowSettlementDispatcher
 * @notice Script to set the escrow settlement dispatcher for a bin sponsor
 */
contract SetEscrowSettlementDispatcher is Utils {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();

        CashModuleSetters cashModuleSetters = CashModuleSetters(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModuleSetters")
        ));

        // Read escrow contract address from environment or deployment file
        address escrowDispatcher = vm.envAddress("ESCROW_DISPATCHER_ADDRESS");
        
        // Read bin sponsor from environment (0 = Reap, 1 = Rain, 2 = PIX)
        uint8 binSponsorValue = uint8(vm.envUint("BIN_SPONSOR"));
        BinSponsor binSponsor = BinSponsor(binSponsorValue);

        // Set the escrow settlement dispatcher
        cashModuleSetters.setSettlementDispatcher(binSponsor, escrowDispatcher);

        vm.stopBroadcast();
    }
}

