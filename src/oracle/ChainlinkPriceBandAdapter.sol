// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAggregatorV3 } from "../interfaces/IAggregatorV3.sol";
import { IChainlinkPriceBandAdapter } from "../interfaces/IChainlinkPriceBandAdapter.sol";

/**
 * @title ChainlinkPriceBandAdapter
 * @notice Limits how fast a Chainlink feed can move the price we lend against. A single round may
 *         not move the reported price more than `BAND_BPS` in either direction against what the
 *         same feed was reporting `REFERENCE_AGE` earlier. Presents the standard aggregator
 *         interface, so it drops in anywhere the raw feed does.
 *
 * @dev WHAT THIS IS FOR
 *      If a collateral feed ever reports a wrong number - a glitch, a bug, or someone who has taken
 *      control of it - the money market believes it immediately. Reported too high, a borrower draws
 *      against collateral that is not worth it and the shortfall lands on suppliers. Reported too
 *      low, healthy positions are marked underwater and liquidated at a price that never traded,
 *      which the borrower cannot undo. This bounds how far either can go before someone notices.
 *
 *      It is NOT a source of truth. If the feed is wrong and stays wrong, this delays that reaching
 *      the market by roughly `REFERENCE_AGE` and then lets it through. It buys time; something has
 *      to use that time. `isCapped()` is an alert with a deadline, not a statistic.
 *
 * @dev THE REFERENCE IS ANCHORED IN TIME, NOT IN ROUND INDEX
 *      Bounding a round against its immediate predecessor bounds nothing when rounds are cheap.
 *      Compounding at 20% a round, four rounds halve a price and thirteen produce a ten-fold move,
 *      with every step passing the check. Not hypothetical: the live PAXG feed on Optimism has a
 *      minimum observed gap between rounds of ZERO seconds, has published three rounds inside one
 *      block, and put 84 rounds within two minutes of the one before.
 *
 *      So the reference is the newest round at least `REFERENCE_AGE` old. A burst all resolves to
 *      the same anchor, and posting more rounds buys no further movement. The guarantee changes
 *      from "20% per round", which is meaningless when rounds are free, to "20% per hour".
 *
 *      Sized against measurement: the worst one-hour move across the full history of the two target
 *      feeds is 7.50% (PAXG) and 1.54% (SPY), both comfortably inside a 2000 bps band.
 *
 *      The anchor is located by binary search, so it is found exactly however many rounds get
 *      posted. A bounded backwards walk would leave the very hole it was meant to close: flood past
 *      it and the reference becomes one of the attacker's own recent rounds, restoring the per-round
 *      bound - and the burst can be repeated inside the same block. The search relies on round
 *      timestamps inside a phase being non-decreasing, which holds because rounds are appended
 *      chronologically.
 *
 * @dev BOTH DIRECTIONS
 *      A manipulated low print is as damaging as a high one and lands on a different party. The
 *      usual objection to bounding falls - that it hides insolvency - does not apply, because the
 *      reference is the FEED's own history and never this adapter's clamped output. A genuine move
 *      is therefore always reported in full after a bounded delay, ended by either the anchor
 *      rolling past it or the band widening, neither of which needs the feed to publish again.
 *
 * @dev THE BAND WIDENS WITH THE AGE OF THE ROUND
 *      Chainlink publishes on a 0.5% deviation or a 24h heartbeat. A large move followed by a quiet
 *      market produces no further rounds, so a fixed band would hold a knowingly wrong price for up
 *      to a full day. The band therefore grows as the current round ages:
 *
 *          effectiveBand = BAND_BPS * (1 + age / WIDEN_PERIOD)
 *
 *      A clamp is a decaying speed bump rather than a wall: full strength on arrival, releasing over
 *      the following hours if the feed keeps insisting. This is safe on a feed that normally goes
 *      24h between rounds because widening only ever matters while something is clamped - an answer
 *      already inside the base band is inside every wider band too, and every new round arrives at
 *      age zero with the band at full strength.
 *
 *      It does weaken protection against a sustained manipulation: a value held flat is accepted in
 *      hours rather than at the next heartbeat. `WIDEN_PERIOD` is the deadline for acting on a clamp.
 *
 * @dev SIZING
 *      Anchor the band to market structure, not to fitted volatility. US market-wide circuit
 *      breakers halt equities at -7% / -13% / -20%, the last closing the session, so a single
 *      session cannot exceed 20% - a 2000 bps band cannot interfere with real trading by
 *      construction, and never once would have across the history of either feed. A band that
 *      clamps in normal markets is worse than none: it trains operators to ignore it.
 *
 * @author ether.fi
 */
contract ChainlinkPriceBandAdapter is IChainlinkPriceBandAdapter {
    uint256 internal constant BPS = 10_000;

    /// @notice Tightest permitted band.
    /// @dev Two constraints meet here. The target feeds publish on a 0.5% deviation threshold, and
    ///      that threshold is a trigger rather than a bound - PAXG printed 6.92% in one round
    ///      against it - so a band near the threshold would clamp routine movement. And because the
    ///      band is two-sided it also rate-limits how fast a genuine crash reaches consumers.
    uint16 public constant MIN_BAND_BPS = 500;

    /// @notice Loosest permitted band. At or above 100% nothing meaningful is bounded.
    uint16 public constant MAX_BAND_BPS = 10_000;

    /// @notice Tightest permitted widen period. Shorter and the band releases before anyone could
    ///         plausibly triage a clamp.
    uint32 public constant MIN_WIDEN_PERIOD = 15 minutes;

    /// @notice Longest permitted widen period.
    uint32 public constant MAX_WIDEN_PERIOD = 2 days;

    /// @notice Shortest permitted reference age.
    uint32 public constant MIN_REFERENCE_AGE = 5 minutes;

    /// @notice Longest permitted reference age. Beyond this the reference predates a full heartbeat
    ///         on these feeds and the band would start binding on ordinary movement.
    uint32 public constant MAX_REFERENCE_AGE = 12 hours;

    /// @dev Ceiling on the widened band so a dead feed cannot overflow the delta arithmetic.
    uint256 internal constant MAX_EFFECTIVE_BAND_BPS = 1_000_000;

    /// @inheritdoc IChainlinkPriceBandAdapter
    IAggregatorV3 public immutable FEED;

    /// @inheritdoc IChainlinkPriceBandAdapter
    uint16 public immutable BAND_BPS;

    /// @inheritdoc IChainlinkPriceBandAdapter
    uint32 public immutable WIDEN_PERIOD;

    /// @inheritdoc IChainlinkPriceBandAdapter
    uint32 public immutable REFERENCE_AGE;

    /// @inheritdoc IAggregatorV3
    uint8 public immutable decimals;

    /// @inheritdoc IAggregatorV3
    uint256 public constant version = 1;

    string private _description;

    /**
     * @param feed The Chainlink feed to wrap. Must expose `getRoundData`, which is what makes the
     *        time-anchored reference possible.
     * @param bandBps Band applied to a freshly published round, in basis points.
     * @param widenPeriod Seconds of round age that add one further `bandBps` to the band. Size it to
     *        how long triaging a clamp actually takes.
     * @param referenceAge How far back the reference round must sit, in seconds. This is the unit
     *        the band is denominated in: at 2000 bps and one hour, the bound is 20% per hour.
     * @param adapterDescription Human-readable description for this adapter.
     */
    constructor(IAggregatorV3 feed, uint16 bandBps, uint32 widenPeriod, uint32 referenceAge, string memory adapterDescription) {
        if (address(feed) == address(0)) revert FeedIsZeroAddress();
        if (bandBps < MIN_BAND_BPS || bandBps > MAX_BAND_BPS) revert InvalidBand(bandBps);
        if (widenPeriod < MIN_WIDEN_PERIOD || widenPeriod > MAX_WIDEN_PERIOD) revert InvalidWidenPeriod(widenPeriod);
        if (referenceAge < MIN_REFERENCE_AGE || referenceAge > MAX_REFERENCE_AGE) revert InvalidReferenceAge(referenceAge);

        FEED = feed;
        BAND_BPS = bandBps;
        WIDEN_PERIOD = widenPeriod;
        REFERENCE_AGE = referenceAge;
        decimals = feed.decimals();
        _description = adapterDescription;
    }

    /// @inheritdoc IAggregatorV3
    function latestAnswer() external view returns (int256) {
        (, int256 answer,,,) = _banded();
        return answer;
    }

    /// @inheritdoc IAggregatorV3
    /// @dev Reports the banded answer against the round's own id and timestamps, so a consumer's own
    ///      staleness check still measures the underlying feed's age.
    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) {
        (roundId, answer, startedAt, updatedAt,) = _banded();
        return (roundId, answer, startedAt, updatedAt, roundId);
    }

    /// @inheritdoc IAggregatorV3
    /// @dev Historical rounds pass through unbanded: the band describes what this adapter reports
    ///      NOW, and rewriting history would misrepresent what the feed actually published.
    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        return FEED.getRoundData(roundId);
    }

    /// @inheritdoc IAggregatorV3
    function description() external view returns (string memory) {
        return _description;
    }

    /// @inheritdoc IChainlinkPriceBandAdapter
    function rawAnswer() external view returns (int256) {
        (,,,, int256 raw) = _banded();
        return raw;
    }

    /// @inheritdoc IChainlinkPriceBandAdapter
    function referenceAnswer() external view returns (int256) {
        (uint80 roundId,,,,) = FEED.latestRoundData();
        (int256 refPrice,,) = _reference(roundId);
        return refPrice;
    }

    /// @inheritdoc IChainlinkPriceBandAdapter
    function hasReference() external view returns (bool) {
        (uint80 roundId,,,,) = FEED.latestRoundData();
        (, bool available,) = _reference(roundId);
        return available;
    }

    /// @inheritdoc IChainlinkPriceBandAdapter
    function referenceIsAnchored() external view returns (bool) {
        (uint80 roundId,,,,) = FEED.latestRoundData();
        (,, bool anchored) = _reference(roundId);
        return anchored;
    }

    /// @inheritdoc IChainlinkPriceBandAdapter
    function effectiveBandBps() external view returns (uint256) {
        (,,, uint256 updatedAt,) = FEED.latestRoundData();
        return _effectiveBandBps(updatedAt);
    }

    /// @inheritdoc IChainlinkPriceBandAdapter
    function roundAge() external view returns (uint256) {
        (,,, uint256 updatedAt,) = FEED.latestRoundData();
        return block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
    }

    /// @inheritdoc IChainlinkPriceBandAdapter
    function isCapped() external view returns (bool) {
        (, int256 answer,,, int256 raw) = _banded();
        return answer != raw;
    }

    /**
     * @dev Reads the latest round and applies the band.
     * @return roundId The feed's latest round id.
     * @return answer The banded answer.
     * @return startedAt The round's startedAt.
     * @return updatedAt The round's updatedAt.
     * @return raw The unmodified answer, so callers can tell whether the band bound.
     */
    function _banded() internal view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, int256 raw) {
        (roundId, raw, startedAt, updatedAt,) = FEED.latestRoundData();
        // A non-positive answer is a broken feed rather than an out-of-band price, and it is the one
        // case that is not clamped. Clamping zero to `refPrice - delta` would report a
        // plausible-looking number from a feed returning garbage and walk it down a band per round,
        // while a fresh `updatedAt` keeps every staleness check satisfied. Better to fail loudly.
        if (raw <= 0) revert InvalidPrice();

        answer = raw;
        (int256 refPrice, bool available,) = _reference(roundId);
        if (!available) return (roundId, answer, startedAt, updatedAt, raw);

        uint256 eff = _effectiveBandBps(updatedAt);
        // refPrice is positive and eff is capped, so the delta cannot overflow for any answer a
        // Chainlink aggregator can represent.
        int256 delta = (refPrice * int256(eff)) / int256(BPS);
        int256 ceiling = refPrice + delta;
        // Once the widened band reaches 100% the floor would be non-positive, which is simply no
        // lower bound at all. Report it as 1 wei so "never returns a non-positive price" holds
        // without the floor doing any work.
        int256 floor = eff >= BPS ? int256(1) : refPrice - delta;
        if (answer > ceiling) answer = ceiling;
        else if (answer < floor) answer = floor;

        return (roundId, answer, startedAt, updatedAt, raw);
    }

    /**
     * @dev The newest round at least `REFERENCE_AGE` old, within the same aggregator phase.
     *
     *      Anchoring in TIME rather than at `latestRound - 1` is what makes the band a bound per
     *      hour instead of per round. Without it, anyone able to produce rounds posts several in one
     *      block, each inside the band against its immediate predecessor, and walks the price
     *      anywhere - four rounds halve a price at a 20% band.
     *
     *      The anchor is found EXACTLY, not approximately. A bounded linear walk backwards would
     *      leave a hole: flood more rounds than the walk can cover and the reference becomes one of
     *      the attacker's own recent rounds, restoring the per-round bound they were trying to
     *      escape - and they can repeat it in the same block. So this binary searches instead.
     *      Round timestamps inside a phase are non-decreasing, because rounds are appended
     *      chronologically, which is exactly the property a binary search needs. The cost is one
     *      staticcall in the common case, rising to log2(rounds) only while a burst is in progress.
     *
     *      A Chainlink proxy round id packs `phaseId` in the high 16 bits and the aggregator's own
     *      round in the low 64. Reaching across a phase boundary reads a different aggregator and in
     *      practice answers zero - `phase 2, round 0` on the live OP SPY feed does exactly that. So
     *      the phase is fixed for the whole search.
     *
     *      `anchored` is false only when no round in this phase is old enough, which means the phase
     *      itself is younger than `REFERENCE_AGE` - a fresh aggregator upgrade, not something an
     *      attacker can manufacture. The oldest round in the phase is used then, which is the most
     *      conservative reference available rather than one of theirs.
     *
     *      Fails open with no usable round at all: the raw answer passes through rather than
     *      reverting, because a revert on a collateral price takes every action on the reserve with
     *      it, liquidation included. `hasReference()` and `referenceIsAnchored()` expose both states.
     */
    function _reference(uint80 latestRoundId) internal view returns (int256 answer, bool available, bool anchored) {
        uint64 latest = uint64(latestRoundId);
        if (latest <= 1) return (0, false, false);

        uint256 phase = uint256(uint16(latestRoundId >> 64)) << 64;
        uint256 cutoff = block.timestamp > REFERENCE_AGE ? block.timestamp - REFERENCE_AGE : 0;

        // Common case, one read: these feeds publish far less often than the anchor window, so the
        // immediately preceding round is already old enough.
        {
            (bool ok, int256 a, uint256 u) = _round(phase, latest - 1);
            if (!ok) return (0, false, false);
            if (u <= cutoff) return (a, true, true);
        }

        // A burst is in progress. Binary search for the NEWEST round at or before the cutoff.
        // Terminates structurally: `mid` always lies in [lo, hi] and each branch moves the bound past
        // it, so the range strictly shrinks - at most log2(uint64) iterations.
        uint64 lo = 1;
        uint64 hi = latest - 2;
        while (lo <= hi) {
            uint64 mid = lo + (hi - lo) / 2;
            (bool ok, int256 a, uint256 u) = _round(phase, mid);
            if (!ok) break; // unreadable history; fall through to the conservative branch
            if (u <= cutoff) {
                answer = a;
                anchored = true;
                lo = mid + 1;
            } else {
                if (mid == 0) break;
                hi = mid - 1;
            }
        }
        if (anchored) return (answer, true, true);

        // Nothing in this phase is old enough, so the phase itself is younger than REFERENCE_AGE -
        // a fresh aggregator upgrade, not something an attacker can manufacture. Use the oldest round
        // in the phase, which is the most conservative reference available rather than one of theirs.
        (bool ok1, int256 oldest,) = _round(phase, 1);
        if (ok1) return (oldest, true, false);
        return (0, false, false);
    }

    /// @dev One history read, normalised. `ok` is false for an unreadable or unwritten round.
    function _round(uint256 phase, uint64 round) internal view returns (bool ok, int256 answer, uint256 updatedAt) {
        try FEED.getRoundData(uint80(phase | uint256(round))) returns (uint80, int256 a, uint256, uint256 u, uint80) {
            if (a <= 0 || u == 0) return (false, 0, 0);
            return (true, a, u);
        } catch {
            return (false, 0, 0);
        }
    }

    /**
     * @dev `BAND_BPS * (1 + age / WIDEN_PERIOD)`, so the band is exactly `BAND_BPS` on a freshly
     *      published round and gains another `BAND_BPS` for every `WIDEN_PERIOD` it goes unrefreshed.
     *      A round timestamped in the future (clock skew between the feed and this chain) reads as
     *      age zero rather than underflowing.
     */
    function _effectiveBandBps(uint256 updatedAt) internal view returns (uint256) {
        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        uint256 eff = uint256(BAND_BPS) + (uint256(BAND_BPS) * age) / WIDEN_PERIOD;
        return eff > MAX_EFFECTIVE_BAND_BPS ? MAX_EFFECTIVE_BAND_BPS : eff;
    }
}
