// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Test } from "forge-std/Test.sol";

import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { ChainlinkCompositePriceFeed } from "../../src/oracle/ChainlinkCompositePriceFeed.sol";

/// @notice Fork tests on Optimism, using the live weETH/ETH rate feed and ETH/USD feed.
contract ChainlinkCompositePriceFeedTest is Test {
    using SafeCast for int256;

    // optimism
    address rateFeed = 0xb4479d436DDa5c1A79bD88D282725615202406E3; // weETH / ETH
    address ethUsdOracle = 0x13e3Ee699D1909E989722E753853AE30b17e08c5; // ETH / USD

    uint8 constant FEED_DECIMALS = 8;
    uint256 constant RATE_MAX_STALENESS = 1 days;
    uint256 constant UNDERLYING_MAX_STALENESS = 1 days;

    ChainlinkCompositePriceFeed feed;

    function setUp() public {
        vm.createSelectFork(vm.envOr("OPTIMISM_RPC", string("https://mainnet.optimism.io")));
        feed = new ChainlinkCompositePriceFeed(IAggregatorV3(rateFeed), IAggregatorV3(ethUsdOracle), FEED_DECIMALS, RATE_MAX_STALENESS, UNDERLYING_MAX_STALENESS, "weETH / USD");
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

    /// @notice Reverts when the rate feed is older than its staleness limit.
    function test_reverts_whenRateStale() public {
        (uint80 roundId, int256 rate, uint256 startedAt,, uint80 answeredInRound) = IAggregatorV3(rateFeed).latestRoundData();
        uint256 staleUpdatedAt = block.timestamp - RATE_MAX_STALENESS - 1;
        vm.mockCall(rateFeed, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), abi.encode(roundId, rate, startedAt, staleUpdatedAt, answeredInRound));
        vm.expectRevert(ChainlinkCompositePriceFeed.StalePrice.selector);
        feed.latestAnswer();
    }

    /// @notice Reverts when the underlying Chainlink price is older than its staleness limit.
    function test_reverts_whenUnderlyingStale() public {
        (uint80 roundId, int256 answer, uint256 startedAt,, uint80 answeredInRound) = IAggregatorV3(ethUsdOracle).latestRoundData();
        uint256 staleUpdatedAt = block.timestamp - UNDERLYING_MAX_STALENESS - 1;
        vm.mockCall(ethUsdOracle, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), abi.encode(roundId, answer, startedAt, staleUpdatedAt, answeredInRound));
        vm.expectRevert(ChainlinkCompositePriceFeed.StalePrice.selector);
        feed.latestAnswer();
    }

    /// @notice Reverts when the rate feed price is zero or negative.
    function test_reverts_whenRateNotPositive() public {
        vm.mockCall(rateFeed, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), abi.encode(uint80(1), int256(0), block.timestamp, block.timestamp, uint80(1)));
        vm.expectRevert(ChainlinkCompositePriceFeed.InvalidPrice.selector);
        feed.latestAnswer();
    }

    /// @notice Reverts when the underlying price is zero or negative.
    function test_reverts_whenUnderlyingNotPositive() public {
        vm.mockCall(ethUsdOracle, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), abi.encode(uint80(1), int256(0), block.timestamp, block.timestamp, uint80(1)));
        vm.expectRevert(ChainlinkCompositePriceFeed.InvalidPrice.selector);
        feed.latestAnswer();
    }
}
