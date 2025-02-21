// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title EtherFiHook
 * @author ether.fi
 * @notice Contract that implements pre and post operation hooks for the ether.fi protocol
 * @dev Implements upgradeable proxy pattern and role-based access control
 */
contract EtherFiHook is UpgradeableProxy {
    /// @custom:storage-location erc7201:etherfi.storage.EtherFiHook
    struct EtherFiHookStorage {
        /// @notice Address of the cash module contract
        address cashModule;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.EtherFiHook")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EtherFiHookStorageLocation = 0x074c0c7a4bbcbd9deccd65f607219fc9b22583eb0823daff8392d7f7c9aaa700;

    /// @notice Role identifier for administrative privileges
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Thrown when a non-admin address attempts to perform an admin-only operation
    error OnlyAdmin();
    /// @notice Thrown when input parameters are invalid or zero address is provided
    error InvalidInput();

    /// @notice Emitted when the cash module address is updated
    /// @param oldCashModule Previous cash module address
    /// @param newCashModule New cash module address
    event CashModuleUpdated(address oldCashModule, address newCashModule);

    /**
     * @notice Initializes the contract with initial the EtherFiHook
     * @dev Can only be called once due to initializer modifier
     * @param _roleRegistry Address of the role registry contract
     * @param _cashModule Address of the Cash Module
     */
    function initialize(address _roleRegistry, address _cashModule) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
        _setCashModule(_cashModule);
    }

    /**
     * @dev Internal function to access the contract's storage
     * @return $ Storage pointer to the EtherFiHookStorage struct
     */
    function _getEtherFiHookStorage() private pure returns (EtherFiHookStorage storage $) {
        assembly {
            $.slot := EtherFiHookStorageLocation
        }
    }

    /**
     * @notice Updates the cash module address
     * @dev Only callable by addresses with ADMIN_ROLE
     * @param cashModule New cash module address to set
     */
    function setCashModule(address cashModule) external {
        _onlyAdmin();
        _setCashModule(cashModule);
    }

    /**
     * @notice Hook called before module operations
     * @dev Currently implemented as a view function with no effects
     * @param module Address of the module being operated on
     */
    function preOpHook(address module) external view { }

    /**
     * @notice Hook called after module operations
     * @dev Currently implemented as a view function with no effects
     * @param module Address of the module being operated on
     */
    function postOpHook(address module) external view { }

    /**
     * @dev Internal function to update the cash module address
     * @param cashModule New cash module address to set
     */
    function _setCashModule(address cashModule) private {
        if (cashModule == address(0)) revert InvalidInput();
        EtherFiHookStorage storage $ = _getEtherFiHookStorage();
        emit CashModuleUpdated($.cashModule, cashModule);
        $.cashModule = cashModule;
    }

    /**
     * @dev Internal function to verify caller has admin role
     */
    function _onlyAdmin() private view {
        if (!roleRegistry().hasRole(ADMIN_ROLE, msg.sender)) revert OnlyAdmin();
    }
}
