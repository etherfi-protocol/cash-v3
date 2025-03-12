// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EtherFiSafeBase } from "./EtherFiSafeBase.sol";
import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { SignatureUtils } from "../libraries/SignatureUtils.sol";

/**
 * @title RecoveryManager
 * @author ether.fi
 * @notice Manages recovery functionality for EtherFi safe accounts
 * @dev Implements a multi-signature recovery system with configurable recovery signers
 */
abstract contract RecoveryManager is EtherFiSafeBase {
    using SignatureUtils for bytes32;

    /// @custom:storage-location erc7201:etherfi.storage.RecoveryManager
    struct RecoveryManagerStorage {
        /// @notice Recovery signer assigned by the user
        address userRecoverySigner;
        /// @notice True if recovery is enabled, false if not
        bool isRecoveryEnabled;
        /// @notice Recovery signer address set by the user overriding the EtherFiRecoverySigner
        address overridenSecondRecoverySigner;
        /// @notice Recovery signer address set by the user overriding the ThirdPartyRecoverySigner
        address overridenThirdRecoverySigner;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.RecoveryManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RecoveryManagerStorageLocation = 0x7252096011fe74e542f364eabd3c198d95310417daa86313d329374e00fb6e00;

    /// @notice Emitted when the user recovery signer is updated
    /// @param oldSigner The previous recovery signer address
    /// @param newSigner The new recovery signer address
    event UserRecoverySignerUpdated(address oldSigner, address newSigner);
    
    /// @notice Emitted when the recovery enabled flag is toggled
    /// @param isEnabled The new state of the recovery feature
    event RecoveryEnabledFlagUpdated(bool isEnabled);
    
    /// @notice Emitted when the EtherFi recovery signer is overridden
    /// @param signer The new overriding recovery signer address
    event EtherFiRecoverySignerOverriden(address signer);
    
    /// @notice Emitted when the third-party recovery signer is overridden
    /// @param signer The new overriding third-party recovery signer address
    event ThirdPartyRecoverySignerOverriden(address signer);
    
    /// @notice Emitted when a recovery process is initiated
    /// @param newOwner The address of the new owner after recovery
    /// @param startTime The timestamp when the new owner can take control
    event Recovery(address newOwner, uint256 startTime);
    
    /// @notice Emitted when a recovery process is cancelled
    event RecoveryCancelled();

    /**
     * @dev Returns the storage struct for RecoveryManager
     * @return $ Reference to the RecoveryManagerStorage struct
     * @custom:storage-location Uses ERC-7201 namespace storage pattern
     */
    function _getRecoveryManagerStorage() internal pure returns (RecoveryManagerStorage storage $) {
        assembly {
            $.slot := RecoveryManagerStorageLocation
        }
    }

    /**
     * @notice Sets up the recovery functionality
     * @dev Can only be called once when recovery is not yet enabled
     * @custom:throws RecoveryManagerAlreadyInitialized If recovery has already been initialized
     */
    function _setupRecovery() internal {
        RecoveryManagerStorage storage $ = _getRecoveryManagerStorage();

        if ($.isRecoveryEnabled == true) revert RecoveryManagerAlreadyInitialized();
        $.isRecoveryEnabled = true;
    }

    /**
     * @notice Updates the user's recovery signer with signature verification
     * @param recoverySigner New recovery signer address
     * @param signers Array of addresses that signed the transaction
     * @param signatures Array of corresponding signatures
     * @dev Uses EIP-712 typed data signing for secure multi-signature authorization
     * @custom:throws InvalidSignatures If signature verification fails
     * @custom:throws InvalidInput If the recovery signer is the zero address
     */
    function setUserRecoverySigner(address recoverySigner, address[] calldata signers, bytes[] calldata signatures) external {
        _currentOwner();
        bytes32 structHash = keccak256(abi.encode(SET_USER_RECOVERY_SIGNER_TYPEHASH, recoverySigner, _useNonce()));

        bytes32 digestHash = _hashTypedDataV4(structHash);
        if (!checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
        
        RecoveryManagerStorage storage $ = _getRecoveryManagerStorage();

        if (recoverySigner == address(0)) revert InvalidInput();
        emit UserRecoverySignerUpdated($.userRecoverySigner, recoverySigner);
        $.userRecoverySigner = recoverySigner;
    }

    /**
     * @notice Enables or disables the recovery functionality with signature verification
     * @param shouldEnable True to enable recovery, false to disable
     * @param signers Array of addresses that signed the transaction
     * @param signatures Array of corresponding signatures
     * @dev Uses EIP-712 typed data signing for secure multi-signature authorization
     * @custom:throws InvalidSignatures If signature verification fails
     * @custom:throws InvalidInput If the new state matches the current state
     */
    function toggleRecoveryEnabled(bool shouldEnable, address[] calldata signers, bytes[] calldata signatures) external {
        _currentOwner();
        bytes32 structHash = keccak256(abi.encode(TOGGLE_RECOVERY_ENABLED_TYPEHASH, shouldEnable, _useNonce()));

        bytes32 digestHash = _hashTypedDataV4(structHash);
        if (!checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
        
        RecoveryManagerStorage storage $ = _getRecoveryManagerStorage();

        if (shouldEnable == $.isRecoveryEnabled) revert InvalidInput();
        emit RecoveryEnabledFlagUpdated(shouldEnable);
        $.isRecoveryEnabled = shouldEnable;
    }

    /**
     * @notice Overrides the default recovery signers with custom addresses
     * @param recoverySigners Array of two addresses [EtherFiRecoverySigner, ThirdPartyRecoverySigner]
     * @param signers Array of addresses that signed the transaction
     * @param signatures Array of corresponding signatures
     * @dev Uses EIP-712 typed data signing for secure multi-signature authorization
     * @custom:throws InvalidSignatures If signature verification fails
     */
    function overrideRecoverySigners(address[2] calldata recoverySigners, address[] calldata signers, bytes[] calldata signatures) external {
        _currentOwner();
        bytes32 structHash = keccak256(abi.encode(OVERRIDE_RECOVERY_SIGNERS_TYPEHASH, recoverySigners, _useNonce()));

        bytes32 digestHash = _hashTypedDataV4(structHash);
        if (!checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
        
        RecoveryManagerStorage storage $ = _getRecoveryManagerStorage();

        emit EtherFiRecoverySignerOverriden(recoverySigners[0]);
        $.overridenSecondRecoverySigner = recoverySigners[0];

        emit ThirdPartyRecoverySignerOverriden(recoverySigners[1]);
        $.overridenThirdRecoverySigner = recoverySigners[1];
    }

    /**
     * @notice Initiates the recovery process to change ownership of the safe
     * @param newOwner Address of the new owner
     * @param recoverySignerIndices Indices of the recovery signers [0-2]
     * @param signatures Signatures from the selected recovery signers
     * @dev Requires signatures from two different recovery signers
     * @custom:throws RecoveryDisabled If recovery functionality is not enabled
     * @custom:throws InvalidRecoverySignature If any signature verification fails
     */
    function recoverSafe(address newOwner, uint256[2] calldata recoverySignerIndices, bytes[2] calldata signatures) external {
        _currentOwner();
        if (!isRecoveryEnabled()) revert RecoveryDisabled();
        bytes32 structHash = keccak256(abi.encode(RECOVER_SAFE_TYPEHASH, newOwner, _useNonce()));
        bytes32 digestHash = _hashTypedDataV4(structHash);

        _checkSig(digestHash, _getRecoverySignerAtIndex(recoverySignerIndices[0]), signatures[0]);
        _checkSig(digestHash, _getRecoverySignerAtIndex(recoverySignerIndices[1]), signatures[1]);

        uint256 incomingOwnerStartTime = block.timestamp + dataProvider.getRecoveryDelayPeriod();
        _setIncomingOwner(newOwner, incomingOwnerStartTime);

        emit Recovery(newOwner, incomingOwnerStartTime);
    }

    /**
     * @notice Cancels an ongoing recovery process with signature verification
     * @param signers Array of addresses that signed the transaction
     * @param signatures Array of corresponding signatures
     * @dev Uses EIP-712 typed data signing for secure multi-signature authorization
     * @custom:throws InvalidSignatures If signature verification fails
     */
    function cancelRecovery(address[] calldata signers, bytes[] calldata signatures) external {
        _currentOwner();
        bytes32 structHash = keccak256(abi.encode(CANCEL_RECOVERY_TYPEHASH, _useNonce()));
        bytes32 digestHash = _hashTypedDataV4(structHash);
        if (!checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();

        _removeIncomingOwner();

        emit RecoveryCancelled();
    }

    /**
     * @notice Returns all three recovery signers for the safe
     * @return User recovery signer, EtherFi recovery signer, Third-party recovery signer
     * @dev If override addresses are set, they will be returned instead of default signers
     */
    function getRecoverySigners() public view returns (address, address, address) {
        return (_getRecoverySignerAtIndex(0), _getRecoverySignerAtIndex(1), _getRecoverySignerAtIndex(2));   
    }

    /**
     * @notice Verifies if a signature is valid for a given signer and digest hash
     * @param digestHash The hash of the data that was signed
     * @param signer The address that supposedly signed the message
     * @param signature The signature to verify
     * @dev Internal utility function for signature verification
     * @custom:throws InvalidRecoverySignature If the signature is invalid
     */
    function _checkSig(bytes32 digestHash, address signer, bytes calldata signature) internal view {
        if (!digestHash.isValidSignature(signer, signature)) revert InvalidRecoverySignature();
    }

    /**
     * @notice Returns the recovery signer at a specific index
     * @param index The index of the recovery signer (0: user, 1: EtherFi, 2: third-party)
     * @return The address of the recovery signer at the specified index
     * @dev Handles override logic for EtherFi and third-party signers
     * @custom:throws InvalidInput If the index is greater than 2
     * @custom:throws InvalidUserRecoverySigner If the user recovery signer is not set
     */
    function _getRecoverySignerAtIndex(uint256 index) internal view returns (address) {
        RecoveryManagerStorage storage $ = _getRecoveryManagerStorage();

        if (index > 2) revert InvalidInput();

        if (index == 0) {
            if ($.userRecoverySigner == address(0)) revert InvalidUserRecoverySigner(); 
            return $.userRecoverySigner;
        } 

        if (index == 1) {
            if ($.overridenSecondRecoverySigner != address(0)) return $.overridenSecondRecoverySigner;
            else return dataProvider.getEtherFiRecoverySigner();
        }

        // if index == 2
        if ($.overridenThirdRecoverySigner != address(0)) return $.overridenThirdRecoverySigner;
        else return dataProvider.getThirdPartyRecoverySigner();
        
    }

    /**
     * @notice Checks if the recovery functionality is enabled
     * @return Boolean indicating whether recovery is enabled
     */
    function isRecoveryEnabled() public view returns (bool) {
        return _getRecoveryManagerStorage().isRecoveryEnabled;
    }
}