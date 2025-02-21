// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { NoncesUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import { EIP712Upgradeable, Initializable } from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { ArrayDeDupLib } from "../libraries/ArrayDeDupLib.sol";
import { SignatureUtils } from "../libraries/SignatureUtils.sol";

import { EtherFiSafeErrors } from "./EtherFiSafeErrors.sol";
import { ModuleManager } from "./ModuleManager.sol";
import { MultiSig } from "./MultiSig.sol";

/**
 * @title EtherFiSafe
 * @author ether.fi
 * @notice Implementation of a multi-signature safe with module management capabilities
 */
contract EtherFiSafe is EtherFiSafeErrors, ModuleManager, MultiSig, Initializable, EIP712Upgradeable, NoncesUpgradeable {
    using SignatureUtils for bytes32;
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using ArrayDeDupLib for address[];

    /// @notice Interface to the data provider contract
    IEtherFiDataProvider public immutable dataProvider;

    // keccak256("ConfigureModules(address[] modules,bool[] shouldWhitelist,uint256 nonce)")
    bytes32 public constant CONFIGURE_MODULES_TYPEHASH = 0x20263b9194095d902b566d15f1db1d03908706042a5d22118c55a666ec3b992c;
    // keccak256("SetThreshold(uint8 threshold,uint256 nonce)")
    bytes32 public constant SET_THRESHOLD_TYPEHASH = 0x41b1bc57fb63493212c2d2f75145ff3130ce53c70f867177944887c5cb8e8626;
    // keccak256("ConfigureOwners(address[] owners,bool[] shouldAdd,uint256 nonce)")
    bytes32 public constant CONFIGURE_OWNERS_TYPEHASH = 0x93a5e8776e97535ceccfb399fc4015baa8aa11c3e58454ef681f9e144c718f92;

    /**
     * @notice Contract constructor
     * @param _dataProvider Address of the EtherFiDataProvider contract
     */
    constructor(address _dataProvider) payable {
        dataProvider = IEtherFiDataProvider(_dataProvider);
    }

    /**
     * @notice Initializes the safe with owners and signature threshold
     * @param _owners Initial array of owner addresses
     * @param _threshold Initial number of required signatures
     * @custom:throws AlreadySetup If safe has already been initialized
     * @custom:throws InvalidThreshold If threshold is 0 or greater than number of owners
     * @custom:throws InvalidInput If owners array is empty
     * @custom:throws InvalidOwnerAddress If any owner address is zero
     */
    function initialize(address[] calldata _owners, uint8 _threshold) external initializer {
        __EIP712_init("EtherFiSafe", "1");
        __Nonces_init();
        _setup(_owners, _threshold);
    }

    /**
     * @notice Updates the signature threshold with owner signatures
     * @param threshold New threshold value
     * @param signers Array of addresses that signed the transaction
     * @param signatures Array of corresponding signatures
     * @dev Uses EIP-712 typed data signing
     * @custom:throws InvalidThreshold If threshold is 0 or greater than number of owners
     * @custom:throws InvalidSignatures If signature verification fails
     */
    function setThreshold(uint8 threshold, address[] calldata signers, bytes[] calldata signatures) external {
        bytes32 structHash = keccak256(abi.encode(SET_THRESHOLD_TYPEHASH, threshold, _useNonce(msg.sender)));

        bytes32 digestHash = _hashTypedDataV4(structHash);
        if (!checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
        _setThreshold(threshold);
    }

    /**
     * @notice Configures safe owners with signature verification
     * @param owners Array of owner addresses to configure
     * @param shouldAdd Array indicating whether to add or remove each owner
     * @param signers Array of addresses that signed the transaction
     * @param signatures Array of corresponding signatures
     * @dev Uses EIP-712 typed data signing
     * @custom:throws InvalidInput If owners array is empty
     * @custom:throws ArrayLengthMismatch If arrays have different lengths
     * @custom:throws InvalidOwnerAddress If any owner address is zero
     * @custom:throws AllOwnersRemoved If operation would remove all owners
     * @custom:throws OwnersLessThanThreshold If owners would be less than threshold
     * @custom:throws InvalidSignatures If signature verification fails
     */
    function configureOwners(address[] calldata owners, bool[] calldata shouldAdd, address[] calldata signers, bytes[] calldata signatures) external {
        bytes32 structHash = keccak256(abi.encode(CONFIGURE_OWNERS_TYPEHASH, keccak256(abi.encodePacked(owners)), keccak256(abi.encodePacked(shouldAdd)), _useNonce(msg.sender)));

        bytes32 digestHash = _hashTypedDataV4(structHash);
        if (!checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
        _configureOwners(owners, shouldAdd);
    }

    /**
     * @notice Configures module whitelist with signature verification
     * @param modules Array of module addresses to configure
     * @param shouldWhitelist Array of booleans indicating whether to add or remove each module
     * @param signers Array of addresses that signed the transaction
     * @param signatures Array of corresponding signatures
     * @dev Uses EIP-712 typed data signing
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
     * @notice Returns the EIP-712 domain separator
     * @return bytes32 Current domain separator value
     */
    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
