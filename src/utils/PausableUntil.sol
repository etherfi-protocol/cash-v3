// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import { IRoleRegistry } from "../interfaces/IRoleRegistry.sol";

/**
 * @title PausableUntil
 * @author ether.fi
 * @notice Auto-expiring emergency pause that a low-trust guardian can trip
 * @dev Extends OpenZeppelin's PausableUpgradeable by overriding `_requireNotPaused` so every
 *      function guarded by `whenNotPaused` also enforces the timed pause. The timed pause and
 *      the indefinite pause (PAUSER/UNPAUSER) are independent: lifting one does not lift the
 *      other. A guardian pause auto-expires after the configured duration and each guardian
 *      key is rate-limited by a cooldown, bounding the blast radius of a compromised key.
 */
abstract contract PausableUntil is PausableUpgradeable {
    /// @custom:storage-location erc7201:etherfi.storage.PausableUntil
    struct PausableUntilStorage {
        /// @notice Timestamp (inclusive) until which the contract is paused, 0 when never paused
        uint256 pausedUntil;
        /// @notice Duration applied by `pauseUntil`, falls back to MIN_PAUSE_DURATION when unset
        uint256 pauseUntilDuration;
        /// @notice Timestamp of each guardian's last pause, enforcing the per-guardian cooldown
        mapping(address => uint256) lastPauseTimestamp;
    }

    /// @notice Role identifier for guardians allowed to trip the timed pause
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Minimum timed pause duration, also the fallback when no duration is configured
    uint256 public constant MIN_PAUSE_DURATION = 8 hours;

    /// @notice Maximum timed pause duration
    uint256 public constant MAX_PAUSE_DURATION = 30 days;

    /// @notice Cooldown a guardian must wait after its pause expires before pausing again
    uint256 public constant PAUSER_UNTIL_COOLDOWN = 7 days;

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.PausableUntil")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PausableUntilStorageLocation = 0x297e298dc05105929d8ca10b807082979fcd5337ac991fc8f17dce28e407b000;

    /// @notice Emitted when a guardian pauses the contract
    /// @param pausedUntil Timestamp until which the contract is paused
    event PausedUntil(uint256 pausedUntil);

    /// @notice Emitted when governance lifts a timed pause early
    event UnpausedUntil();

    /// @notice Emitted when governance updates the timed pause duration
    /// @param pauseUntilDuration New duration applied by `pauseUntil`
    event PauseUntilDurationSet(uint256 pauseUntilDuration);

    /// @notice Error thrown when the contract is under an active timed pause
    error ContractPausedUntil(uint256 pausedUntil);

    /// @notice Error thrown when lifting a timed pause that is not active
    error ContractNotPausedUntil();

    /// @notice Error thrown when a guardian pauses again before its cooldown elapsed
    error PauserCooldownStillActive();

    /// @notice Error thrown when the timed pause duration is outside [MIN_PAUSE_DURATION, MAX_PAUSE_DURATION]
    error InvalidPauseUntilDuration();

    /// @notice Error thrown when caller does not hold the GUARDIAN_ROLE
    error OnlyGuardian();

    /**
     * @notice Returns the address of the Role Registry contract
     * @return roleRegistry Reference to the role registry contract
     */
    function roleRegistry() public view virtual returns (IRoleRegistry);

    /**
     * @notice Pauses the contract for the configured duration
     * @dev Only callable by accounts with the GUARDIAN_ROLE, `virtual` so contracts requiring
     *      stricter gating can override the access control
     */
    function pauseUntil() external virtual onlyGuardian {
        _pauseUntil();
    }

    /**
     * @notice Lifts an active timed pause early
     * @dev Only callable by the governance multisig, does not reset guardian cooldowns
     */
    function unpauseUntil() external onlyGovernanceMultisig {
        _requirePausedUntil();
        _getPausableUntilStorage().pausedUntil = 0;
        emit UnpausedUntil();
    }

    /**
     * @notice Sets the duration applied by `pauseUntil`
     * @dev Only callable by the governance multisig
     * @param _pauseUntilDuration New duration, bounded by [MIN_PAUSE_DURATION, MAX_PAUSE_DURATION]
     */
    function setPauseUntilDuration(uint256 _pauseUntilDuration) external onlyGovernanceMultisig {
        if (_pauseUntilDuration < MIN_PAUSE_DURATION || _pauseUntilDuration > MAX_PAUSE_DURATION) revert InvalidPauseUntilDuration();
        _getPausableUntilStorage().pauseUntilDuration = _pauseUntilDuration;
        emit PauseUntilDurationSet(_pauseUntilDuration);
    }

    /**
     * @notice Returns the timestamp (inclusive) until which the contract is paused
     */
    function pausedUntil() external view returns (uint256) {
        return _getPausableUntilStorage().pausedUntil;
    }

    /**
     * @notice Returns the duration applied by `pauseUntil`
     */
    function pauseUntilDuration() external view returns (uint256) {
        return _getPausableUntilStorage().pauseUntilDuration;
    }

    /**
     * @notice Returns the timestamp of a guardian's last pause
     * @param guardian Guardian address to query
     */
    function lastPauseTimestamp(address guardian) external view returns (uint256) {
        return _getPausableUntilStorage().lastPauseTimestamp[guardian];
    }

    /**
     * @notice Returns whether the contract is blocked by either the indefinite or the timed pause
     */
    function isPaused() public view returns (bool) {
        return paused() || _getPausableUntilStorage().pausedUntil >= block.timestamp;
    }

    /**
     * @dev Pauses the contract until `block.timestamp + pauseUntilDuration`
     *      Only callable when no timed pause is active and the caller is not in cooldown
     */
    function _pauseUntil() internal {
        _requireNotPausedUntil();
        PausableUntilStorage storage $ = _getPausableUntilStorage();
        uint256 duration = $.pauseUntilDuration;
        // An unset duration (fresh proxy, or a just-upgraded contract before governance calls
        // setPauseUntilDuration) falls back to the minimum so the emergency pause is never a
        // same-block no-op that still burns the guardian's cooldown.
        if (duration == 0) duration = MIN_PAUSE_DURATION;
        if ($.lastPauseTimestamp[msg.sender] + duration + PAUSER_UNTIL_COOLDOWN > block.timestamp) revert PauserCooldownStillActive();
        $.pausedUntil = block.timestamp + duration;
        $.lastPauseTimestamp[msg.sender] = block.timestamp;
        emit PausedUntil($.pausedUntil);
    }

    /**
     * @dev Reverts with ContractPausedUntil if a timed pause is active
     */
    function _requireNotPausedUntil() internal view {
        uint256 _pausedUntil = _getPausableUntilStorage().pausedUntil;
        if (_pausedUntil >= block.timestamp) revert ContractPausedUntil(_pausedUntil);
    }

    /**
     * @dev Reverts with ContractNotPausedUntil if no timed pause is active
     */
    function _requirePausedUntil() internal view {
        if (_getPausableUntilStorage().pausedUntil < block.timestamp) revert ContractNotPausedUntil();
    }

    /**
     * @dev Overrides {PausableUpgradeable-_requireNotPaused} so every function guarded by
     *      `whenNotPaused` also enforces the timed pause. Note this makes `_pause()` revert
     *      while a timed pause is active: governance must call `unpauseUntil()` before an
     *      indefinite `pause()`.
     */
    function _requireNotPaused() internal view virtual override {
        super._requireNotPaused();
        _requireNotPausedUntil();
    }

    /**
     * @dev Returns the storage struct from the specified storage slot
     * @return $ Reference to the PausableUntilStorage struct
     */
    function _getPausableUntilStorage() internal pure returns (PausableUntilStorage storage $) {
        assembly {
            $.slot := PausableUntilStorageLocation
        }
    }

    /**
     * @dev Modifier enforcing only the timed pause, for functions that must stay callable
     *      under an indefinite pause
     */
    modifier whenNotPausedUntil() {
        _requireNotPausedUntil();
        _;
    }

    /**
     * @dev Modifier to restrict access to holders of the GUARDIAN_ROLE
     */
    modifier onlyGuardian() {
        if (!roleRegistry().hasRole(GUARDIAN_ROLE, msg.sender)) revert OnlyGuardian();
        _;
    }

    /**
     * @dev Modifier to restrict access to holders of the GOVERNANCE_ROLE, implemented by
     *      the inheriting contract
     */
    modifier onlyGovernanceMultisig() virtual;
}
