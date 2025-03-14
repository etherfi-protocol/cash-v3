// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ArrayDeDupLib
 * @author ether.fi
 * @notice Library for checking and handling duplicate elements in arrays
 * @dev Provides utility functions to verify array uniqueness
 */
library ArrayDeDupLib {
    /**
     * @notice Thrown when a duplicate element is found in an array that requires unique elements
     */
    error DuplicateElementFound();

    /**
     * @notice Checks if an array of addresses contains duplicate elements
     * @dev Uses an O(n²) algorithm that's efficient for small arrays
     * @param addresses Array of addresses to check for duplicates
     * @custom:throws DuplicateElementFound If a duplicate address is found in the array
     */
    function checkDuplicates(address[] memory addresses) internal pure {
        uint256 length = addresses.length;
        if (length <= 1) return;

        address[] memory seen = new address[](length);

        for (uint256 i = 0; i < length;) {
            address current = addresses[i];

            for (uint256 j = 0; j < i;) {
                if (current == seen[j]) revert DuplicateElementFound();
                unchecked {
                    ++j;
                }
            }

            seen[i] = current;
            unchecked {
                ++i;
            }
        }
    }
}