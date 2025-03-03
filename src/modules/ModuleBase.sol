// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { SignatureUtils } from "../libraries/SignatureUtils.sol";

/**
 * @title ModuleBase
 * @author ether.fi
 * @notice Base contract for implementing modules with admin functionality
 * @dev Provides common functionality for modules including admin management and signature verification
 *      Uses ERC-7201 for namespace storage pattern
 */
contract ModuleBase {
    using SignatureUtils for bytes32;

    IEtherFiDataProvider public immutable etherFiDataProvider;

    /// @notice Throws when the msg.sender is not an admin to the safe
    error OnlySafeAdmin();
    /// @notice Thrown when the input is invalid
    error InvalidInput();
    /// @notice Thrown when the signature verification fails
    error InvalidSignature();
    /// @notice Thrown when there is an array length mismatch
    error ArrayLengthMismatch();

    /// @custom:storage-location erc7201:etherfi.storage.ModuleBaseStorage
    struct ModuleBaseStorage {
        /// @notice Mapping of Safe addresses to their nonces for replay protection
        mapping(address safe => uint256 nonce) nonces;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.ModuleBaseStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ModuleBaseStorageLocation = 0x9425b2e03e09da4c20ff7a465da264f7a02bf7079e1dbb47fce0436e1d206d00;

    constructor(address _etherFiDataProvider) {
        if (_etherFiDataProvider == address(0)) revert InvalidInput();
        etherFiDataProvider = IEtherFiDataProvider(_etherFiDataProvider);
    }

    /**
     * @dev Returns the storage struct from the specified storage slot
     * @return $ Reference to the ModuleBaseStorage struct
     */
    function _getModuleBaseStorage() internal pure returns (ModuleBaseStorage storage $) {
        assembly {
            $.slot := ModuleBaseStorageLocation
        }
    }

    /**
     * @notice Returns the current nonce for a Safe
     * @param safe The Safe address to query
     * @return Current nonce value
     * @dev Nonces are used to prevent signature replay attacks
     */
    function getNonce(address safe) public view returns (uint256) {
        return _getModuleBaseStorage().nonces[safe];
    }

    /**
     * @dev Uses and increments the nonce for a Safe
     * @param safe The Safe address
     * @return The nonce value before incrementing
     */
    function _useNonce(address safe) internal returns (uint256) {
        ModuleBaseStorage storage $ = _getModuleBaseStorage();

        unchecked {
            return $.nonces[safe]++;
        }
    }

    /**
     * @dev Verifies if a signature is valid and made by an admin of the safe
     * @param digestHash The message hash that was signed
     * @param signer The address that supposedly signed the message
     * @param signature The signature to verify
     * @custom:throws SignerIsNotAnAdmin If the signer is not an admin of the Safe
     * @custom:throws InvalidSignature If the signature is invalid
     */
    function _verifyAdminSig(bytes32 digestHash, address signer, bytes calldata signature) internal view {
        if (!digestHash.isValidSignature(signer, signature)) revert InvalidSignature();
    }

    /**
     * @dev Ensures that the caller is an admin for the specified Safe
     * @param safe The Safe address to check admin status for
     */
    modifier onlySafeAdmin(address safe, address account) {
        if (!etherFiDataProvider.roleRegistry().isSafeAdmin(safe, account)) revert OnlySafeAdmin();
        _;
    }

    /**
     * @dev Ensures that the account is an instance of the deployed EtherfiSafe
     * @param account The account address to check
     */
    modifier onlyEtherFiSafe(address account) {
        etherFiDataProvider.onlyEtherFiSafe(account);
        _;
    }

    function setupModule(bytes calldata data) external virtual { }
}
