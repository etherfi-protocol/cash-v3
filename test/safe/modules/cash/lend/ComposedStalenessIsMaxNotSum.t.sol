// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

interface IFeedLike {
    function rateMaxStaleness() external view returns (uint256);
}
interface ICapLike {
    function BASE_TO_USD_AGGREGATOR() external view returns (address);
    function RATIO_PROVIDER() external view returns (address);
}
interface IAggLike {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
interface IVedaLike {
    struct S {
        address payoutAddress; uint96 highwaterMark; uint128 feesOwedInBase; uint128 totalSharesLastUpdate;
        uint96 exchangeRate; uint16 up; uint16 down; uint64 lastUpdateTimestamp; bool isPaused;
        uint24 minDelay; uint16 platformFee; uint16 perfFee;
    }
    function accountantState() external view returns (S memory);
}
interface IChainlinkLegLike { function rateFeed() external view returns (address); }
interface IVedaLegLike { function accountant() external view returns (address); }

/**
 * @title ComposedStalenessIsMaxNotSum
 * @notice Settles how the two independently-bounded legs of a price source compose: as a MAXIMUM
 *         (the tighter leg binds) or ADDITIVELY (the windows accumulate).
 *
 *         It matters operationally. If the bounds were additive, every composed asset would tolerate
 *         a served price twice as old as its per-leg bound, and a keeper alarm set at the per-leg
 *         bound would fire a full window late. The answer here is MAX, and it is proven rather than
 *         reasoned about, because "composed price" is a phrase that fits two different topologies:
 *
 *           MAX  — both legs re-check `block.timestamp > updatedAt + bound` inside the SAME call.
 *                  Independent simultaneous checks, so the call dies at min(deadline_a, deadline_b).
 *           SUM  — a value is STAMPED at one time and CONSUMED later (relay/bridge shapes). The
 *                  relayed datum may already be near its source bound when stamped, and the sink
 *                  then permits its own window on top.
 *
 *         Aave's cap adapters and our `...PriceFeed` legs are the first shape. This test pins that,
 *         so a future reviewer does not re-derive it wrongly from the second.
 *
 * Run:
 *   FOUNDRY_PROFILE=aave-deploy forge test \
 *     --match-contract ComposedStalenessIsMaxNotSum --fork-url $OPTIMISM_RPC -vv
 */
contract ComposedStalenessIsMaxNotSum is Test {
    /// @dev liquidETH cap adapter: base = ETH/USD Chainlink leg, ratio = Veda accountant leg.
    address constant ADAPTER = 0x48420d702a3190235B5A5D123ca82f876752add1;
    /// @dev iwSPYx sink feed, which composes an underlying SPY/USD leg.
    address constant SINK_FEED = 0x253F4Fb7082e314430972A2B783aD7514D20d64c;
    address constant SINK_UNDERLYING = 0x045ACc54e73f93c5b9B4F20Fa01931cB23234C38;

    function _reverts(address target) internal view returns (bool) {
        (bool ok,) = target.staticcall(abi.encodeWithSignature("latestAnswer()"));
        return !ok;
    }

    /// @notice A cap adapter dies at the EARLIER of its two legs' deadlines, so the oldest datum it
    ///         can ever serve is bounded by max(boundA, boundB) — never their sum.
    function test_capAdapter_boundIsMaxNotSum() public {
        address baseLeg = ICapLike(ADAPTER).BASE_TO_USD_AGGREGATOR();
        address ratioLeg = ICapLike(ADAPTER).RATIO_PROVIDER();

        uint256 baseBound = IFeedLike(baseLeg).rateMaxStaleness();
        uint256 ratioBound = IFeedLike(ratioLeg).rateMaxStaleness();
        assertGt(baseBound, 0, "base leg carries no bound - test would be vacuous");
        assertGt(ratioBound, 0, "ratio leg carries no bound - test would be vacuous");

        uint256 baseDeadline;
        {
            (,,, uint256 u,) = IAggLike(IChainlinkLegLike(baseLeg).rateFeed()).latestRoundData();
            assertGt(u, 0, "base leg has no data timestamp");
            baseDeadline = u + baseBound;
        }
        uint256 ratioDeadline =
            uint256(IVedaLike(IVedaLegLike(ratioLeg).accountant()).accountantState().lastUpdateTimestamp) + ratioBound;
        assertGt(ratioDeadline, ratioBound, "ratio leg has no data timestamp");

        uint256 earliest = baseDeadline < ratioDeadline ? baseDeadline : ratioDeadline;
        uint256 latest = baseDeadline > ratioDeadline ? baseDeadline : ratioDeadline;
        assertTrue(earliest > block.timestamp, "both legs already stale on this fork - test would be vacuous");

        // Alive at the earlier deadline, dead one second later — while the other leg is still fresh.
        vm.warp(earliest);
        assertFalse(_reverts(ADAPTER), "adapter must still price AT the earlier deadline");

        vm.warp(earliest + 1);
        assertTrue(_reverts(ADAPTER), "adapter must fail one second past the EARLIER deadline");

        // It can never be reached at the later deadline: the tighter leg binds first.
        if (latest > earliest) {
            vm.warp(latest);
            assertTrue(_reverts(ADAPTER), "adapter cannot survive to the LATER deadline");
        }

        // The decisive assertion: the SUM is unreachable.
        uint256 maxBound = baseBound > ratioBound ? baseBound : ratioBound;
        assertLt(maxBound, baseBound + ratioBound, "bounds must differ from their sum for this to mean anything");
        vm.warp(earliest + maxBound);
        assertTrue(_reverts(ADAPTER), "adapter must be long dead well before base+ratio elapses");

        console.log("max(base,ratio) =", maxBound);
        console.log("base+ratio      =", baseBound + ratioBound, "(unreachable)");
    }

    /// @notice A feed composing an `underlyingUsdFeed` behaves the same way: it dies the instant the
    ///         underlying goes stale, whatever its own window is.
    function test_sinkFeed_diesWithItsUnderlying() public {
        uint256 underBound = IFeedLike(SINK_UNDERLYING).rateMaxStaleness();
        (,,, uint256 u,) = IAggLike(IChainlinkLegLike(SINK_UNDERLYING).rateFeed()).latestRoundData();
        assertGt(u, 0, "underlying has no data timestamp");

        uint256 underDeadline = u + underBound;
        assertTrue(underDeadline > block.timestamp, "underlying already stale - test would be vacuous");

        vm.warp(underDeadline);
        assertFalse(_reverts(SINK_FEED), "sink feed must still price at its underlying's deadline");

        vm.warp(underDeadline + 1);
        assertTrue(_reverts(SINK_FEED), "sink feed must die when its UNDERLYING is stale");
    }
}
