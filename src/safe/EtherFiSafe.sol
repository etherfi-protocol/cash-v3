// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { NoncesUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import { EIP712Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";

import { IEtherFiHook } from "../interfaces/IEtherFiHook.sol";
import { IRoleRegistry } from "../interfaces/IRoleRegistry.sol";
import { ArrayDeDupLib } from "../libraries/ArrayDeDupLib.sol";
import { SignatureUtils } from "../libraries/SignatureUtils.sol";
import { EtherFiSafeErrors } from "./EtherFiSafeErrors.sol";
import { ModuleManager } from "./ModuleManager.sol";
import { MultiSig } from "./MultiSig.sol";

/**
 * @title EtherFiSafe
 * @notice Implementation of a multi-signature safe with module management capabilities
 * @dev Combines ModuleManager and MultiSig functionality with EIP-712 signature verification
 * @author ether.fi
 */
contract EtherFiSafe is EtherFiSafeErrors, ModuleManager, MultiSig, EIP712Upgradeable {
    using SignatureUtils for bytes32;
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using ArrayDeDupLib for address[];

    /**
     * @notice Interface to the data provider contract
     * @dev Used to access protocol configuration and validation services
     */
    IEtherFiDataProvider public immutable dataProvider;

    /**
     * @dev Storage structure for EtherFiSafe using ERC-7201 namespaced storage pattern
     * @custom:storage-location erc7201:etherfi.storage.EtherFiSafe
     */
    struct EtherFiSafeStorage {
        /// @notice Current nonce for replay protection
        uint256 nonce;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.EtherFiSafe")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EtherFiSafeStorageLocation = 0x44768873c7c67d9dae2df1ca334431d5cd98fd349ed85d549beecffe9f026500;

    /**
     * @notice TypeHash for module configuration with EIP-712 signatures
     * @dev keccak256("ConfigureModules(address[] modules,bool[] shouldWhitelist,uint256 nonce)")
     */
    bytes32 public constant CONFIGURE_MODULES_TYPEHASH = 0x20263b9194095d902b566d15f1db1d03908706042a5d22118c55a666ec3b992c;

    /**
     * @notice TypeHash for threshold setting with EIP-712 signatures
     * @dev keccak256("SetThreshold(uint8 threshold,uint256 nonce)")
     */
    bytes32 public constant SET_THRESHOLD_TYPEHASH = 0x41b1bc57fb63493212c2d2f75145ff3130ce53c70f867177944887c5cb8e8626;

    /**
     * @notice TypeHash for owner configuration with EIP-712 signatures
     * @dev keccak256("ConfigureOwners(address[] owners,bool[] shouldAdd,uint256 nonce)")
     */
    bytes32 public constant CONFIGURE_OWNERS_TYPEHASH = 0x93a5e8776e97535ceccfb399fc4015baa8aa11c3e58454ef681f9e144c718f92;

    /**
     * @notice TypeHash for admin configuration with EIP-712 signatures
     * @dev keccak256("ConfigureAdmins(address[] accounts,bool[] shouldAdd,uint256 nonce)")
     */
    bytes32 public constant CONFIGURE_ADMIN_TYPEHASH = 0x3dfd66efb2a5d3ec63eb6eb270a4a662d28b1e27ce51f3c835ba384215a0ac80;

    /**
     * @notice TypeHash for cancel nonce with EIP-712 signatures
     * @dev keccak256("CancelNonce(uint256 nonce)")
     */
    bytes32 public constant CANCEL_NONCE_TYPEHASH = 0x911689a040f9425c778a23077912d56c2402a1006cf81f5d629a2c8281b77563;

    /**
     * @notice Emitted when a transaction is executed through a module
     * @param to Array of target addresses for the calls
     * @param value Array of ETH values to send with each call
     * @param data Array of calldata for each call
     */
    event ExecTransactionFromModule(address[] to, uint256[] value, bytes[] data);

    /**
     * @notice Emitted when admin accounts are configured
     * @param accounts Array of admin addresses that were configured
     * @param shouldAdd Array indicating whether each admin was added (true) or removed (false)
     */
    event AdminsConfigured(address[] accounts, bool[] shouldAdd);
    
    /**
     * @notice Emitted when a nonce is cancelled
     * @param nonce The cancelled nonce
     */
    event NonceCancelled(uint256 nonce);

    /**
     * @dev Returns the storage struct for EtherFiSafe
     * @return $ Reference to the EtherFiSafeStorage struct
     * @custom:storage-location Uses ERC-7201 namespace storage pattern
     */
    function _getEtherFiSafeStorage() internal pure returns (EtherFiSafeStorage storage $) {
        assembly {
            $.slot := EtherFiSafeStorageLocation
        }
    }

    /**
     * @notice Contract constructor
     * @dev Sets the immutable data provider reference
     * @param _dataProvider Address of the EtherFiDataProvider contract
     */
    constructor(address _dataProvider) payable {
        dataProvider = IEtherFiDataProvider(_dataProvider);
    }

    /**
     * @notice Initializes the safe with owners, modules, and signature threshold
     * @dev Sets up all components and can only be called once
     * @param _owners Initial array of owner addresses
     * @param _modules Initial array of module addresses
     * @param _moduleSetupData Array of data for setting up individual modules for the safe
     * @param _threshold Initial number of required signatures
     * @custom:throws AlreadySetup If safe has already been initialized
     * @custom:throws InvalidThreshold If threshold is 0 or greater than number of owners
     * @custom:throws InvalidInput If owners array is empty
     * @custom:throws InvalidOwnerAddress If any owner address is zero
     */
    function initialize(address[] calldata _owners, address[] calldata _modules, bytes[] calldata _moduleSetupData, uint8 _threshold) external initializer {
        __EIP712_init("EtherFiSafe", "1");

        bool[] memory _shouldAdd = new bool[](_owners.length);
        for (uint256 i = 0; i < _owners.length;) {
            _shouldAdd[i] = true;

            unchecked {
                ++i;
            }
        }

        _setupMultiSig(_owners, _threshold);
        _configureAdmin(_owners, _shouldAdd);
        if (_modules.length > 0) _setupModules(_modules, _moduleSetupData);
    }

    /**
     * @notice Configures admin accounts with signature verification
     * @dev Uses EIP-712 typed data signing for secure multi-signature authorization
     * @param accounts Array of admin addresses to configure
     * @param shouldAdd Array indicating whether to add or remove each admin
     * @param signers Array of addresses that signed the transaction
     * @param signatures Array of corresponding signatures
     * @custom:throws InvalidSignatures If signature verification fails
     */
    function configureAdmins(address[] calldata accounts, bool[] calldata shouldAdd, address[] calldata signers, bytes[] calldata signatures) external {
        bytes32 structHash = keccak256(abi.encode(CONFIGURE_ADMIN_TYPEHASH, keccak256(abi.encodePacked(accounts)), keccak256(abi.encodePacked(shouldAdd)), _useNonce()));

        bytes32 digestHash = _hashTypedDataV4(structHash);
        if (!checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
        _configureAdmin(accounts, shouldAdd);
    }

    /**
     * @notice Cancels the next nonce. 
     * @dev Uses EIP-712 typed data signing for secure multi-signature authorization
     * @param signers Array of addresses that signed the transaction
     * @param signatures Array of corresponding signatures
     * @custom:throws InvalidSignatures If signature verification fails
     */
    function cancelNonce(address[] calldata signers, bytes[] calldata signatures) external {
        uint256 cancelledNonce = _useNonce();
        bytes32 structHash = keccak256(abi.encode(CANCEL_NONCE_TYPEHASH, cancelledNonce));
        bytes32 digestHash = _hashTypedDataV4(structHash);
        if (!checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
        emit NonceCancelled(cancelledNonce);
    }

    /**
     * @notice Gets all admin addresses for this safe
     * @dev Retrieves admin information from the role registry
     * @return Array of admin addresses
     */
    function getAdmins() external view returns (address[] memory) {
        return dataProvider.roleRegistry().getSafeAdmins(address(this));
    }

    /**
     * @notice Returns if an account has safe admin privileges
     * @param account Address of the account
     * @return bool True if the account has the safe admin role, false otherwise
     */
    function isAdmin(address account) external view returns (bool) {
        return dataProvider.roleRegistry().isSafeAdmin(address(this), account);
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
     * @custom:throws InvalidOwnerAddress If any owner address is zero
     * @custom:throws AllOwnersRemoved If operation would remove all owners
     * @custom:throws OwnersLessThanThreshold If owners would be less than threshold
     * @custom:throws InvalidSignatures If signature verification fails
     */
    function configureOwners(address[] calldata owners, bool[] calldata shouldAdd, address[] calldata signers, bytes[] calldata signatures) external {
        bytes32 structHash = keccak256(abi.encode(CONFIGURE_OWNERS_TYPEHASH, keccak256(abi.encodePacked(owners)), keccak256(abi.encodePacked(shouldAdd)), _useNonce()));

        bytes32 digestHash = _hashTypedDataV4(structHash);
        if (!checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
        _configureOwners(owners, shouldAdd);
        _configureAdmin(owners, shouldAdd);
    }

    /**
     * @notice Configures module whitelist with signature verification
     * @dev Uses EIP-712 typed data signing for secure multi-signature authorization
     * @param modules Array of module addresses to configure
     * @param shouldWhitelist Array of booleans indicating whether to add or remove each module
     * @param moduleSetupData Array of data for setting up individual modules for the safe
     * @param signers Array of addresses that signed the transaction
     * @param signatures Array of corresponding signatures
     * @custom:throws InvalidInput If modules array is empty
     * @custom:throws ArrayLengthMismatch If modules and shouldWhitelist arrays have different lengths
     * @custom:throws InvalidModule If any module address is zero
     * @custom:throws InvalidSignatures If the signature verification fails
     */
    function configureModules(address[] calldata modules, bool[] calldata shouldWhitelist, bytes[] calldata moduleSetupData, address[] calldata signers, bytes[] calldata signatures) external {
        bytes32 structHash = keccak256(abi.encode(CONFIGURE_MODULES_TYPEHASH, keccak256(abi.encodePacked(modules)), keccak256(abi.encodePacked(shouldWhitelist)), keccak256(abi.encode(moduleSetupData)), _useNonce()));

        bytes32 digestHash = _hashTypedDataV4(structHash);
        if (!checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
        _configureModules(modules, shouldWhitelist, moduleSetupData);
    }

    /**
     * @notice Returns the EIP-712 domain separator
     * @dev Used for signature verification
     * @return bytes32 Current domain separator value
     */
    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Gets the current nonce value
     * @dev Used for replay protection in signatures
     * @return Current nonce value
     */
    function nonce() public view returns (uint256) {
        return _getEtherFiSafeStorage().nonce;
    }

    /**
     * @notice Executes a transaction from an authorized module
     * @dev Allows modules to execute arbitrary transactions on behalf of the safe
     * @param to Array of target addresses for the calls
     * @param values Array of ETH values to send with each call
     * @param data Array of calldata for each call
     * @custom:throws OnlyModules If the caller is not an enabled module
     * @custom:throws CallFailed If any of the calls fail
     */
    function execTransactionFromModule(address[] calldata to, uint256[] calldata values, bytes[] calldata data) external {
        if (!isModuleEnabled(msg.sender)) revert OnlyModules();
        IEtherFiHook hook = IEtherFiHook(dataProvider.getHookAddress());

        hook.preOpHook(msg.sender);

        uint256 len = to.length;

        for (uint256 i = 0; i < len;) {
            (bool success,) = to[i].call{ value: values[i] }(data[i]);
            if (!success) revert CallFailed(i);
            unchecked {
                ++i;
            }
        }

        hook.postOpHook(msg.sender);

        emit ExecTransactionFromModule(to, values, data);
    }

    /**
     * @notice Returns all current owners of the safe
     * @dev Implementation of the abstract function from ModuleManager
     * @return address[] Array containing all owner addresses
     */
    function getOwners() public view override returns (address[] memory) {
        return _getMultiSigStorage().owners.values();
    }

    /**
     * @notice Uses a nonce for operations in modules which require a quorum of owners
     * @return uint256 nonce for the operation
     */
    function useNonce() external returns (uint256) {
        if (!isModuleEnabled(msg.sender)) revert OnlyModules();
        return _useNonce();
    }

    /**
     * @dev Checks if a module is whitelisted on the data provider
     * @param module Address of the module to check
     * @return bool True if the module is whitelisted on the data provider
     */
    function _isWhitelistedOnDataProvider(address module) internal view override returns (bool) {
        return dataProvider.isWhitelistedModule(module);
    }

    /**
     * @dev Checks if a module is the cash module
     * @param module Address of the module to check
     * @return bool True if the module is the Cash module
     */
    function _isCashModule(address module) internal view override returns (bool) {
        return dataProvider.getCashModule() == module;
    }

    /**
     * @dev Internal function to configure admin accounts
     * @param accounts Array of admin addresses to configure
     * @param shouldAdd Array indicating whether to add or remove each admin
     */
    function _configureAdmin(address[] calldata accounts, bool[] memory shouldAdd) internal {
        dataProvider.roleRegistry().configureSafeAdmins(accounts, shouldAdd);
        emit AdminsConfigured(accounts, shouldAdd);
    }

    /**
     * @dev Consumes a nonce for replay protection
     * @return Current nonce value before incrementing
     */
    function _useNonce() internal returns (uint256) {
        EtherFiSafeStorage storage $ = _getEtherFiSafeStorage();

        // The nonce has an initial value of 0, can only be incremented by one, and cannot be
        // decremented or reset. This guarantees that the nonce never overflows.
        unchecked {
            // It is important to do x++ and not ++x here.
            return $.nonce++;
        }
    }

    receive() external payable {}
}
