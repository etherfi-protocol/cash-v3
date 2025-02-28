// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library ArrayDeDupLib {
    error DuplicateElementFound();

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
