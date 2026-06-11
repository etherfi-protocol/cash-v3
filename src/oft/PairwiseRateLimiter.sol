// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OFTCoreUpgradeable } from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTCoreUpgradeable.sol";

/**
 * @title PairwiseRateLimiter
 * @author ether.fi
 * @notice Per-pathway throughput cap for the OFT bridges. Ported from the weETH
 *         cross-chain work (`PairwiseRateLimiter`): the upstream LayerZero rate
 *         limiter only meters outbound messages, this meters BOTH directions with
 *         an independent limit per peer endpoint id.
 * @dev Mixed into the beacon OFT impls ({EtherFiOFTAdapter}, {EtherFiShadowOFT}).
 *      Children call {_checkAndUpdateOutboundRateLimit} in `_debit` (send) and
 *      {_checkAndUpdateInboundRateLimit} in `_credit` (receive). Capacity replenishes
 *      linearly over the configured window.
 *
 *      Amounts are metered in the asset's LOCAL decimals (LD): every proxy backs a
 *      single asset with a single `decimalConversionRate`, so the per-bridge limit is
 *      denominated in that asset's units. `limit`/`window`/`amountInFlight` are
 *      `uint256` (an 18-decimal cap can exceed `uint64`).
 *
 *      Fail-closed: an unconfigured pathway (`limit == 0`) allows zero throughput, so a
 *      bridge must have its limits explicitly set before it can move value. This matches
 *      the rest of cash-v3 (spending limits, oracle staleness) where zero means blocked.
 *      State lives in ERC-7201 namespaced storage so the limiter can be added to an
 *      existing beacon impl without disturbing any deployed proxy's layout.
 *
 *      Inherits {OFTCoreUpgradeable} purely to share the `onlyOwner` (delegate) gate on
 *      the setters; it is already the common base of the OFT impls, so this adds no new
 *      inheritance diamond.
 */
abstract contract PairwiseRateLimiter is OFTCoreUpgradeable {
    /**
     * @notice Rate limit state for a single pathway.
     * @param amountInFlight The amount counted in the current (decaying) window.
     * @param lastUpdated Timestamp the rate limit was last checked or updated.
     * @param limit Maximum amount allowed within a window.
     * @param window Duration of the rate-limiting window, in seconds.
     */
    struct RateLimit {
        uint256 amountInFlight;
        uint256 lastUpdated;
        uint256 limit;
        uint256 window;
    }

    /**
     * @notice Rate limit configuration input.
     * @param peerEid The peer endpoint id this config applies to.
     * @param limit Maximum amount allowed within a window.
     * @param window Duration of the rate-limiting window, in seconds.
     */
    struct RateLimitConfig {
        uint32 peerEid;
        uint256 limit;
        uint256 window;
    }

    /// @custom:storage-location erc7201:etherfi.storage.PairwiseRateLimiter
    struct PairwiseRateLimiterStorage {
        /// @notice Outbound (send) limits, keyed by destination endpoint id
        mapping(uint32 dstEid => RateLimit) outboundRateLimits;
        /// @notice Inbound (receive) limits, keyed by source endpoint id
        mapping(uint32 srcEid => RateLimit) inboundRateLimits;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.PairwiseRateLimiter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PairwiseRateLimiterStorageLocation = 0x7f5b707dd949ce880b63fa3570a51e92d8b382587579a84776075096ec18c500;

    /// @notice Emitted when outbound limits are (re)configured.
    event OutboundRateLimitsChanged(RateLimitConfig[] rateLimitConfigs);
    /// @notice Emitted when inbound limits are (re)configured.
    event InboundRateLimitsChanged(RateLimitConfig[] rateLimitConfigs);

    /// @notice Thrown when a send would exceed the outbound limit for the destination.
    error OutboundRateLimitExceeded();
    /// @notice Thrown when a receive would exceed the inbound limit for the source.
    error InboundRateLimitExceeded();

    // ---------------------------------------------------------------------
    // Owner-gated configuration (owner == OApp delegate)
    // ---------------------------------------------------------------------

    /// @notice Sets the outbound (send) limits. Only the OApp owner (delegate) may call.
    function setOutboundRateLimits(RateLimitConfig[] calldata _rateLimitConfigs) external onlyOwner {
        _setOutboundRateLimits(_rateLimitConfigs);
    }

    /// @notice Sets the inbound (receive) limits. Only the OApp owner (delegate) may call.
    function setInboundRateLimits(RateLimitConfig[] calldata _rateLimitConfigs) external onlyOwner {
        _setInboundRateLimits(_rateLimitConfigs);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Returns the raw outbound rate-limit state for a destination endpoint id.
    function outboundRateLimit(uint32 _dstEid) external view returns (RateLimit memory) {
        return _getRateLimiterStorage().outboundRateLimits[_dstEid];
    }

    /// @notice Returns the raw inbound rate-limit state for a source endpoint id.
    function inboundRateLimit(uint32 _srcEid) external view returns (RateLimit memory) {
        return _getRateLimiterStorage().inboundRateLimits[_srcEid];
    }

    /**
     * @notice Current outbound utilization for a destination endpoint id.
     * @return outboundAmountInFlight The amount currently counted in the window.
     * @return amountCanBeSent The amount that can still be sent right now.
     */
    function getAmountCanBeSent(uint32 _dstEid) external view virtual returns (uint256 outboundAmountInFlight, uint256 amountCanBeSent) {
        RateLimit memory rl = _getRateLimiterStorage().outboundRateLimits[_dstEid];
        return _amountCanBeSent(rl.amountInFlight, rl.lastUpdated, rl.limit, rl.window);
    }

    /**
     * @notice Current inbound utilization for a source endpoint id.
     * @return inboundAmountInFlight The amount currently counted in the window.
     * @return amountCanBeReceived The amount that can still be received right now.
     */
    function getAmountCanBeReceived(uint32 _srcEid) external view virtual returns (uint256 inboundAmountInFlight, uint256 amountCanBeReceived) {
        RateLimit memory rl = _getRateLimiterStorage().inboundRateLimits[_srcEid];
        return _amountCanBeSent(rl.amountInFlight, rl.lastUpdated, rl.limit, rl.window);
    }

    // ---------------------------------------------------------------------
    // Internal: configuration
    // ---------------------------------------------------------------------

    /// @dev Checkpoints decay before applying new limit/window; never resets amountInFlight/lastUpdated.
    function _setOutboundRateLimits(RateLimitConfig[] memory _rateLimitConfigs) internal virtual {
        PairwiseRateLimiterStorage storage $ = _getRateLimiterStorage();
        unchecked {
            for (uint256 i = 0; i < _rateLimitConfigs.length; i++) {
                RateLimit storage rl = $.outboundRateLimits[_rateLimitConfigs[i].peerEid];

                // Checkpoint the existing in-flight amount so the new window does not retroactively decay it.
                _checkAndUpdateOutboundRateLimit(_rateLimitConfigs[i].peerEid, 0);

                rl.limit = _rateLimitConfigs[i].limit;
                rl.window = _rateLimitConfigs[i].window;
            }
        }
        emit OutboundRateLimitsChanged(_rateLimitConfigs);
    }

    /// @dev Checkpoints decay before applying new limit/window; never resets amountInFlight/lastUpdated.
    function _setInboundRateLimits(RateLimitConfig[] memory _rateLimitConfigs) internal virtual {
        PairwiseRateLimiterStorage storage $ = _getRateLimiterStorage();
        unchecked {
            for (uint256 i = 0; i < _rateLimitConfigs.length; i++) {
                RateLimit storage rl = $.inboundRateLimits[_rateLimitConfigs[i].peerEid];

                // Checkpoint the existing in-flight amount so the new window does not retroactively decay it.
                _checkAndUpdateInboundRateLimit(_rateLimitConfigs[i].peerEid, 0);

                rl.limit = _rateLimitConfigs[i].limit;
                rl.window = _rateLimitConfigs[i].window;
            }
        }
        emit InboundRateLimitsChanged(_rateLimitConfigs);
    }

    // ---------------------------------------------------------------------
    // Internal: decay math + check-and-update (called from _debit / _credit)
    // ---------------------------------------------------------------------

    /**
     * @dev Linear-decay accounting for a window.
     * @return currentAmountInFlight The decayed in-flight amount.
     * @return amountCanBeSent The remaining capacity in the window.
     */
    function _amountCanBeSent(uint256 _amountInFlight, uint256 _lastUpdated, uint256 _limit, uint256 _window) internal view virtual returns (uint256 currentAmountInFlight, uint256 amountCanBeSent) {
        uint256 timeSinceLastDeposit = block.timestamp - _lastUpdated;
        if (timeSinceLastDeposit >= _window) {
            currentAmountInFlight = 0;
            amountCanBeSent = _limit;
        } else {
            // Linear decay of the in-flight amount over the window.
            uint256 decay = (_limit * timeSinceLastDeposit) / _window;
            currentAmountInFlight = _amountInFlight <= decay ? 0 : _amountInFlight - decay;
            // If the limit was lowered below the current in-flight amount, no further capacity is available.
            amountCanBeSent = _limit <= currentAmountInFlight ? 0 : _limit - currentAmountInFlight;
        }
    }

    /**
     * @dev Verifies `_amount` is within the outbound limit for `_dstEid`, then checkpoints the new
     *      in-flight amount and timestamp. Reverts {OutboundRateLimitExceeded} on breach. An
     *      unconfigured pathway (`limit == 0`) has `amountCanBeSent == 0`, so any non-zero send reverts.
     */
    function _checkAndUpdateOutboundRateLimit(uint32 _dstEid, uint256 _amount) internal virtual {
        RateLimit storage rl = _getRateLimiterStorage().outboundRateLimits[_dstEid];

        (uint256 currentAmountInFlight, uint256 amountCanBeSent) = _amountCanBeSent(rl.amountInFlight, rl.lastUpdated, rl.limit, rl.window);
        if (_amount > amountCanBeSent) revert OutboundRateLimitExceeded();

        rl.amountInFlight = currentAmountInFlight + _amount;
        rl.lastUpdated = block.timestamp;
    }

    /**
     * @dev Verifies `_amount` is within the inbound limit for `_srcEid`, then checkpoints the new
     *      in-flight amount and timestamp. Reverts {InboundRateLimitExceeded} on breach. An
     *      unconfigured pathway (`limit == 0`) has zero capacity, so any non-zero receive reverts.
     */
    function _checkAndUpdateInboundRateLimit(uint32 _srcEid, uint256 _amount) internal virtual {
        RateLimit storage rl = _getRateLimiterStorage().inboundRateLimits[_srcEid];

        (uint256 currentAmountInFlight, uint256 amountCanBeReceived) = _amountCanBeSent(rl.amountInFlight, rl.lastUpdated, rl.limit, rl.window);
        if (_amount > amountCanBeReceived) revert InboundRateLimitExceeded();

        rl.amountInFlight = currentAmountInFlight + _amount;
        rl.lastUpdated = block.timestamp;
    }

    function _getRateLimiterStorage() private pure returns (PairwiseRateLimiterStorage storage $) {
        assembly {
            $.slot := PairwiseRateLimiterStorageLocation
        }
    }
}
