// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAggregatorV3 } from "../interfaces/IAggregatorV3.sol";
import { L2SequencerGuardLib } from "../libraries/L2SequencerGuardLib.sol";

/// @notice Shared immutable sequencer configuration for L2 price-feed adapters.
abstract contract L2SequencerGuard {
    IAggregatorV3 public immutable sequencerUptimeFeed;
    uint256 public immutable sequencerGracePeriod;

    error InvalidSequencerConfig();

    constructor(IAggregatorV3 _sequencerUptimeFeed, uint256 _sequencerGracePeriod) {
        if ((address(_sequencerUptimeFeed) == address(0)) != (_sequencerGracePeriod == 0)) {
            revert InvalidSequencerConfig();
        }
        sequencerUptimeFeed = _sequencerUptimeFeed;
        sequencerGracePeriod = _sequencerGracePeriod;
    }

    function _validateSequencer() internal view {
        L2SequencerGuardLib.validate(sequencerUptimeFeed, sequencerGracePeriod);
    }
}
