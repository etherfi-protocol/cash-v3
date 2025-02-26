// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IModule {
    /**
     * @notice Configures admins for a Safe with signature verification
     * @param safe The Safe address to configure admins for
     * @param accounts Array of admin addresses to configure
     * @param shouldAdd Array indicating whether to add or remove each admin
     * @param signers Array of addresses that signed the transaction
     * @param signatures Array of corresponding signatures
     * @dev Validates signatures using the Safe's checkSignatures function
     * @custom:throws EmptyInput If accounts array is empty
     * @custom:throws ArrayLengthMismatch If arrays have different lengths
     * @custom:throws InvalidAddress If any account address is zero
     * @custom:throws InvalidSignature If signature verification fails
     */
    function configureAdmins(address safe, address[] calldata accounts, bool[] calldata shouldAdd, address[] calldata signers, bytes[] calldata signatures) external;

    function CONFIG_ADMIN() external view returns (bytes32);
    function ADMIN_ROLE() external view returns (bytes32);
    function getNonce(address safe) external view returns (uint256);
}
