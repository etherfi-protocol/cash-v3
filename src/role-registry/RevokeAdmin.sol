// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { RoleRegistry } from "./RoleRegistry.sol";

/**
 * @title RevokeAdmin
 * @notice Emergency valve for instantly revoking operational/guardian roles when a key leaks
 * @dev Mirrors the protocol governance RevokeAdmin: exposes one named revoke per operational
 *      role, each callable only by the admin multisig (ADMIN_ROLE holder), delegating to
 *      RoleRegistry.revokeFast. The registry refuses to fast-revoke ADMIN_ROLE and
 *      ADMIN_TIMELOCK_ROLE, so this contract can never touch the governance tier.
 *      Not upgradeable: to rotate or extend it, deploy a new instance and repoint the
 *      registry's revokeAdmin via the owner (upgrade timelock).
 * @author ether.fi
 */
contract RevokeAdmin {
    /// @notice Reference to the role registry this contract revokes roles on
    RoleRegistry public immutable roleRegistry;

    /// @notice Thrown when the zero address is passed to the constructor
    error InvalidInput();

    /**
     * @param _roleRegistry Address of the RoleRegistry
     */
    constructor(address _roleRegistry) {
        if (_roleRegistry == address(0)) revert InvalidInput();
        roleRegistry = RoleRegistry(_roleRegistry);
    }

    /**
     * @dev Restricts calls to holders of the registry's ADMIN_ROLE (the admin multisig)
     */
    modifier onlyAdmin() {
        roleRegistry.onlyAdmin(msg.sender);
        _;
    }

    /// @notice Instantly revokes ETHER_FI_WALLET_ROLE (backend spend/repay/borrow signer) from an account
    function revokeEtherFiWalletRole(address account) external onlyAdmin {
        roleRegistry.revokeFast(keccak256("ETHER_FI_WALLET_ROLE"), account);
    }

    /// @notice Instantly revokes SETTLEMENT_DISPATCHER_BRIDGER_ROLE from an account
    function revokeSettlementDispatcherBridgerRole(address account) external onlyAdmin {
        roleRegistry.revokeFast(keccak256("SETTLEMENT_DISPATCHER_BRIDGER_ROLE"), account);
    }

    /// @notice Instantly revokes TOP_UP_ROLE from an account
    function revokeTopUpRole(address account) external onlyAdmin {
        roleRegistry.revokeFast(keccak256("TOP_UP_ROLE"), account);
    }

    /// @notice Instantly revokes the TopUpDest DEPOSITOR_ROLE from an account
    function revokeTopUpDepositorRole(address account) external onlyAdmin {
        roleRegistry.revokeFast(keccak256("DEPOSITOR_ROLE"), account);
    }

    /// @notice Instantly revokes TOPUP_FACTORY_BRIDGER_ROLE from an account
    function revokeTopUpFactoryBridgerRole(address account) external onlyAdmin {
        roleRegistry.revokeFast(keccak256("TOPUP_FACTORY_BRIDGER_ROLE"), account);
    }

    /// @notice Instantly revokes TOPUP_FACTORY_REDIRECT_ROLE from an account
    function revokeTopUpFactoryRedirectRole(address account) external onlyAdmin {
        roleRegistry.revokeFast(keccak256("TOPUP_FACTORY_REDIRECT_ROLE"), account);
    }

    /// @notice Instantly revokes TRADING_SAFE_FACTORY_ADMIN_ROLE from an account
    function revokeTradingSafeFactoryAdminRole(address account) external onlyAdmin {
        roleRegistry.revokeFast(keccak256("TRADING_SAFE_FACTORY_ADMIN_ROLE"), account);
    }

    /// @notice Instantly revokes TRADING_SAFE_REDIRECT_ROLE from an account
    function revokeTradingSafeRedirectRole(address account) external onlyAdmin {
        roleRegistry.revokeFast(keccak256("TRADING_SAFE_REDIRECT_ROLE"), account);
    }

    /// @notice Instantly revokes ETHERFI_SAFE_FACTORY_ADMIN_ROLE from an account
    function revokeEtherFiSafeFactoryAdminRole(address account) external onlyAdmin {
        roleRegistry.revokeFast(keccak256("ETHERFI_SAFE_FACTORY_ADMIN_ROLE"), account);
    }

    /// @notice Instantly revokes the PAUSER role from an account
    function revokePauserRole(address account) external onlyAdmin {
        roleRegistry.revokeFast(keccak256("PAUSER"), account);
    }

    /// @notice Instantly revokes the UNPAUSER role from an account
    function revokeUnpauserRole(address account) external onlyAdmin {
        roleRegistry.revokeFast(keccak256("UNPAUSER"), account);
    }

    /// @notice Instantly revokes RAMP_VOLUME_EMITTER_ROLE from an account
    function revokeRampVolumeEmitterRole(address account) external onlyAdmin {
        roleRegistry.revokeFast(keccak256("RAMP_VOLUME_EMITTER_ROLE"), account);
    }

    /**
     * @notice Instantly revokes an arbitrary role from an account
     * @dev Covers roles added after this contract was deployed. The registry still
     *      refuses ADMIN_ROLE and ADMIN_TIMELOCK_ROLE.
     * @param role The role to revoke
     * @param account The account to revoke the role from
     */
    function revokeRoleFast(bytes32 role, address account) external onlyAdmin {
        roleRegistry.revokeFast(role, account);
    }
}
