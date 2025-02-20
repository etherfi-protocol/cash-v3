// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { NoncesUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import { EIP712Upgradeable, Initializable } from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { ArrayDeDupLib } from "../libraries/ArrayDeDupLib.sol";
import { SignatureUtils } from "../libraries/SignatureUtils.sol";
import { ModuleManager } from "./ModuleManager.sol";

contract EtherFiSafe is ModuleManager, Initializable, EIP712Upgradeable, NoncesUpgradeable {
    using SignatureUtils for bytes32;
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using ArrayDeDupLib for address[];

    /// @custom:storage-location erc7201:etherfi.storage.EtherFiSafe
    struct EtherFiSafeStorage {
        /// @notice Set containing addresses of all the owners to the safe
        EnumerableSetLib.AddressSet owners;
        /// @notice Multisig threshold for the safe
        uint8 threshold;
        /// @notice Pre Operation Guard address
        address preOpGuard;
        /// @notice Post Operation Guard address
        address postOpGuard;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.EtherFiSafe")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EtherFiSafeStorageLocation = 0x44768873c7c67d9dae2df1ca334431d5cd98fd349ed85d549beecffe9f026500;

    // keccak256("ConfigureModules(address[] modules,bool[] shouldWhitelist,uint256 nonce)")
    bytes32 public constant CONFIGURE_MODULES_TYPEHASH = 0x20263b9194095d902b566d15f1db1d03908706042a5d22118c55a666ec3b992c;

    /// @notice Thrown when a signer at the given index is invalid
    error InvalidSigner(uint256 index);
    /// @notice Thrown when the signature verification fails
    error InvalidSignatures();
    /// @notice Thrown when there are not enough signers to meet the threshold
    error InsufficientSigners();
    /// @notice Thrown when no signers are provided
    error EmptySigners();
    /// @notice Thrown when adding address(0) as owner
    error InvalidOwnerAddress();

    /**
     * @notice Initializes the safe with EIP712 and nonce management
     * @dev Sets up the domain separator for EIP712 and initializes nonces
     */
    function initialize(address[] memory owners, uint8 threshold) external initializer {
        __EIP712_init("EtherFiSafe", "1");
        __Nonces_init();
    
        EtherFiSafeStorage storage $ = _getEtherFiSafeStorage();
        uint256 len = owners.length;

        if (len == 0 || len < threshold) revert InvalidInput();

        for (uint256 i = 0; i < len; ){
            if (owners[i] == address(0)) revert InvalidOwnerAddress();
            $.owners.add(owners[i]);
            unchecked { ++i; }
        }

        $.threshold = threshold;

    }

    /**
     * @notice Configures module whitelist with signature verification
     * @param modules Array of module addresses to configure
     * @param shouldWhitelist Array of booleans indicating whether to add or remove each module
     * @param signers Array of addresses that signed the transaction
     * @param signatures Array of corresponding signatures
     * @custom:throws InvalidInput If modules array is empty
     * @custom:throws ArrayLengthMismatch If modules and shouldWhitelist arrays have different lengths
     * @custom:throws InvalidModule If any module address is zero
     * @custom:throws InvalidSignatures If the signature verification fails
     */
    function configureModules(address[] calldata modules, bool[] calldata shouldWhitelist, address[] calldata signers, bytes[] calldata signatures) external {
        bytes32 structHash = keccak256(abi.encode(CONFIGURE_MODULES_TYPEHASH, keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), _useNonce(msg.sender)));

        bytes32 digestHash = _hashTypedDataV4(structHash);
        if (!checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
        _configureModules(modules, shouldWhitelist);
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
        EtherFiSafeStorage storage $ = _getEtherFiSafeStorage();

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

    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @dev Returns the storage struct for EtherFiSafe
     * @return $ Reference to the EtherFiSafeStorage struct
     */
    function _getEtherFiSafeStorage() internal pure returns (EtherFiSafeStorage storage $) {
        assembly {
            $.slot := EtherFiSafeStorageLocation
        }
    }
}
