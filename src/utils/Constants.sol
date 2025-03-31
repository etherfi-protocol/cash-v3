// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title Constants
 * @author ether.fi
 * @notice Contract that defines commonly used constants across the ether.fi protocol
 * @dev This contract is not meant to be deployed but to be inherited by other contracts
 */
contract Constants {
    /**
     * @notice Special address used to represent native ETH in the protocol
     * @dev This address is used as a marker since ETH is not an ERC20 token
     */
    address public constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
}