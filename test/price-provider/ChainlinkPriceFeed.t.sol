// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Test } from "forge-std/Test.sol";

import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { L2SequencerGuardLib } from "../../src/libraries/L2SequencerGuardLib.sol";
import { ChainlinkPriceFeed } from "../../src/oracle/ChainlinkPriceFeed.sol";

/// @notice Fork tests on Optimism, using the live weETH/ETH rate feed and ETH/USD feed.
contract ChainlinkPriceFeedTest is Test {
    using SafeCast for int256;

    // optimism
    address rateFeed = 0xb4479d436DDa5c1A79bD88D282725615202406E3; // weETH / ETH
    address ethUsdOracle = 0x13e3Ee699D1909E989722E753853AE30b17e08c5; // ETH / USD

    uint8 constant FEED_DECIMALS = 8;
    uint256 constant RATE_MAX_STALENESS = 1 days;

    ChainlinkPriceFeed feed;

    function setUp() public {
        vm.createSelectFork(vm.envOr("OPTIMISM_RPC", string("https://mainnet.optimism.io")));
        // A raw Chainlink aggregator satisfies IAaveV4PriceFeed; any deployed feed can be the USD leg
        feed = new ChainlinkPriceFeed(IAggregatorV3(rateFeed), IAaveV4PriceFeed(ethUsdOracle), FEED_DECIMALS, RATE_MAX_STALENESS, false, "weETH / USD", IAggregatorV3(address(0)), 0);
    }

    /// @notice The reported price equals rate x underlying, and lands in a sane USD range.
    function test_latestAnswer_matchesRateTimesUnderlying() public view {
        (, int256 rate,,,) = IAggregatorV3(rateFeed).latestRoundData();
        (, int256 ethUsd,,,) = IAggregatorV3(ethUsdOracle).latestRoundData();

        uint256 expected = rate.toUint256() * ethUsd.toUint256() * (10 ** FEED_DECIMALS) / (10 ** (feed.rateDecimals() + feed.underlyingDecimals()));

        uint256 price = feed.latestAnswer().toUint256();
        assertEq(price, expected, "price mismatch");

        // Sanity on magnitude, which catches a decimals mistake: weETH should be a few thousand USD,
        // so well within 100 to 100,000 USD at 8 decimals.
        assertGt(price, 100 * (10 ** FEED_DECIMALS), "price too low");
        assertLt(price, 100_000 * (10 ** FEED_DECIMALS), "price too high");
    }

    function test_decimalsAndDescription() public view {
        assertEq(feed.decimals(), FEED_DECIMALS);
        assertEq(feed.description(), "weETH / USD");
    }

    /// @notice A Chainlink-backed Aave feed rejects prices while the L2 sequencer is down.
    function test_latestAnswer_revertsWhenSequencerIsDown() public {
        address sequencer = makeAddr("sequencer");
        vm.mockCall(sequencer, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), abi.encode(uint80(1), int256(1), block.timestamp - 2 hours, block.timestamp, uint80(1)));
        ChainlinkPriceFeed guardedFeed = new ChainlinkPriceFeed(IAggregatorV3(rateFeed), IAaveV4PriceFeed(ethUsdOracle), FEED_DECIMALS, RATE_MAX_STALENESS, false, "weETH / USD", IAggregatorV3(sequencer), 1 hours);

        vm.expectRevert(L2SequencerGuardLib.SequencerDown.selector);
        guardedFeed.latestAnswer();
    }

    /// @notice Reverts when the rate feed is older than its staleness limit.
    function test_reverts_whenRateStale() public {
        (uint80 roundId, int256 rate, uint256 startedAt,, uint80 answeredInRound) = IAggregatorV3(rateFeed).latestRoundData();
        uint256 staleUpdatedAt = block.timestamp - RATE_MAX_STALENESS - 1;
        vm.mockCall(rateFeed, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), abi.encode(roundId, rate, startedAt, staleUpdatedAt, answeredInRound));
        vm.expectRevert(ChainlinkPriceFeed.StalePrice.selector);
        feed.latestAnswer();
    }

    /// @notice Reverts at construction when the staleness bound is zero.
    function test_constructor_revertsOnZeroStaleness() public {
        vm.expectRevert(ChainlinkPriceFeed.InvalidMaxStaleness.selector);
        new ChainlinkPriceFeed(IAggregatorV3(rateFeed), IAaveV4PriceFeed(ethUsdOracle), FEED_DECIMALS, 0, false, "weETH / USD", IAggregatorV3(address(0)), 0);
    }

    /// @notice Reverts when the rate feed price is zero or negative.
    function test_reverts_whenRateNotPositive() public {
        vm.mockCall(rateFeed, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), abi.encode(uint80(1), int256(0), block.timestamp, block.timestamp, uint80(1)));
        vm.expectRevert(ChainlinkPriceFeed.InvalidPrice.selector);
        feed.latestAnswer();
    }

    /// @notice Reverts when the underlying price is zero or negative.
    function test_reverts_whenUnderlyingNotPositive() public {
        vm.mockCall(ethUsdOracle, abi.encodeWithSelector(IAaveV4PriceFeed.latestAnswer.selector), abi.encode(int256(0)));
        vm.expectRevert(ChainlinkPriceFeed.InvalidPrice.selector);
        feed.latestAnswer();
    }

    // ----------------------------------------------------------------- no-underlying mode

    /// @notice Without an underlying feed, the price is the USD-quoted Chainlink answer scaled to feed decimals.
    function test_noUnderlying_latestAnswer_isScaledAnswer() public {
        ChainlinkPriceFeed usdFeed = new ChainlinkPriceFeed(IAggregatorV3(ethUsdOracle), IAaveV4PriceFeed(address(0)), FEED_DECIMALS, RATE_MAX_STALENESS, false, "ETH / USD", IAggregatorV3(address(0)), 0);
        (, int256 raw,,,) = IAggregatorV3(ethUsdOracle).latestRoundData();
        assertEq(usdFeed.latestAnswer(), raw); // ETH/USD is already 8 decimals
    }

    /// @notice A stable feed snaps to exactly 1 USD inside the 1% band and passes the raw price outside it.
    function test_stable_snapsWithinOnePercent() public {
        ChainlinkPriceFeed stableFeed = new ChainlinkPriceFeed(IAggregatorV3(ethUsdOracle), IAaveV4PriceFeed(address(0)), FEED_DECIMALS, RATE_MAX_STALENESS, true, "USDC / USD", IAggregatorV3(address(0)), 0);
        _mockAnswer(0.995e8);
        assertEq(stableFeed.latestAnswer(), 1e8);
        _mockAnswer(0.99e8); // the 1% band edge is exclusive
        assertEq(stableFeed.latestAnswer(), 0.99e8);
        _mockAnswer(1.02e8);
        assertEq(stableFeed.latestAnswer(), 1.02e8);
    }

    function _mockAnswer(int256 answer) internal {
        vm.mockCall(ethUsdOracle, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), abi.encode(uint80(1), answer, block.timestamp, block.timestamp, uint80(1)));
    }

    /// @notice The no-underlying mode still enforces staleness on the Chainlink feed.
    function test_noUnderlying_revertsOnStale() public {
        ChainlinkPriceFeed usdFeed = new ChainlinkPriceFeed(IAggregatorV3(ethUsdOracle), IAaveV4PriceFeed(address(0)), FEED_DECIMALS, RATE_MAX_STALENESS, false, "ETH / USD", IAggregatorV3(address(0)), 0);
        (uint80 roundId, int256 answer, uint256 startedAt,, uint80 answeredInRound) = IAggregatorV3(ethUsdOracle).latestRoundData();
        uint256 staleUpdatedAt = block.timestamp - RATE_MAX_STALENESS - 1;
        vm.mockCall(ethUsdOracle, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), abi.encode(roundId, answer, startedAt, staleUpdatedAt, answeredInRound));
        vm.expectRevert(ChainlinkPriceFeed.StalePrice.selector);
        usdFeed.latestAnswer();
    }
}
