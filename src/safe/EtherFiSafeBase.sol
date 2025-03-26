// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EIP712Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";

import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { EtherFiSafeErrors } from "./EtherFiSafeErrors.sol";

/**
 * @title EtherFiSafeBase
 * @author ether.fi
 * @notice Base contract for EtherFi safe implementations providing common functionality
 * @dev Implements EIP-712 typed data signing and core safe functionality
 */
abstract contract EtherFiSafeBase is EtherFiSafeErrors, EIP712Upgradeable {
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
     * @dev keccak256("ConfigureModules(address[] modules,bool[] shouldWhitelist,bytes[] moduleSetupData,uint256 nonce)")
     */
    bytes32 public constant CONFIGURE_MODULES_TYPEHASH = 0x17e852b97b6d99745122cea2e2c782f5720a732d6f557a0a647b5090fc919667;

    /**
     * @notice TypeHash for threshold setting with EIP-712 signatures
     * @dev keccak256("SetThreshold(uint8 threshold,uint256 nonce)")
     */
    bytes32 public constant SET_THRESHOLD_TYPEHASH = 0x41b1bc57fb63493212c2d2f75145ff3130ce53c70f867177944887c5cb8e8626;

    /**
     * @notice TypeHash for owner configuration with EIP-712 signatures
     * @dev keccak256("ConfigureOwners(address[] owners,bool[] shouldAdd,uint8 threshold,uint256 nonce)")
     */
    bytes32 public constant CONFIGURE_OWNERS_TYPEHASH = 0x7ae209fa0e1cd2808f119c4a89c36952d3ac8521e0be463a9bdab5449b4ee419;

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
     * @notice TypeHash for setting user recovery signers with EIP-712 signatures
     * @dev keccak256("SetUserRecoverySigners(address[] recoverySigners, bool[] shouldAdd, uint256 nonce)")
     */
    bytes32 public constant SET_USER_RECOVERY_SIGNERS_TYPEHASH = 0x13a92003fda0d03ec95bfceee0b09375118fa2f6b07643738d22bb5ab1624892;

    /**
     * @notice TypeHash for toggling recovery enabled flag with EIP-712 signatures
     * @dev keccak256("ToggleRecoveryEnabled(bool shouldEnable, uint256 nonce)")
     */
    bytes32 public constant TOGGLE_RECOVERY_ENABLED_TYPEHASH = 0x5c10794d3a4aa2f8b255fb0edd6a1590ef803ef6938cd05b4b429373f6d7f23a;

    /**
     * @notice TypeHash for recovering the safe with EIP-712 signatures
     * @dev keccak256("RecoverSafe(address newOwner, uint256 nonce)")
     */
    bytes32 public constant RECOVER_SAFE_TYPEHASH = 0x2992e7b46f73f4592f11ad26ecd28369c2c2c21ff82538e3a580b30a75cf7475;

    /**
     * @notice TypeHash for overriding EtherFi and Third Party recovery signers with EIP-712 signatures
     * @dev keccak256("OverrideRecoverySigners(address[2] recoverySigners, uint256 nonce)")
     */
    bytes32 public constant OVERRIDE_RECOVERY_SIGNERS_TYPEHASH = 0x04bcf772e9794a9d599eb843d9bc5d71ec13708fac13593aefc4ff9cfc4ba9e7;

    /**
     * @notice TypeHash for cancelling recovery with EIP-712 signatures
     * @dev keccak256("CancelRecovery(uint256 nonce)")
     */
    bytes32 public constant CANCEL_RECOVERY_TYPEHASH = 0x74bf4a4220866f2d5407c382e8b086ccc8579acc38c68ccbcb96d46432578c8d;

    /**
     * @notice TypeHash for setting the recovery threshold with EIP-712 signatures
     * @dev keccak256("SetRecoveryThreshold(uint8 threshold, uint256 nonce)")
     */
    bytes32 public constant SET_RECOVERY_THRESHOLD_TYPEHASH = 0x55fbacc2ae7fb06b8e6207b13a0239f651c6c83bbee4bf809286d76d9ee9a8ac;

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
     * @notice Verifies multiple signatures against a digest hash
     * @param digestHash The hash of the data that was signed
     * @param signers Array of addresses that supposedly signed the message
     * @param signatures Array of signatures corresponding to the signers
     * @return bool True if the signatures are valid and meet the threshold requirements
     * @dev Implementation varies based on the inheriting contract
     */
    function checkSignatures(bytes32 digestHash, address[] calldata signers, bytes[] calldata signatures) public view virtual returns (bool);

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

    /**
     * @notice Verifies current ownership state and handles recovery transitions
     * @dev Implementation depends on the specific ownership model in inheriting contracts
     */
    function _currentOwner() internal virtual;

    /**
     * @notice Sets a new incoming owner with a timelock
     * @param incomingOwner Address of the new incoming owner
     * @param startTime Timestamp when the new owner can take effect
     * @dev Used in the recovery process, implementation in inheriting contracts
     */
    function _setIncomingOwner(address incomingOwner, uint256 startTime) internal virtual;  
    
    /**
     * @notice Removes the currently set incoming owner
     * @dev Used to cancel a recovery process, implementation in inheriting contracts
     */
    function _removeIncomingOwner() internal virtual;

    /**
     * @notice Returns all current owners of the safe
     * @return address[] Array containing all owner addresses
     */
    function getOwners() public view virtual returns (address[] memory);

    /**
     * @notice Returns the current incoming owner address
     * @return Address of the incoming owner
     * @dev Used during recovery process
     */
    function getIncomingOwner() public virtual view returns (address);

    /**
     * @notice Returns the start time for the incoming owner
     * @return Timestamp when the incoming owner can take effect
     * @dev Used to check if the recovery timelock has passed
     */
    function getIncomingOwnerStartTime() public virtual view returns (uint256);

    /**
     * @dev Internal function to configure admin accounts
     * @param accounts Array of admin addresses to configure
     * @param shouldAdd Array indicating whether to add or remove each admin
     */
    function _configureAdmin(address[] memory accounts, bool[] memory shouldAdd) internal {
        dataProvider.roleRegistry().configureSafeAdmins(accounts, shouldAdd);
        emit AdminsConfigured(accounts, shouldAdd);
    }
}