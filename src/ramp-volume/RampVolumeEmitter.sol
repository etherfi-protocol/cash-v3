// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";
import { IRampVolumeEmitter } from "../interfaces/IRampVolumeEmitter.sol";

/**
 * @title RampVolumeEmitter
 * @author ether.fi
 * @notice Emits aggregated ether.fi Cash on/off-ramp volumes for off-chain indexing (Dune).
 * @dev Stateless w.r.t. volume: stores no totals and enforces no monotonicity. Volumes are
 *      day-attributed and intraday-cumulative; "latest event per (label, token, dayTimestamp)
 *      wins" is a consumer concern. Emission is restricted to RAMP_VOLUME_EMITTER_ROLE
 *      (the backend relayer). Follows the CashEventEmitter / SettlementDispatcherV2 pattern.
 */
contract RampVolumeEmitter is UpgradeableProxy, IRampVolumeEmitter {
    /// @notice Role authorized to emit RampVolume events (granted to the backend relayer).
    bytes32 public constant RAMP_VOLUME_EMITTER_ROLE = keccak256("RAMP_VOLUME_EMITTER_ROLE");

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the proxy with the role registry.
     * @param _roleRegistry Address of the role registry contract.
     */
    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
    }

    /// @inheritdoc IRampVolumeEmitter
    function emitRampVolume(bytes32 label, bytes32 token, uint64 dayTimestamp, uint256 value) external onlyRole(RAMP_VOLUME_EMITTER_ROLE) {
        emit RampVolume(label, token, dayTimestamp, value, uint64(block.timestamp));
    }

    /// @inheritdoc IRampVolumeEmitter
    function emitRampVolumes(RampVolumeData[] calldata items) external onlyRole(RAMP_VOLUME_EMITTER_ROLE) {
        uint64 asOf = uint64(block.timestamp);
        uint256 len = items.length;
        for (uint256 i = 0; i < len;) {
            RampVolumeData calldata item = items[i];
            emit RampVolume(item.label, item.token, item.dayTimestamp, item.value, asOf);
            unchecked {
                ++i;
            }
        }
    }
}
