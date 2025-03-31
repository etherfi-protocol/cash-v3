// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title Library of utilities for making EIP1271-compliant signature checks
 * @author ether.fi
 * @notice Provides functions to verify signatures from both EOAs and smart contracts implementing EIP-1271
 * @dev Implements signature verification following EIP-1271 standard for smart contracts
 * and standard ECDSA verification for EOAs
 */
library SignatureUtils {
    // bytes4(keccak256("isValidSignature(bytes32,bytes)")
    bytes4 internal constant EIP1271_MAGICVALUE = 0x1626ba7e;

    /// @notice Thrown when an EOA signature is invalid
    error InvalidSigner();
    /// @notice Thrown when an ERC1271 contract signature verification fails
    error InvalidERC1271Signer();

    /**
     * @notice Verifies if a signature is valid according to EIP-1271 standards
     * @dev For EOAs, uses ECDSA recovery. For contracts, calls EIP-1271 isValidSignature
     * @param digestHash The hash of the data that was signed
     * @param signer The address that should have signed the data
     * @param signature The signature bytes
     * @custom:security Consider that contract signatures might have different gas costs
     * @custom:warning The isContract check may return false positives during contract construction
     * @custom:throws InvalidSigner If the EOA signature is invalid
     * @custom:throws InvalidERC1271Signer If the contract signature verification fails
     */
    function checkSignature(bytes32 digestHash, address signer, bytes memory signature) internal view {
        if (isContract(signer)) {
            if (IERC1271(signer).isValidSignature(digestHash, signature) != EIP1271_MAGICVALUE) revert InvalidERC1271Signer();
        } else {
            if (ECDSA.recover(digestHash, signature) != signer) revert InvalidSigner();
        }
    }

    /**
     * @notice Returns whether a signature is valid according to EIP-1271 standards
     * @dev Similar to checkSignature_EIP1271 but returns boolean instead of reverting
     * @param digestHash The hash of the data that was signed
     * @param signer The address that should have signed the data
     * @param signature The signature bytes
     * @return bool True if the signature is valid, false otherwise
     * @custom:warning The isContract check may return false positives during contract construction
     */
    function isValidSignature(bytes32 digestHash, address signer, bytes memory signature) internal view returns (bool) {
        if (isContract(signer)) {
            return IERC1271(signer).isValidSignature(digestHash, signature) == EIP1271_MAGICVALUE;
        } else {
            return ECDSA.recover(digestHash, signature) == signer;
        }
    }

    /**
     * @notice Determines if an address is a contract
     * @dev Uses assembly to check if the address has code
     * @param account The address to check
     * @return bool True if the address has code (is a contract), false otherwise
     * @custom:warning This function returns false for contracts during their construction
     */
    function isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly ("memory-safe") {
            size := extcodesize(account)
        }
        return size > 0;
    }
}
