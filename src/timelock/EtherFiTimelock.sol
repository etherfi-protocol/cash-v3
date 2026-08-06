// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title EtherFiTimelock
 * @author ether.fi
 * @notice Timelock that owns the RoleRegistry, putting role administration and contract
 *         upgrades behind an execution delay.
 */
contract EtherFiTimelock is TimelockController {
    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin) TimelockController(minDelay, proposers, executors, admin) { }
}
