// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IEtherFiSafe {
    /**
     * @notice Verifies signatures against a digest hash until reaching the required threshold
     * @param digestHash The hash of the data that was signed
     * @param signers Array of addresses that supposedly signed the message
     * @param signatures Array of signatures corresponding to the signers
     * @return bool True if enough valid signatures are found to meet the threshold
     * @dev Processes signatures until threshold is met. Invalid signatures are skipped.
     * @custom:throws EmptySigners If the signers array is empty
     * @custom:throws ArrayLengthMismatch If the lengths of signers and signatures arrays do not match
     * @custom:throws InsufficientSigners If the length of signers array is less than the required threshold
     * @custom:throws DuplicateElementFound If the signers array contains duplicate addresses
     * @custom:throws InvalidSigner If a signer is the zero address or not an owner of the safe
     */
    function checkSignatures(bytes32 digestHash, address[] calldata signers, bytes[] calldata signatures) external view returns (bool);

    /**
     * @notice Executes a transaction from an authorized module
     * @dev Allows modules to execute arbitrary transactions on behalf of the safe
     * @param to Array of target addresses for the calls
     * @param values Array of ETH values to send with each call
     * @param data Array of calldata for each call
     * @custom:throws OnlyModules If the caller is not an enabled module
     * @custom:throws CallFailed If any of the calls fail
     */
    function execTransactionFromModule(address[] calldata to, uint256[] calldata values, bytes[] calldata data) external;

    /**
     * @notice Gets the current nonce value
     * @dev Used for replay protection in signatures
     * @return Current nonce value
     */
    function nonce() external view returns (uint256);

    /**
     * @notice Returns all current owners of the safe
     * @dev Implementation of the abstract function from ModuleManager
     * @return address[] Array containing all owner addresses
     */
    function getOwners() external view returns (address[] memory);

    /**
     * @notice Uses a nonce for operations in modules which require a quorum of owners
     * @dev Can only be called by enabled modules
     * @return uint256 The current nonce value before incrementing
     * @custom:throws OnlyModules If the caller is not an enabled module
     */
    function useNonce() external returns (uint256);

    function isAdmin(address account) external view returns (bool); 
}
