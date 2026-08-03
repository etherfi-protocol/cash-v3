// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title Blacklister
 * @author ether.fi
 * @notice Central address-level freeze registry for the cash protocol
 * @dev UUPS singleton mirroring smart-contracts/src/governance/Blacklister.sol, on the
 *      cash-v3 UpgradeableProxy base. Consumers hold this contract's address and call
 *      `nonBlacklisted(user)` as a view guard; where that guard is enforced is decided
 *      per flow in the wiring.
 *      Two tiers: a low-trust guardian can freeze an address for a fixed, auto-expiring
 *      window, while the governance multisig can freeze for an arbitrary duration or
 *      indefinitely, and lift any freeze. The freeze gate itself is deliberately never
 *      gated by the pause: `nonBlacklisted` must stay readable under any pause state.
 */
contract Blacklister is UpgradeableProxy {
    /// @custom:storage-location erc7201:etherfi.storage.Blacklister
    struct BlacklisterStorage {
        /// @notice Timestamp (exclusive) until which each user is blacklisted, 0 when never blacklisted
        mapping(address => uint256) blacklistedUntil;
    }

    /// @notice Role identifier for guardians allowed to trip the auto-expiring blacklist
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Fixed window applied by the guardian's `blacklistUserUntil`
    uint256 public constant BLACKLIST_DURATION = 3 days;

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.Blacklister")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BlacklisterStorageLocation = 0x9ea2b95533369649149a4112dbf03a9ec872da99b01b6ea9b13a361bcd248100;

    /// @notice Emitted when a user is blacklisted indefinitely
    /// @param user Address that was blacklisted
    event UserBlacklisted(address indexed user);

    /// @notice Emitted when a user's blacklist is lifted
    /// @param user Address that was unblacklisted
    event UserUnblacklisted(address indexed user);

    /// @notice Emitted when a user is blacklisted until a timestamp
    /// @param user Address that was blacklisted
    /// @param until Timestamp (exclusive) until which the user is blacklisted
    event UserBlacklistedUntil(address indexed user, uint256 until);

    /// @notice Error thrown when the user address is the zero address
    error InvalidUser();

    /// @notice Error thrown by `nonBlacklisted` when the user is blacklisted
    error BlacklistedUser(address user);

    /// @notice Error thrown when a guardian blacklists a user whose blacklist is still active
    error UserAlreadyBlacklisted(address user);

    /// @notice Error thrown when caller does not hold the GUARDIAN_ROLE
    error OnlyGuardian();

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract
     * @param _roleRegistry Address of the role registry contract
     */
    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
    }

    /**
     * @notice Blacklists a user for the fixed BLACKLIST_DURATION window
     * @dev Only callable by accounts with the GUARDIAN_ROLE. The already-blacklisted guard
     *      prevents a guardian from chaining windows to extend a freeze indefinitely.
     * @param user Address to blacklist
     * @custom:throws InvalidUser if `user` is the zero address
     * @custom:throws UserAlreadyBlacklisted if the user's blacklist is still active
     */
    function blacklistUserUntil(address user) external onlyGuardian {
        if (user == address(0)) revert InvalidUser();
        BlacklisterStorage storage $ = _getBlacklisterStorage();
        if ($.blacklistedUntil[user] > block.timestamp) revert UserAlreadyBlacklisted(user);
        uint256 until = block.timestamp + BLACKLIST_DURATION;
        $.blacklistedUntil[user] = until;
        emit UserBlacklistedUntil(user, until);
    }

    /**
     * @notice Blacklists a user for an arbitrary duration from now
     * @dev Only callable by the governance multisig. Overwrites any existing blacklist,
     *      including an indefinite one — a zero duration is therefore an immediate lift.
     * @param user Address to blacklist
     * @param duration Seconds from now until the blacklist expires
     * @custom:throws InvalidUser if `user` is the zero address
     */
    function setBlacklistUntil(address user, uint256 duration) external onlyGovernanceMultisig {
        if (user == address(0)) revert InvalidUser();
        uint256 until = block.timestamp + duration;
        _getBlacklisterStorage().blacklistedUntil[user] = until;
        emit UserBlacklistedUntil(user, until);
    }

    /**
     * @notice Blacklists a user indefinitely
     * @dev Only callable by the governance multisig
     * @param user Address to blacklist
     * @custom:throws InvalidUser if `user` is the zero address
     */
    function blacklistUser(address user) external onlyGovernanceMultisig {
        if (user == address(0)) revert InvalidUser();
        _getBlacklisterStorage().blacklistedUntil[user] = type(uint256).max;
        emit UserBlacklisted(user);
    }

    /**
     * @notice Lifts a user's blacklist, timed or indefinite
     * @dev Only callable by the governance multisig
     * @param user Address to unblacklist
     */
    function unblacklistUser(address user) external onlyGovernanceMultisig {
        _getBlacklisterStorage().blacklistedUntil[user] = 0;
        emit UserUnblacklisted(user);
    }

    /**
     * @notice Reverts if the user is blacklisted, passes otherwise
     * @dev The gate is a strict `>` — at exactly `blacklistedUntil[user]` the gate is open
     * @param user Address to check
     * @custom:throws BlacklistedUser if the user's blacklist is active
     */
    function nonBlacklisted(address user) external view {
        if (_getBlacklisterStorage().blacklistedUntil[user] > block.timestamp) revert BlacklistedUser(user);
    }

    /**
     * @notice Returns whether the user is currently blacklisted
     * @param user Address to check
     */
    function isBlacklisted(address user) external view returns (bool) {
        return _getBlacklisterStorage().blacklistedUntil[user] > block.timestamp;
    }

    /**
     * @notice Returns the timestamp (exclusive) until which the user is blacklisted
     * @param user Address to check
     */
    function blacklistedUntil(address user) external view returns (uint256) {
        return _getBlacklisterStorage().blacklistedUntil[user];
    }

    /**
     * @dev Returns the storage struct from the specified storage slot
     * @return $ Reference to the BlacklisterStorage struct
     */
    function _getBlacklisterStorage() internal pure returns (BlacklisterStorage storage $) {
        assembly {
            $.slot := BlacklisterStorageLocation
        }
    }

    /**
     * @dev Modifier to restrict access to holders of the GUARDIAN_ROLE
     */
    modifier onlyGuardian() {
        if (!roleRegistry().hasRole(GUARDIAN_ROLE, msg.sender)) revert OnlyGuardian();
        _;
    }
}
