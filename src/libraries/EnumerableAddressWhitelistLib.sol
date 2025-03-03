// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { ArrayDeDupLib } from "./ArrayDedupLib.sol";

library EnumerableAddressWhitelistLib {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using ArrayDeDupLib for address[];

    error InvalidInput();
    error ArrayLengthMismatch();
    error InvalidAddress(uint256 index);

    function configure(EnumerableSetLib.AddressSet storage set, address[] calldata addrs, bool[] calldata shouldAdd) internal {
        uint256 len = addrs.length;
        if (len == 0) revert InvalidInput();
        if (len > 1) addrs.checkDuplicates();
        if (len != shouldAdd.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < len;) {
            if (addrs[i] == address(0)) revert InvalidAddress(i);

            if (shouldAdd[i] && !set.contains(addrs[i])) set.add(addrs[i]);
            if (!shouldAdd[i] && set.contains(addrs[i])) set.remove(addrs[i]);

            unchecked {
                ++i;
            }
        }
    }
}
