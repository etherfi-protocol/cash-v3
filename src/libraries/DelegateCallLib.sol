// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library DelegateCallLib {
    /**
     * @notice Performs a delegate call to the target contract
     * @dev Internal function used for bridge adapter calls
     * @param target The address of the contract to delegate call to
     * @param data The calldata to execute
     * @return result The returned data from the delegate call
     */
    function delegateCall(address target, bytes memory data) internal returns (bytes memory result) {
        require(target != address(this), "delegatecall to self");

        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            // Perform delegatecall to the target contract
            let success := delegatecall(gas(), target, add(data, 0x20), mload(data), 0, 0)

            // Get the size of the returned data
            let size := returndatasize()

            // Allocate memory for the return data
            result := mload(0x40)

            // Set the length of the return data
            mstore(result, size)

            // Copy the return data to the allocated memory
            returndatacopy(add(result, 0x20), 0, size)

            // Update the free memory pointer
            mstore(0x40, add(result, add(0x20, size)))

            if iszero(success) { revert(result, returndatasize()) }
        }
    }
}