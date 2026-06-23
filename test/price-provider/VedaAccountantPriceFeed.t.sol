// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Test } from "forge-std/Test.sol";

import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { IVedaAccountant } from "../../src/interfaces/IVedaAccountant.sol";
import { VedaAccountantPriceFeed } from "../../src/oracle/VedaAccountantPriceFeed.sol";

/// @notice Fork tests on Optimism, using the live liquidETH accountant and ETH/USD feed.
contract VedaAccountantPriceFeedTest is Test {
    using SafeCast for int256;

    // optimism
    IVedaAccountant accountant = IVedaAccountant(0x0d05D94a5F1E76C18fbeB7A13d17C8a314088198); // liquidETH
    address ethUsdOracle = 0x13e3Ee699D1909E989722E753853AE30b17e08c5; // ETH/USD

    uint8 constant FEED_DECIMALS = 8;
    uint256 constant UNDERLYING_MAX_STALENESS = 1 days;

    VedaAccountantPriceFeed feed;

    function setUp() public {
        vm.createSelectFork(vm.envOr("OPTIMISM_RPC", string("https://mainnet.optimism.io")));
        feed = new VedaAccountantPriceFeed(accountant, IAggregatorV3(ethUsdOracle), FEED_DECIMALS, UNDERLYING_MAX_STALENESS, "liquidETH / USD");
    }

    /// @notice The reported price equals rate x underlying, and lands in a sane USD range.
    function test_latestAnswer_matchesRateTimesUnderlying() public view {
        uint256 rate = accountant.getRateSafe();
        (, int256 ethUsd,,,) = IAggregatorV3(ethUsdOracle).latestRoundData();

        uint256 expected = rate * ethUsd.toUint256() * (10 ** FEED_DECIMALS) / (10 ** (feed.rateDecimals() + feed.underlyingDecimals()));

        uint256 price = feed.latestAnswer().toUint256();
        assertEq(price, expected, "price mismatch");

        // Sanity on magnitude, which catches a decimals mistake: liquidETH should be a few thousand
        // USD, so well within 100 to 100,000 USD at 8 decimals.
        assertGt(price, 100 * (10 ** FEED_DECIMALS), "price too low");
        assertLt(price, 100_000 * (10 ** FEED_DECIMALS), "price too high");
    }

    function test_decimalsAndDescription() public view {
        assertEq(feed.decimals(), FEED_DECIMALS);
        assertEq(feed.description(), "liquidETH / USD");
    }

    /// @notice Reverts when the underlying Chainlink price is older than the staleness limit.
    function test_reverts_whenUnderlyingStale() public {
        vm.warp(block.timestamp + UNDERLYING_MAX_STALENESS + 1);
        vm.expectRevert(VedaAccountantPriceFeed.StalePrice.selector);
        feed.latestAnswer();
    }

    /// @notice Reverts when the accountant has paused itself (getRateSafe reverts).
    function test_reverts_whenAccountantPaused() public {
        vm.mockCallRevert(address(accountant), abi.encodeWithSelector(IVedaAccountant.getRateSafe.selector), "paused");
        vm.expectRevert();
        feed.latestAnswer();
    }

    /// @notice Reverts when the rate is zero.
    function test_reverts_whenRateZero() public {
        vm.mockCall(address(accountant), abi.encodeWithSelector(IVedaAccountant.getRateSafe.selector), abi.encode(uint256(0)));
        vm.expectRevert(VedaAccountantPriceFeed.InvalidPrice.selector);
        feed.latestAnswer();
    }

    /// @notice Reverts when the underlying price is zero or negative.
    function test_reverts_whenUnderlyingNotPositive() public {
        vm.mockCall(ethUsdOracle, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), abi.encode(uint80(1), int256(0), block.timestamp, block.timestamp, uint80(1)));
        vm.expectRevert(VedaAccountantPriceFeed.InvalidPrice.selector);
        feed.latestAnswer();
    }
}
