// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { EnumerableAddressWhitelistLib } from "../libraries/EnumerableAddressWhitelistLib.sol";
import { EtherFiSafeBase } from "./EtherFiSafeBase.sol";
import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { SignatureUtils } from "../libraries/SignatureUtils.sol";
import { ArrayDeDupLib } from "../libraries/ArrayDeDupLib.sol";

/**
 * @title RecoveryManager
 * @author ether.fi
 * @notice Manages recovery functionality for EtherFi safe accounts
 * @dev Implements a multi-signature recovery system with configurable recovery signers
 */
abstract contract RecoveryManager is EtherFiSafeBase {
    using SignatureUtils for bytes32;
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using ArrayDeDupLib for address[];

    /// @custom:storage-location erc7201:etherfi.storage.RecoveryManager
    struct RecoveryManagerStorage {
        /// @notice Set of recovery signers added by the user
        EnumerableSetLib.AddressSet userRecoverySigners;
        /// @notice Number of signatures required to perform a recovery
        uint8 recoveryThreshold;
        /// @notice True if recovery is enabled, false if not
        bool isRecoveryEnabled;
        /// @notice Recovery signer address set by the user overriding the EtherFiRecoverySigner
        address overridenEtherFiRecoverySigner;
        /// @notice Recovery signer address set by the user overriding the ThirdPartyRecoverySigner
        address overridenThirdPartyRecoverySigner;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.RecoveryManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RecoveryManagerStorageLocation = 0x7252096011fe74e542f364eabd3c198d95310417daa86313d329374e00fb6e00;

    /// @notice Emitted when recovery signers are added or removed
    /// @param recoverySigners Array of recovery signer addresses that were configured
    /// @param shouldAdd Array indicating whether each recovery signer was added (true) or removed (false)
    event RecoverySignersConfigured(address[] recoverySigners, bool[] shouldAdd);
    
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

    /// @notice Emitted when the recovery threshold is updated
    /// @param oldThreshold Previous threshold value
    /// @param newThreshold New threshold value
    event RecoveryThresholdSet(uint8 oldThreshold, uint8 newThreshold);

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

        if ($.isRecoveryEnabled == true && $.recoveryThreshold > 0) revert RecoveryManagerAlreadyInitialized();
        $.isRecoveryEnabled = true;
        $.recoveryThreshold = 2;
    }

    /**
     * @notice Updates user recovery signers with secure signature verification
     * @param recoverySigners Array of recovery signer addresses to modify
     * @param shouldAdd Array indicating whether to add (true) or remove (false) each signer
     * @param signers Array of owner addresses that signed this transaction
     * @param signatures Array of corresponding signatures from the signers
     * @dev Modifies the set of user recovery signers based on specified actions
     * @custom:throws InvalidSignatures If the provided signatures are invalid
     * @custom:throws RecoverySignersLengthLessThanThreshold If modifying signers would result in too few available signers for the current threshold
     */
    function setUserRecoverySigners(address[] calldata recoverySigners, bool[] calldata shouldAdd, address[] calldata signers, bytes[] calldata signatures) external {
        _currentOwner();
        bytes32 structHash = keccak256(abi.encode(SET_USER_RECOVERY_SIGNERS_TYPEHASH, keccak256(abi.encodePacked(recoverySigners)), keccak256(abi.encodePacked(shouldAdd)), _useNonce()));

        bytes32 digestHash = _hashTypedDataV4(structHash);
        if (!checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
        
        RecoveryManagerStorage storage $ = _getRecoveryManagerStorage();

        EnumerableAddressWhitelistLib.configure($.userRecoverySigners, recoverySigners, shouldAdd);

        emit RecoverySignersConfigured(recoverySigners, shouldAdd);
        
        if ($.recoveryThreshold > 2 && $.recoveryThreshold - 2 > $.userRecoverySigners.length()) revert RecoverySignersLengthLessThanThreshold();
    }

    /**
     * @notice Updates the number of signatures required for recovery
     * @param threshold New threshold value
     * @param signers Array of owner addresses that signed this transaction
     * @param signatures Array of corresponding signatures from the signers
     * @dev Sets a new recovery threshold with proper owner authorization
     * @custom:throws InvalidSignatures If the provided signatures are invalid
     * @custom:throws RecoverySignersLengthLessThanThreshold If the new threshold exceeds the number of available recovery signers
     */
    function setRecoveryThreshold(uint8 threshold, address[] calldata signers, bytes[] calldata signatures) external {
        _currentOwner();
        bytes32 structHash = keccak256(abi.encode(SET_RECOVERY_THRESHOLD_TYPEHASH, threshold, _useNonce()));
        bytes32 digestHash = _hashTypedDataV4(structHash);
        if (!checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
        
        RecoveryManagerStorage storage $ = _getRecoveryManagerStorage();

        if (threshold > 2 && threshold - 2 > $.userRecoverySigners.length()) revert RecoverySignersLengthLessThanThreshold();

        emit RecoveryThresholdSet($.recoveryThreshold, threshold);
        $.recoveryThreshold = threshold;
    }

    /**
     * @notice Enables or disables the recovery functionality with signature verification
     * @param shouldEnable True to enable recovery, false to disable
     * @param signers Array of owner addresses that signed this transaction
     * @param signatures Array of corresponding signatures from the signers
     * @dev Toggles recovery functionality on or off with proper owner authorization
     * @custom:throws InvalidSignatures If the provided signatures are invalid
     * @custom:throws InvalidInput If attempting to set the state to its current value
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
     * @param signers Array of owner addresses that signed this transaction
     * @param signatures Array of corresponding signatures from the signers
     * @dev Replaces the default protocol-level recovery signers with custom ones
     * @custom:throws InvalidSignatures If the provided signatures are invalid
     */
    function overrideRecoverySigners(address[2] calldata recoverySigners, address[] calldata signers, bytes[] calldata signatures) external {
        _currentOwner();

        bytes32 recoverySignersHash = keccak256(abi.encodePacked(
            keccak256(abi.encode(recoverySigners[0])),
            keccak256(abi.encode(recoverySigners[1]))
        ));

        bytes32 structHash = keccak256(abi.encode(OVERRIDE_RECOVERY_SIGNERS_TYPEHASH, recoverySignersHash, _useNonce()));

        bytes32 digestHash = _hashTypedDataV4(structHash);
        if (!checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
        
        RecoveryManagerStorage storage $ = _getRecoveryManagerStorage();

        if ($.overridenEtherFiRecoverySigner != recoverySigners[0]) {
            emit EtherFiRecoverySignerOverriden(recoverySigners[0]);
            $.overridenEtherFiRecoverySigner = recoverySigners[0];
        }

        if ($.overridenThirdPartyRecoverySigner != recoverySigners[1]) {
            emit ThirdPartyRecoverySignerOverriden(recoverySigners[1]);
            $.overridenThirdPartyRecoverySigner = recoverySigners[1];
        }
    }

    /**
     * @notice Initiates the recovery process to change ownership of the safe
     * @param newOwner Address of the new owner
     * @param recoverySigners Addresses of the recovery signers providing authorization
     * @param signatures Signatures from the recovery signers
     * @dev Starts a recovery process with proper validation and timelock
     * @custom:throws RecoveryDisabled If recovery functionality is not enabled
     * @custom:throws InvalidInput If the new owner is the zero address
     * @custom:throws ArrayLengthMismatch If the signer and signature arrays have different lengths
     * @custom:throws InsufficientRecoverySignatures If fewer signers than the threshold are provided
     * @custom:throws InvalidRecoverySigner If any of the provided signers is not a valid recovery signer
     * @custom:throws InvalidRecoverySignatures If not enough valid signatures are provided
     */
    function recoverSafe(address newOwner, address[] calldata recoverySigners, bytes[] calldata signatures) external {
        _currentOwner();

        RecoveryManagerStorage storage $ = _getRecoveryManagerStorage();

        if (!$.isRecoveryEnabled) revert RecoveryDisabled();
        if (newOwner == address(0)) revert InvalidInput();
        uint256 len = recoverySigners.length;
        if (len != signatures.length) revert ArrayLengthMismatch();
        if (len < $.recoveryThreshold) revert InsufficientRecoverySignatures();

        recoverySigners.checkDuplicates();
        
        bytes32 structHash = keccak256(abi.encode(RECOVER_SAFE_TYPEHASH, newOwner, _useNonce()));
        bytes32 digestHash = _hashTypedDataV4(structHash);
        uint256 validSignatures = 0;

        for (uint256 i = 0; i < len; ) {
            if (!isRecoverySigner(recoverySigners[i])) revert InvalidRecoverySigner(i);
            if (digestHash.isValidSignature(recoverySigners[i], signatures[i])) validSignatures++;

            if (validSignatures == $.recoveryThreshold) break;   
            unchecked {
                ++i;
            }
        }

        if (validSignatures != $.recoveryThreshold) revert InvalidRecoverySignatures();

        uint256 incomingOwnerStartTime = block.timestamp + dataProvider.getRecoveryDelayPeriod();
        _setIncomingOwner(newOwner, incomingOwnerStartTime);

        emit Recovery(newOwner, incomingOwnerStartTime);
    }

    /**
     * @notice Checks if an address is a valid recovery signer
     * @param signer Address to verify
     * @return bool True if the address is a valid recovery signer
     * @dev Validates against overridden signers, default signers from the data provider, and user-added signers
     * @custom:throws InvalidInput If the provided signer is the zero address
     */
    function isRecoverySigner(address signer) public view returns (bool) {
        if (signer == address(0)) revert InvalidInput();
        RecoveryManagerStorage storage $ = _getRecoveryManagerStorage();

        address recoverySigner1 = $.overridenEtherFiRecoverySigner;
        address recoverySigner2 = $.overridenThirdPartyRecoverySigner;
        if (recoverySigner1 == address(0)) recoverySigner1 = dataProvider.getEtherFiRecoverySigner();
        if (recoverySigner2 == address(0)) recoverySigner2 = dataProvider.getThirdPartyRecoverySigner();

        if ($.userRecoverySigners.contains(signer) || recoverySigner1 == signer || recoverySigner2 == signer) return true;
        else return false;
    }

    /**
     * @notice Cancels an ongoing recovery process with signature verification
     * @param signers Array of owner addresses that signed this transaction
     * @param signatures Array of corresponding signatures from the signers
     * @dev Reverts an in-progress recovery with proper owner authorization
     * @custom:throws InvalidSignatures If the provided signatures are invalid
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
     * @notice Returns a list of all recovery signers for this safe
     * @return Array of all recovery signer addresses, including default and user-added signers
     * @dev Combines default signers (or their overrides) with user-added signers
     */
    function getRecoverySigners() public view returns (address[] memory) {
        RecoveryManagerStorage storage $ = _getRecoveryManagerStorage();

        address recoverySigner1 = $.overridenEtherFiRecoverySigner;
        address recoverySigner2 = $.overridenThirdPartyRecoverySigner;
        if (recoverySigner1 == address(0)) recoverySigner1 = dataProvider.getEtherFiRecoverySigner();
        if (recoverySigner2 == address(0)) recoverySigner2 = dataProvider.getThirdPartyRecoverySigner();

        uint256 len = $.userRecoverySigners.length();
        
        address[] memory recoverySigners = new address[](len + 2);
        recoverySigners[0] = recoverySigner1;
        recoverySigners[1] = recoverySigner2;

        for (uint256 i = 0; i < len; ) {
            recoverySigners[i + 2] = $.userRecoverySigners.at(i);
            unchecked {
                ++i;
            }
        }

        return recoverySigners;
    }

    /**
     * @notice Checks if the recovery functionality is enabled
     * @return Boolean indicating whether recovery is enabled
     */
    function isRecoveryEnabled() public view returns (bool) {
        return _getRecoveryManagerStorage().isRecoveryEnabled;
    }

    /**
     * @notice Returns the current recovery threshold
     * @return The number of recovery signatures required to initiate recovery
     * @dev This threshold determines how many valid recovery signer signatures are needed
     */
    function getRecoveryThreshold() public view returns (uint8) {
        return _getRecoveryManagerStorage().recoveryThreshold;
    }

    /**
     * @notice Returns the current recovery status information
     * @return isEnabled Whether recovery is currently enabled
     * @return isPending Whether there is a pending recovery in progress
     * @return incomingOwner The address of the new owner if recovery is pending
     * @return timelockExpiration The timestamp when ownership transition will occur if recovery is pending
     * @dev Provides comprehensive information about the current recovery state
     */
    function getRecoveryStatus() public view returns (bool isEnabled, bool isPending, address incomingOwner, uint256 timelockExpiration) {
        RecoveryManagerStorage storage $ = _getRecoveryManagerStorage();
        address _incomingOwner = getIncomingOwner();
        uint256 _timelockExpiration = getIncomingOwnerStartTime();
        
        return ($.isRecoveryEnabled, _incomingOwner != address(0) && _timelockExpiration > 0, _incomingOwner, _timelockExpiration);
    }
}