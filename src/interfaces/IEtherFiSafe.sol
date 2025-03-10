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

    function execTransactionFromModule(address[] calldata to, uint256[] calldata value, bytes[] calldata data) external;

    function nonce() external view returns (uint256);

    function getOwners() external view returns (address[] memory);

    function useNonce() external returns (uint256);
}
