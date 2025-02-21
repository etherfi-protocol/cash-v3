// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { ArrayDeDupLib } from "../libraries/ArrayDeDupLib.sol";
import { SignatureUtils } from "../libraries/SignatureUtils.sol";
import { EtherFiSafeErrors } from "./EtherFiSafeErrors.sol";

/**
 * @title MultiSig
 * @author ether.fi
 * @notice Implements multi-sig functionality with configurable owners and threshold
 */
abstract contract MultiSig is EtherFiSafeErrors {
    using SignatureUtils for bytes32;
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using ArrayDeDupLib for address[];

    /// @custom:storage-location erc7201:etherfi.storage.MultiSig
    struct MultiSigStorage {
        /// @notice Set containing addresses of all the owners to the safe
        EnumerableSetLib.AddressSet owners;
        /// @notice Multisig threshold for the safe
        uint8 threshold;
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
     * @custom:throws AlreadySetup If the safe has already been set up
     * @custom:throws InvalidThreshold If threshold is 0 or greater than number of owners
     * @custom:throws InvalidInput If owners array is empty
     * @custom:throws InvalidOwnerAddress If any owner address is zero
     */
    function _setup(address[] calldata _owners, uint8 _threshold) internal {
        MultiSigStorage storage $ = _getMultiSigStorage();

        if ($.owners.length() > 0) revert AlreadySetup();

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
     * @dev Cannot remove all owners or reduce owners below threshold
     * @custom:throws InvalidInput If owners array is empty
     * @custom:throws ArrayLengthMismatch If owners and shouldAdd arrays have different lengths
     * @custom:throws InvalidOwnerAddress If any owner address is zero
     * @custom:throws AllOwnersRemoved If operation would remove all owners
     * @custom:throws OwnersLessThanThreshold If operation would reduce owners below threshold
     */
    function _configureOwners(address[] calldata _owners, bool[] calldata _shouldAdd) internal {
        MultiSigStorage storage $ = _getMultiSigStorage();

        uint256 len = _owners.length;
        if (len == 0) revert InvalidInput();
        if (len > 1) _owners.checkDuplicates();
        if (len != _shouldAdd.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < len;) {
            if (_owners[i] == address(0)) revert InvalidOwnerAddress(i);

            if (_shouldAdd[i] && !$.owners.contains(_owners[i])) $.owners.add(_owners[i]);
            if (!_shouldAdd[i] && $.owners.contains(_owners[i])) $.owners.remove(_owners[i]);

            unchecked {
                ++i;
            }
        }

        if ($.owners.length() == 0) revert AllOwnersRemoved();
        if ($.owners.length() < $.threshold) revert OwnersLessThanThreshold();

        emit OwnersConfigured(_owners, _shouldAdd);
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
    function checkSignatures(bytes32 digestHash, address[] calldata signers, bytes[] calldata signatures) public view returns (bool) {
        MultiSigStorage storage $ = _getMultiSigStorage();

        uint256 len = signers.length;

        if (len == 0) revert EmptySigners();
        if (len != signatures.length) revert ArrayLengthMismatch();
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
     * @notice Checks if an address is an owner of the safe
     * @param account Address to check
     * @return bool True if the address is an owner, false otherwise
     */
    function isOwner(address account) public view returns (bool) {
        return _getMultiSigStorage().owners.contains(account);
    }

    /**
     * @notice Returns all current owners of the safe
     * @return address[] Array containing all owner addresses
     */
    function getOwners() public view returns (address[] memory) {
        return _getMultiSigStorage().owners.values();
    }

    /**
     * @notice Returns the current signature threshold
     * @return uint8 Current threshold value
     */
    function getThreshold() public view returns (uint8) {
        return _getMultiSigStorage().threshold;
    }
}
