// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAggregatorV3 } from "../interfaces/IAggregatorV3.sol";

/// @notice Protects L2 price reads while the sequencer is down and immediately after it recovers.
library L2SequencerGuardLib {
    error SequencerDown();
    error GracePeriodNotOver();

    function validate(IAggregatorV3 sequencerUptimeFeed, uint256 gracePeriod) internal view {
        if (address(sequencerUptimeFeed) == address(0)) return;

        (, int256 answer, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (startedAt == 0 || startedAt > block.timestamp || block.timestamp - startedAt <= gracePeriod) {
            revert GracePeriodNotOver();
        }
    }
}
