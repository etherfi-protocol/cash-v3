// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { ArrayDeDupLib } from "../libraries/ArrayDeDupLib.sol";
import { EnumerableAddressWhitelistLib } from "../libraries/EnumerableAddressWhitelistLib.sol";
import { SignatureUtils } from "../libraries/SignatureUtils.sol";
import { EtherFiSafeBase } from "./EtherFiSafeBase.sol";

/**
 * @title MultiSig
 * @author ether.fi
 * @notice Implements multi-sig functionality with configurable owners and threshold
 */
abstract contract MultiSig is EtherFiSafeBase {
    using SignatureUtils for bytes32;
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using ArrayDeDupLib for address[];

    /// @custom:storage-location erc7201:etherfi.storage.MultiSig
    struct MultiSigStorage {
        /// @notice Set containing addresses of all the owners to the safe
        EnumerableSetLib.AddressSet owners;
        /// @notice Multisig threshold for the safe
        uint8 threshold;
        /// @notice Timelock for new owner after recovery
        uint256 incomingOwnerStartTime;
        /// @notice New owner after recovery
        address incomingOwner;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.MultiSig")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MultiSigStorageLocation = 0xa70a07defbd4aa681e6834c0c45f48279262d903d23e46456d62b7d6ef638000;

    /// @notice Emitted when the threshold value is changed
    /// @param oldThreshold Previous threshold value
    /// @param newThreshold New threshold value
    event ThresholdSet(uint8 oldThreshold, uint8 newThreshold);

    /// @notice Emitted when owners are added or removed
    /// @param owners Array of owner addresses that were configured
    /// @param shouldAdd Array indicating whether each owner was added (true) or removed (false)
    event OwnersConfigured(address[] owners, bool[] shouldAdd);

    /// @notice Emitted when a new incoming owner is set after recovery
    /// @param incomingOwner Address of the incoming owner
    /// @param startTime Timestamp when the incoming owner can take effect
    event IncomingOwnerSet(address incomingOwner, uint256 startTime);

    /// @notice Emitted when an account is recovered after timelock period is complete
    /// @param newOwner Address of the new owner
    event AccountRecovered(address newOwner);

    /**
     * @dev Returns the storage struct for MultiSig
     * @return $ Reference to the MultiSigStorage struct
     * @custom:storage-location Uses ERC-7201 namespace storage pattern
     */
    function _getMultiSigStorage() internal pure returns (MultiSigStorage storage $) {
        assembly {
            $.slot := MultiSigStorageLocation
        }
    }

    /**
     * @notice Sets up initial owners and threshold for the safe
     * @param _owners Array of initial owner addresses
     * @param _threshold Initial signature threshold
     * @dev Can only be called once when owners set is empty
     * @custom:throws MultiSigAlreadySetup If the safe has already been set up
     * @custom:throws InvalidThreshold If threshold is 0 or greater than number of owners
     * @custom:throws InvalidInput If owners array is empty
     * @custom:throws InvalidOwnerAddress(index) If any owner address is zero
     * @custom:throws DuplicateElementFound If owner addresses are repeated int the array
     */
    function _setupMultiSig(address[] calldata _owners, uint8 _threshold) internal {
        MultiSigStorage storage $ = _getMultiSigStorage();

        if ($.owners.length() > 0) revert MultiSigAlreadySetup();

        uint256 len = _owners.length;
        if (_threshold == 0 || _threshold > len) revert InvalidThreshold();

        emit ThresholdSet(0, _threshold);
        $.threshold = _threshold;

        if (len == 0) revert InvalidInput();
        if (len > 1) _owners.checkDuplicates();
        bool[] memory _shouldAdd = new bool[](len);

        for (uint256 i = 0; i < len;) {
            if (_owners[i] == address(0)) revert InvalidOwnerAddress(i);
            $.owners.add(_owners[i]);
            _shouldAdd[i] = true;
            unchecked {
                ++i;
            }
        }

        emit OwnersConfigured(_owners, _shouldAdd);
    }

    /**
     * @notice Updates the signature threshold with owner signatures
     * @dev Uses EIP-712 typed data signing for secure multi-signature authorization
     * @param threshold New threshold value
     * @param signers Array of addresses that signed the transaction
     * @param signatures Array of corresponding signatures
     * @custom:throws InvalidThreshold If threshold is 0 or greater than number of owners
     * @custom:throws InvalidSignatures If signature verification fails
     */
    function setThreshold(uint8 threshold, address[] calldata signers, bytes[] calldata signatures) external {
        _currentOwner();
        bytes32 structHash = keccak256(abi.encode(SET_THRESHOLD_TYPEHASH, threshold, _useNonce()));

        bytes32 digestHash = _hashTypedDataV4(structHash);
        if (!checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
        _setThreshold(threshold);
    }

    /**
     * @notice Configures safe owners with signature verification
     * @dev Uses EIP-712 typed data signing for secure multi-signature authorization
     * @param owners Array of owner addresses to configure
     * @param shouldAdd Array indicating whether to add or remove each owner
     * @param signers Array of addresses that signed the transaction
     * @param signatures Array of corresponding signatures
     * @custom:throws InvalidInput If owners array is empty
     * @custom:throws ArrayLengthMismatch If arrays have different lengths
     * @custom:throws InvalidAddress(index) If any owner address is zero
     * @custom:throws DuplicateElementFound If owner addresses are repeated int the array
     * @custom:throws AllOwnersRemoved If operation would remove all owners
     * @custom:throws OwnersLessThanThreshold If owners would be less than threshold
     * @custom:throws InvalidSignatures If signature verification fails
     */
    function configureOwners(address[] calldata owners, bool[] calldata shouldAdd, uint8 threshold, address[] calldata signers, bytes[] calldata signatures) external {
        _currentOwner();
        bytes32 structHash = keccak256(abi.encode(CONFIGURE_OWNERS_TYPEHASH, keccak256(abi.encodePacked(owners)), keccak256(abi.encodePacked(shouldAdd)), threshold, _useNonce()));

        bytes32 digestHash = _hashTypedDataV4(structHash);
        if (!checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
        _configureOwners(owners, shouldAdd, threshold);
        _configureAdmin(owners, shouldAdd);
    }

    /**
     * @notice Updates the signature threshold
     * @param _threshold New threshold value
     * @dev Threshold must be greater than 0 and not exceed the number of owners
     * @custom:throws InvalidThreshold If threshold is 0 or greater than number of owners
     */
    function _setThreshold(uint8 _threshold) internal {
        MultiSigStorage storage $ = _getMultiSigStorage();
        if (_threshold == 0 || _threshold > $.owners.length()) revert InvalidThreshold();

        emit ThresholdSet($.threshold, _threshold);
        $.threshold = _threshold;
    }

    /**
     * @notice Configures safe owners by adding or removing them
     * @param _owners Array of owner addresses to configure
     * @param _shouldAdd Array indicating whether to add (true) or remove (false) each owner
     * @param _threshold New threshold value
     * @dev Cannot remove all owners or reduce owners below threshold
     * @custom:throws InvalidInput If owners array is empty
     * @custom:throws InvalidThreshold If threshold is 0 or greater than number of owners
     * @custom:throws ArrayLengthMismatch If owners and shouldAdd arrays have different lengths
     * @custom:throws InvalidAddress(index) If any owner address is zero
     * @custom:throws DuplicateElementFound If owner addresses are repeated int the array
     * @custom:throws AllOwnersRemoved If operation would remove all owners
     * @custom:throws OwnersLessThanThreshold If operation would reduce owners below threshold
     */
    function _configureOwners(address[] calldata _owners, bool[] calldata _shouldAdd, uint8 _threshold) internal {
        MultiSigStorage storage $ = _getMultiSigStorage();

        if (_threshold == 0) revert InvalidThreshold();

        EnumerableAddressWhitelistLib.configure($.owners, _owners, _shouldAdd);
        $.threshold = _threshold;

        if ($.owners.length() == 0) revert AllOwnersRemoved();
        if ($.owners.length() < $.threshold) revert OwnersLessThanThreshold();

        emit OwnersConfigured(_owners, _shouldAdd);
    }

    /**
     * @notice Sets a new incoming owner with associated timelock
     * @param incomingOwner Address of the new incoming owner
     * @param startTime Timestamp from which the new owner can take effect
     * @dev This is part of the owner recovery mechanism
     */
    function _setIncomingOwner(address incomingOwner, uint256 startTime) internal override {
        MultiSigStorage storage $ = _getMultiSigStorage();

        emit IncomingOwnerSet(incomingOwner, startTime);
        $.incomingOwner = incomingOwner;
        $.incomingOwnerStartTime = startTime;
    }

    /**
     * @notice Removes the incoming owner and resets recovery timelock
     * @dev Implementation of abstract function from EtherFiSafeBase
     * @dev Called during recovery cancellation process
     * @dev Sets the incoming owner to address(0) and timelock to 0, effectively canceling any pending recovery
     */
    function _removeIncomingOwner() internal override {
        _setIncomingOwner(address(0), 0);
    }

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
    function checkSignatures(bytes32 digestHash, address[] calldata signers, bytes[] calldata signatures) public view override returns (bool) {
        MultiSigStorage storage $ = _getMultiSigStorage();

        uint256 len = signers.length;

        if (len == 0) revert EmptySigners();
        if (len != signatures.length) revert ArrayLengthMismatch();


        if ($.incomingOwnerStartTime > 0 && block.timestamp > $.incomingOwnerStartTime) {
            if (len > 1) revert InvalidInput();
            if (signers[0] != $.incomingOwner) revert InvalidSigner(0);   
            return digestHash.isValidSignature(signers[0], signatures[0]);
        }

        if (len < $.threshold) revert InsufficientSigners();
        if (len > 1) signers.checkDuplicates();

        uint256 validSigs = 0;

        for (uint256 i = 0; i < len;) {
            if (signers[i] == address(0)) revert InvalidSigner(i);
            if (!$.owners.contains(signers[i])) revert InvalidSigner(i);

            if (digestHash.isValidSignature(signers[i], signatures[i])) {
                unchecked {
                    ++validSigs;
                }
                if (validSigs == $.threshold) break;
            }

            unchecked {
                ++i;
            }
        }

        return validSigs == $.threshold;
    }

    /**
     * @notice Returns the current incoming owner address
     * @return Address of the incoming owner
     * @dev Used during recovery process
     */
    function getIncomingOwner() public override view returns (address) {
        return _getMultiSigStorage().incomingOwner;
    }

    /**
     * @notice Returns the start time for the incoming owner
     * @return Timestamp when the incoming owner can take effect
     * @dev Used to check if the recovery timelock has passed
     */
    function getIncomingOwnerStartTime() public override view returns (uint256) {
        return _getMultiSigStorage().incomingOwnerStartTime;
    }

    /**
     * @notice Checks if an address is an owner of the safe
     * @param account Address to check
     * @return bool True if the address is an owner, false otherwise
     */
    function isOwner(address account) public view returns (bool) {
        uint256 incomingOwnerStartTime = getIncomingOwnerStartTime();
        if (incomingOwnerStartTime > 0 && block.timestamp > incomingOwnerStartTime) {
            return account == getIncomingOwner();
        }
        
        return _isOwner(account);
    }

    /**
     * @notice Checks if an address is an owner of the safe
     * @param account Address to check
     */
    function _isOwner(address account) internal view returns (bool) {
        return _getMultiSigStorage().owners.contains(account);
    } 

    /**
     * @notice Returns the current signature threshold
     * @return uint8 Current threshold value
     */
    function getThreshold() public view returns (uint8) {
        uint256 incomingOwnerStartTime = getIncomingOwnerStartTime();
        if (incomingOwnerStartTime > 0 && block.timestamp > incomingOwnerStartTime) return 1;
        return _getMultiSigStorage().threshold;
    }

    /**
     * @notice Handles owner transitions during recovery process
     * @dev If the incoming owner timelock has passed, replaces all existing owners
     *      with the incoming owner and sets threshold to 1
     */
    function _currentOwner() internal override {
        MultiSigStorage storage $ = _getMultiSigStorage();

        if ($.incomingOwnerStartTime > 0 && block.timestamp > $.incomingOwnerStartTime) {

            address[] memory owners = $.owners.values();
            uint256 len = owners.length;

            address[] memory accounts = new address[](len + 1);
            accounts[len] = $.incomingOwner;

            bool[] memory shouldAdd = new bool[](len + 1);
            shouldAdd[len] = true;

            for (uint256 i = 0; i < len; ) {
                $.owners.remove(owners[i]);
                accounts[i] = owners[i];
                shouldAdd[i] = false;

                unchecked {
                    ++i;
                }
            }

            _configureAdmin(accounts, shouldAdd);

            $.owners.add($.incomingOwner);
            $.threshold = 1;

            delete $.incomingOwnerStartTime;
            delete $.incomingOwner;


            emit AccountRecovered($.incomingOwner);
        }
    }
}