// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IRampVolumeEmitter
 * @notice Interface for the RampVolumeEmitter contract that emits aggregated
 *         ether.fi Cash on/off-ramp volumes for off-chain indexing (e.g. Dune).
 */
interface IRampVolumeEmitter {
    /**
     * @notice A single day-to-date volume datapoint for one (label, token, day) bucket.
     * @param label Ramp direction as a bytes32 string: bytes32("onramp") | bytes32("offramp").
     * @param token Token as a bytes32 string: bytes32("USDC") | bytes32("EURC").
     * @param dayTimestamp UTC-midnight (00:00:00Z) of the attributed day.
     * @param value Day-to-date cumulative volume, 6-decimals USD.
     */
    struct RampVolumeData {
        bytes32 label;
        bytes32 token;
        uint64 dayTimestamp;
        uint256 value;
    }

    /**
     * @notice Emitted for each (label, token, day) bucket pushed on-chain.
     * @dev Intraday-cumulative: the latest event per (label, token, dayTimestamp) — ordered
     *      by asOf, then log index — is that day's current total. value is NOT monotonic
     *      (refunds can shrink it). Restatement re-emits a past dayTimestamp.
     * @param label Indexed ramp direction (bytes32 string).
     * @param token Indexed token (bytes32 string).
     * @param dayTimestamp Indexed UTC-midnight of the attributed day.
     * @param value Day-to-date cumulative volume, 6-decimals USD.
     * @param asOf Emission time (block timestamp) for latest-wins ordering.
     */
    event RampVolume(bytes32 indexed label, bytes32 indexed token, uint64 indexed dayTimestamp, uint256 value, uint64 asOf);

    /// @notice Emit a single day-to-date volume datapoint.
    function emitRampVolume(bytes32 label, bytes32 token, uint64 dayTimestamp, uint256 value) external;

    /// @notice Emit all changed (label, token, day) buckets for an hourly run in one tx.
    function emitRampVolumes(RampVolumeData[] calldata items) external;
}
