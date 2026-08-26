// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { BaseAaveV4PriceFeed } from "../../src/oracle/BaseAaveV4PriceFeed.sol";
import { IOracleSink } from "../../src/interfaces/IOracleSink.sol";
import { OracleSinkPriceFeed } from "../../src/oracle/OracleSinkPriceFeed.sol";

/// @notice Local stand-in for the cash-mainnet-asset-listing OracleSink: same token-keyed
///         Chainlink-shaped surface, with the stored price and source read time settable per test.
contract MockOracleSink {
    error PriceNotSet();

    struct Point {
        uint256 price;
        uint64 srcUpdatedAt;
        bool set;
    }

    mapping(address token => Point) internal points;

    function setPrice(address token, uint256 price, uint64 srcUpdatedAt) external {
        points[token] = Point(price, srcUpdatedAt, true);
    }

    function latestRoundData(address token) external view returns (uint80, int256, uint256, uint256, uint80) {
        Point memory p = points[token];
        if (!p.set) revert PriceNotSet();
        return (0, int256(p.price), p.srcUpdatedAt, p.srcUpdatedAt, 0);
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }
}

contract OracleSinkPriceFeedTest is Test {
    uint8 constant SINK_DECIMALS = 6;
    uint8 constant FEED_DECIMALS = 8;
    uint256 constant RATE_MAX_STALENESS = 1 hours;
    uint256 constant START_TIMESTAMP = 1_753_000_000;

    address wspyx = makeAddr("wspyx");

    MockOracleSink sink;
    OracleSinkPriceFeed feed;

    function setUp() public {
        vm.warp(START_TIMESTAMP);
        sink = new MockOracleSink();
        sink.setPrice(wspyx, 620e6, uint64(block.timestamp));
        feed = new OracleSinkPriceFeed(IOracleSink(address(sink)), wspyx, IAaveV4PriceFeed(address(0)), FEED_DECIMALS, RATE_MAX_STALENESS, false, "wSPYX / USD");
    }

    /// @notice The sink's 6-decimal USD price is scaled to feed decimals.
    function test_latestAnswer_scalesSinkPriceToFeedDecimals() public view {
        assertEq(feed.latestAnswer(), 620e8);
        assertEq(feed.rateDecimals(), SINK_DECIMALS);
    }

    function test_decimalsAndDescription() public view {
        assertEq(feed.decimals(), FEED_DECIMALS);
        assertEq(feed.description(), "wSPYX / USD");
        assertEq(feed.token(), wspyx);
        assertEq(address(feed.sink()), address(sink));
    }

    /// @notice The price stays fresh up to exactly srcUpdatedAt + maxStaleness and reverts one second past it.
    function test_stalenessBoundary() public {
        vm.warp(START_TIMESTAMP + RATE_MAX_STALENESS);
        assertEq(feed.latestAnswer(), 620e8);

        vm.warp(START_TIMESTAMP + RATE_MAX_STALENESS + 1);
        vm.expectRevert(BaseAaveV4PriceFeed.StalePrice.selector);
        feed.latestAnswer();
    }

    /// @notice A zero answer from the sink is rejected.
    function test_reverts_whenAnswerZero() public {
        sink.setPrice(wspyx, 0, uint64(block.timestamp));
        vm.expectRevert(BaseAaveV4PriceFeed.InvalidPrice.selector);
        feed.latestAnswer();
    }

    /// @notice A token the sink has never priced fails closed: the sink's revert propagates.
    function test_reverts_whenPriceNotSet() public {
        OracleSinkPriceFeed unsetFeed = new OracleSinkPriceFeed(IOracleSink(address(sink)), makeAddr("unlisted"), IAaveV4PriceFeed(address(0)), FEED_DECIMALS, RATE_MAX_STALENESS, false, "unlisted / USD");
        vm.expectRevert(MockOracleSink.PriceNotSet.selector);
        unsetFeed.latestAnswer();
    }

    /// @notice A stable feed snaps to exactly 1 USD inside the 1% band and passes the raw price outside it.
    function test_stable_snapsWithinOnePercent() public {
        address usdcb = makeAddr("usdcb");
        OracleSinkPriceFeed stableFeed = new OracleSinkPriceFeed(IOracleSink(address(sink)), usdcb, IAaveV4PriceFeed(address(0)), FEED_DECIMALS, RATE_MAX_STALENESS, true, "USDCB / USD");

        sink.setPrice(usdcb, 0.995e6, uint64(block.timestamp));
        assertEq(stableFeed.latestAnswer(), 1e8);
        sink.setPrice(usdcb, 0.99e6, uint64(block.timestamp)); // the 1% band edge is exclusive
        assertEq(stableFeed.latestAnswer(), 0.99e8);
        sink.setPrice(usdcb, 1.02e6, uint64(block.timestamp));
        assertEq(stableFeed.latestAnswer(), 1.02e8);
    }

    // ----------------------------------------------------------------- underlying mode

    /// @notice With an underlying feed, the sink rate is multiplied by the underlying USD price.
    function test_underlying_latestAnswer_isRateTimesUnderlying() public {
        (OracleSinkPriceFeed rateFeed,) = _deployUnderlyingPair();
        // 1.05 (6 dp) x 2000 USD (8 dp) scaled to 8 dp = 2100e8
        assertEq(rateFeed.latestAnswer(), 2100e8);
    }

    /// @notice A stale underlying USD leg fails closed even while the rate leg is fresh.
    function test_underlying_revertsWhenUnderlyingStale() public {
        address eth = makeAddr("eth");
        address weeth = makeAddr("weeth");
        sink.setPrice(eth, 2000e6, uint64(block.timestamp - 1 hours)); // will age out first
        sink.setPrice(weeth, 1.05e6, uint64(block.timestamp));
        OracleSinkPriceFeed usdFeed = new OracleSinkPriceFeed(IOracleSink(address(sink)), eth, IAaveV4PriceFeed(address(0)), FEED_DECIMALS, RATE_MAX_STALENESS, false, "ETH / USD");
        OracleSinkPriceFeed rateFeed = new OracleSinkPriceFeed(IOracleSink(address(sink)), weeth, usdFeed, FEED_DECIMALS, RATE_MAX_STALENESS, false, "weETH / USD");

        vm.warp(block.timestamp + 1);
        vm.expectRevert(BaseAaveV4PriceFeed.StalePrice.selector);
        rateFeed.latestAnswer();
    }

    function _deployUnderlyingPair() internal returns (OracleSinkPriceFeed rateFeed, OracleSinkPriceFeed usdFeed) {
        address eth = makeAddr("eth");
        address weeth = makeAddr("weeth");
        sink.setPrice(eth, 2000e6, uint64(block.timestamp));
        sink.setPrice(weeth, 1.05e6, uint64(block.timestamp));
        usdFeed = new OracleSinkPriceFeed(IOracleSink(address(sink)), eth, IAaveV4PriceFeed(address(0)), FEED_DECIMALS, RATE_MAX_STALENESS, false, "ETH / USD");
        rateFeed = new OracleSinkPriceFeed(IOracleSink(address(sink)), weeth, usdFeed, FEED_DECIMALS, RATE_MAX_STALENESS, false, "weETH / USD");
    }

    // ----------------------------------------------------------------- constructor guards

    /// @notice Reverts at construction when the staleness bound is zero.
    function test_constructor_revertsOnZeroStaleness() public {
        vm.expectRevert(BaseAaveV4PriceFeed.InvalidMaxStaleness.selector);
        new OracleSinkPriceFeed(IOracleSink(address(sink)), wspyx, IAaveV4PriceFeed(address(0)), FEED_DECIMALS, 0, false, "wSPYX / USD");
    }

    /// @notice Reverts at construction on a zero token, which would otherwise deploy a dud feed.
    function test_constructor_revertsOnZeroToken() public {
        vm.expectRevert(OracleSinkPriceFeed.InvalidToken.selector);
        new OracleSinkPriceFeed(IOracleSink(address(sink)), address(0), IAaveV4PriceFeed(address(0)), FEED_DECIMALS, RATE_MAX_STALENESS, false, "wSPYX / USD");
    }
}
