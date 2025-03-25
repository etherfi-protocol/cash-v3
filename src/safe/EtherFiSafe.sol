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
import { RecoveryManager } from "./RecoveryManager.sol";
import { EtherFiSafeBase } from "./EtherFiSafeBase.sol";

/**
 * @title EtherFiSafe
 * @notice Implementation of a multi-signature safe with module management capabilities
 * @dev Combines ModuleManager and MultiSig functionality with EIP-712 signature verification
 * @author ether.fi
 */
contract EtherFiSafe is EtherFiSafeBase, ModuleManager, RecoveryManager, MultiSig{
    using SignatureUtils for bytes32;
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using ArrayDeDupLib for address[];

    /**
     * @notice Contract constructor
     * @dev Sets the immutable data provider reference
     * @param _dataProvider Address of the EtherFiDataProvider contract
     */
    constructor(address _dataProvider) payable EtherFiSafeBase(_dataProvider) {
        _disableInitializers();
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
        _setupRecovery();
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
        _currentOwner();
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
        _currentOwner();
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
        uint256 incomingOwnerStartTime = getIncomingOwnerStartTime();
        if (incomingOwnerStartTime > 0 && block.timestamp > incomingOwnerStartTime) {
            address[] memory admins = dataProvider.roleRegistry().getSafeAdmins(address(this));
            uint256 len = admins.length;
            address[] memory currentAdmins = new address[](len + 1);
            uint256 counter = 0;

            for (uint256 i = 0; i < len; ) {
                if (!_isOwner(admins[i])) {
                    currentAdmins[counter] = admins[i];
                    unchecked {
                        ++counter;
                    }
                }
                unchecked {
                    ++i;
                }
            }

            currentAdmins[counter] = getIncomingOwner();
            unchecked {
                ++counter; 
            }

            assembly ("memory-safe") {
                mstore(currentAdmins, counter)
            }

            return currentAdmins;
        }

        return dataProvider.roleRegistry().getSafeAdmins(address(this));
    }

    /**
     * @notice Returns if an account has safe admin privileges
     * @param account Address of the account
     * @return bool True if the account has the safe admin role, false otherwise
     */
    function isAdmin(address account) external view returns (bool) {
        uint256 incomingOwnerStartTime = getIncomingOwnerStartTime();

        if (incomingOwnerStartTime > 0 && block.timestamp > incomingOwnerStartTime) {
            if (account == getIncomingOwner()) return true;
            if (_isOwner(account)) return false;
        }
        return dataProvider.roleRegistry().isSafeAdmin(address(this), account);
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

        if (address(hook) != address(0)) hook.preOpHook(msg.sender);

        uint256 len = to.length;

        for (uint256 i = 0; i < len;) {
            (bool success,) = to[i].call{ value: values[i] }(data[i]);
            if (!success) revert CallFailed(i);
            unchecked {
                ++i;
            }
        }

        if (address(hook) != address(0)) hook.postOpHook(msg.sender);

        emit ExecTransactionFromModule(to, values, data);
    }

    /**
     * @notice Returns all current owners of the safe
     * @dev Implementation of the abstract function from ModuleManager
     * @return address[] Array containing all owner addresses
     */
    function getOwners() public view override returns (address[] memory) {
        uint256 incomingOwnerStartTime = getIncomingOwnerStartTime();
        if (incomingOwnerStartTime > 0 && block.timestamp > incomingOwnerStartTime) {
            address[] memory owners = new address[](1);
            owners[0] = getIncomingOwner();

            return owners;
        }
        
        return _getMultiSigStorage().owners.values();
    }

    /**
     * @notice Uses a nonce for operations in modules which require a quorum of owners
     * @dev Can only be called by enabled modules
     * @return uint256 The current nonce value before incrementing
     * @custom:throws OnlyModules If the caller is not an enabled module
     */
    function useNonce() external returns (uint256) {
        if (!isModuleEnabled(msg.sender)) revert OnlyModules();
        return _useNonce();
    }

    /**
     * @dev Implementation of abstract function from ModuleManager
     * @dev Checks if a module is whitelisted on the data provider
     * @param module Address of the module to check
     * @return bool True if the module is whitelisted on the data provider
     */
    function _isWhitelistedOnDataProvider(address module) internal view override returns (bool) {
        return dataProvider.isWhitelistedModule(module);
    }

    /**
     * @dev Implementation of abstract function from ModuleManager
     * @dev Checks if a module is the cash module
     * @param module Address of the module to check
     * @return bool True if the module is the Cash module
     */
    function _isCashModule(address module) internal view override returns (bool) {
        return dataProvider.getCashModule() == module;
    }

    receive() external payable {}
}
