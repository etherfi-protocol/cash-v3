// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { Utils } from "../utils/Utils.sol";
import { OwnershipBridgeReceiver } from "../../src/ownership-bridge/OwnershipBridgeReceiver.sol";

/**
 * @title WireOwnershipBridge
 * @notice Final wiring step: points the mainnet OwnershipBridgeReceiver's LZ peer at the
 *         OP OwnershipBridgeSender. Run on MAINNET after both deploy scripts; the OP-side
 *         peer was already set during the OP deploy (it had the receiver address).
 *
 * Run:
 *   source .env && ENV=dev forge script scripts/trading-account/WireOwnershipBridge.s.sol --rpc-url mainnet --broadcast -vvv --verify
 */
contract WireOwnershipBridge is Utils {
    uint32 constant OP_EID = 30111;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        OwnershipBridgeReceiver receiver = OwnershipBridgeReceiver(0x13A84ae8bb2b56728B19c86b573c95B4b5Db6f5c);
        address opSender = 0xE59e2b6e91675e5Ed19CAb4aA1881C0b7eFbaD90;

        vm.startBroadcast(pk);
        receiver.setPeer(OP_EID, bytes32(uint256(uint160(opSender))));
        vm.stopBroadcast();

        console.log("Receiver", address(receiver), "now trusts OP sender", opSender);
    }
}
