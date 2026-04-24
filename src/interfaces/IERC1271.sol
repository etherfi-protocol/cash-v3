// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice EIP-1271 interface for smart contract signature validation
interface IERC1271 {
    /// @notice Validates a signature for a given hash
    /// @param hash The hash that was signed
    /// @param signature The signature bytes
    /// @return magicValue 0x1626ba7e if valid, any other value if invalid
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}
