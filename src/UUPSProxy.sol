// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title UUPSProxy
 * @author ether.fi
 * @notice Implementation of the ERC1967 proxy for Universal Upgradeable Proxy Standard (UUPS) pattern
 * @dev This contract is a thin wrapper around OpenZeppelin's ERC1967Proxy
 */
contract UUPSProxy is ERC1967Proxy {
    /**
     * @notice Initializes the proxy with an implementation contract and initialization data
     * @dev Delegates the initialization call to the implementation with the provided data
     * @param _implementation Address of the initial implementation contract
     * @param _data Initialization data to be passed to the implementation contract
     */
    constructor(address _implementation, bytes memory _data) ERC1967Proxy(_implementation, _data) { }
}