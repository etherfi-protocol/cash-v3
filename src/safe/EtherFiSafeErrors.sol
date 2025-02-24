// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

abstract contract EtherFiSafeErrors {
    /// @notice Thrown when an empty modules array is provided
    error InvalidInput();

    /// @notice Thrown when modules and shouldWhitelist arrays have different lengths
    error ArrayLengthMismatch();

    /// @notice Thrown when a module address is zero
    /// @param index Index of the invalid module in the array 
    error InvalidModule(uint256 index);

    /// @notice Thrown when a signer at the given index is invalid
    error InvalidSigner(uint256 index);

    /// @notice Thrown when the signature verification fails
    error InvalidSignatures();

    /// @notice Thrown when there are not enough signers to meet the threshold
    error InsufficientSigners();

    /// @notice Thrown when no signers are provided
    error EmptySigners();

    /// @notice Thrown when adding address(0) as owner
    error InvalidOwnerAddress(uint256 index);

    /// @notice Thrown when removing all owners
    error AllOwnersRemoved();

    /// @notice Thrown when owners are less than threshold
    error OwnersLessThanThreshold();

    /// @notice Throws when threshold is either 0 or greater than length of owners
    error InvalidThreshold();

    /// @notice Throws when the multisig is already setup
    error MultiSigAlreadySetup();

    /// @notice Throws when trying to remove Cash Module
    /// @param index Index of the cash module in the array
    error CannotRemoveCashModule(uint256 index);

    /// @notice Throws when trying to add an unsupported module to whitelist 
    /// @param index Index of the unsupported module in the array
    error UnsupportedModule(uint256 index);

    /// @notice Throws when trying to reinit modules
    error ModulesAlreadySetup();
}
