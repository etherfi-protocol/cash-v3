// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { IEtherFiSafe } from "../interfaces/IEtherFiSafe.sol";
import { ArrayDeDupLib } from "../libraries/ArrayDeDupLib.sol";
import { SignatureUtils } from "../libraries/SignatureUtils.sol";
import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";

/**
 * @title ModuleBase
 * @author ether.fi
 * @notice Base contract for implementing modules with admin functionality
 * @dev Provides common functionality for modules including admin management and signature verification
 *      Uses ERC-7201 for namespace storage pattern
 */
contract ModuleBase {
    using SignatureUtils for bytes32;
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using MessageHashUtils for bytes32;
    using ArrayDeDupLib for address[];

    IEtherFiDataProvider public immutable etherFiDataProvider;

    /// @custom:storage-location erc7201:etherfi.storage.ModuleBaseStorage
    struct ModuleBaseStorage {
        /// @notice Mapping of Safe addresses to their admin sets
        mapping(address safe => EnumerableSetLib.AddressSet admins) admins;
        /// @notice Mapping of Safe addresses to their nonces for replay protection
        mapping(address safe => uint256 nonce) nonces;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.ModuleBaseStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ModuleBaseStorageLocation = 0x9425b2e03e09da4c20ff7a465da264f7a02bf7079e1dbb47fce0436e1d206d00;

    /// @notice Role identifier for administrative privileges
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice TypeHash for admin configuration
    bytes32 public constant CONFIG_ADMIN = keccak256("configureAdmins");

    /// @notice Thrown when the input is invalid
    error InvalidInput();

    /// @notice Thrown when the signature verification fails
    error InvalidSignature();

    /// @notice Thrown when array lengths don't match in configuration functions
    error ArrayLengthMismatch();

    /// @notice Thrown when an invalid address is provided at the specified index
    /// @param index The index where the invalid address was found
    error InvalidAddress(uint256 index);

    /// @notice Thrown when empty input is provided
    error EmptyInput();

    /// @notice Throws when the signer is not an admin
    error SignerIsNotAnAdmin();

    /// @notice Throws when the msg.sender is not an admin
    error OnlyAdmin();

    /// @notice Emitted when admins are configured for a Safe
    /// @param safe The Safe address for which admins were configured
    /// @param admins Array of admin addresses that were configured
    /// @param shouldAdd Array indicating whether each admin was added (true) or removed (false)
    event AdminsConfigured(address indexed safe, address[] admins, bool[] shouldAdd);

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
     * @notice Checks if an account has admin role for a specific Safe
     * @param safe The Safe address to check
     * @param account The account address to check
     * @return bool True if the account has admin role, false otherwise
     */
    function hasAdminRole(address safe, address account) public view returns (bool) {
        return _getModuleBaseStorage().admins[safe].contains(account);
    }

    /**
     * @notice Returns all admin addresses for a Safe
     * @param safe The Safe address to query
     * @return Array of admin addresses for the specified Safe
     */
    function getAdmins(address safe) public view onlyEtherFiSafe(safe) returns (address[] memory) {
        return _getModuleBaseStorage().admins[safe].values();
    }

    /**
     * @notice Returns the current nonce for a Safe
     * @param safe The Safe address to query
     * @return Current nonce value
     * @dev Nonces are used to prevent signature replay attacks
     */
    function getNonce(address safe) public view onlyEtherFiSafe(safe) returns (uint256) {
        return _getModuleBaseStorage().nonces[safe];
    }

    function setupModuleForSafe(address[] memory admins, bytes calldata data) external onlyEtherFiSafe(msg.sender) {
        address safe = msg.sender;
        uint256 len = admins.length;
        bool[] memory shouldAdd = new bool[](len);

        for (uint256 i = 0; i < len; ) {
            shouldAdd[i] = true;
            unchecked {
                ++i;
            }
        }

        _configureAdmins(safe, admins, shouldAdd);
        _setupModule(data);
    }

    function _setupModule(bytes calldata data) internal virtual {}

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
    function configureAdmins(address safe, address[] calldata accounts, bool[] calldata shouldAdd, address[] calldata signers, bytes[] calldata signatures) external onlyEtherFiSafe(safe) {
        bytes32 configAdminsHash = keccak256(abi.encode(CONFIG_ADMIN, block.chainid, address(this), _useNonce(safe), safe, accounts, shouldAdd));
        bytes32 digestHash = configAdminsHash.toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digestHash, signers, signatures)) revert InvalidSignature();

        _configureAdmins(safe, accounts, shouldAdd);
    }

    /**
     * @dev Verifies if a signature is valid and made by an admin of the safe
     * @param safe The Safe address
     * @param digestHash The message hash that was signed
     * @param signer The address that supposedly signed the message
     * @param signature The signature to verify
     * @custom:throws SignerIsNotAnAdmin If the signer is not an admin of the Safe
     * @custom:throws InvalidSignature If the signature is invalid
     */
    function _verifyAdminSig(address safe, bytes32 digestHash, address signer, bytes calldata signature) internal view {
        if (!hasAdminRole(safe, signer)) revert SignerIsNotAnAdmin();
        if (!digestHash.isValidSignature(signer, signature)) revert InvalidSignature();
    }

    /**
     * @dev Internal function to configure admin addresses
     * @param safe The Safe address to configure admins for
     * @param accounts Array of admin addresses to configure
     * @param shouldAdd Array indicating whether to add or remove each admin
     * @custom:throws EmptyInput If accounts array is empty
     * @custom:throws ArrayLengthMismatch If arrays have different lengths
     * @custom:throws InvalidAddress If any admin address is zero
     */
    function _configureAdmins(address safe, address[] memory accounts, bool[] memory shouldAdd) internal {
        ModuleBaseStorage storage $ = _getModuleBaseStorage();
        uint256 len = accounts.length;

        if (len == 0) revert EmptyInput();
        if (len != shouldAdd.length) revert ArrayLengthMismatch();
        if (len > 1) accounts.checkDuplicates();

        for (uint256 i = 0; i < len;) {
            if (accounts[i] == address(0)) revert InvalidAddress(i);

            if (shouldAdd[i] && !$.admins[safe].contains(accounts[i])) $.admins[safe].add(accounts[i]);
            if (!shouldAdd[i] && $.admins[safe].contains(accounts[i])) $.admins[safe].remove(accounts[i]);

            unchecked {
                ++i;
            }
        }

        emit AdminsConfigured(safe, accounts, shouldAdd);
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
     * @dev Ensures that the caller is an admin for the specified Safe
     * @param safe The Safe address to check admin status for
     */
    modifier onlyAdmin(address safe) {
        if (!hasAdminRole(safe, msg.sender)) revert OnlyAdmin();
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
}