// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { ArrayDeDupLib } from "./ArrayDeDupLib.sol";

/**
 * @title EnumerableAddressWhitelistLib
 * @author ether.fi
 * @notice Library for managing address whitelists with enumeration capabilities
 * @dev Leverages Solady's EnumerableSetLib for storage efficiency and ArrayDeDupLib for input validation
 */
library EnumerableAddressWhitelistLib {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using ArrayDeDupLib for address[];

    /**
     * @notice Thrown when input parameters are invalid or empty
     */
    error InvalidInput();
    
    /**
     * @notice Thrown when provided arrays have different lengths
     */
    error ArrayLengthMismatch();
    
    /**
     * @notice Thrown when an invalid address is provided at a specific index
     * @param index The position in the array where the invalid address was found
     */
    error InvalidAddress(uint256 index);

    /**
     * @notice Configures a set of addresses by adding or removing them based on boolean flags
     * @dev Checks for duplicate addresses and validates inputs before modifying the set
     * @param set The EnumerableSetLib.AddressSet to modify
     * @param addrs Array of addresses to add or remove
     * @param shouldAdd Array of boolean flags indicating whether each address should be added (true) or removed (false)
     * @custom:throws InvalidInput If the arrays are empty
     * @custom:throws ArrayLengthMismatch If the arrays have different lengths
     * @custom:throws InvalidAddress If any address is the zero address
     * @custom:throws DuplicateElementFound If any address appears more than once in the addrs array
     */
    function configure(EnumerableSetLib.AddressSet storage set, address[] calldata addrs, bool[] calldata shouldAdd) internal {
        uint256 len = addrs.length;
        if (len == 0) revert InvalidInput();
        if (len != shouldAdd.length) revert ArrayLengthMismatch();
        if (len > 1) addrs.checkDuplicates();

        // Use unchecked for the entire loop to save gas on overflow checks
        unchecked {
            for (uint256 i; i < len; ++i) {
                if (addrs[i] == address(0)) revert InvalidAddress(i);

                // Direct condition checks instead of nested ifs for better gas optimization
                bool contains = set.contains(addrs[i]);
                if (shouldAdd[i]) {
                    if (!contains) set.add(addrs[i]);
                } else {
                    if (contains) set.remove(addrs[i]);
                }
            }
        }
    }
}