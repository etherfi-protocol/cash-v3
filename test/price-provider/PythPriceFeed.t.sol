// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Test } from "forge-std/Test.sol";

import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { IPythPairOracle, PythPriceFeed } from "../../src/oracle/PythPriceFeed.sol";

contract MockPythPairOracle is IPythPairOracle {
    uint256 public price;

    function setPrice(uint256 price_) external {
        price = price_;
    }
}

contract MockUsdFeed is IAaveV4PriceFeed {
    int256 public answer;
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function set(int256 answer_) external {
        answer = answer_;
    }

    function description() external pure returns (string memory) {
        return "MOCK UNDERLYING / USD";
    }

    function latestAnswer() external view returns (int256) {
        return answer;
    }
}

/// @notice Unit tests on mocks plus a fork test against the live ETHFI/USD pair oracle on OP.
contract PythPriceFeedTest is Test {
    using SafeCast for int256;

    // ETHFI/USD Pyth pair oracle on Optimism (see scripts/gnosis-txs/SetPythOraclesOP.s.sol)
    address constant ETHFI_USD_ORACLE = 0x3E377b4e02bc848Ade3c289477F21441b7e014C2;
    uint8 constant ORACLE_DECIMALS = 16;
    uint8 constant FEED_DECIMALS = 8;

    MockPythPairOracle mockOracle;
    MockUsdFeed mockUnderlying;
    PythPriceFeed feed;
    PythPriceFeed compositeFeed;

    function setUp() public {
        mockOracle = new MockPythPairOracle();
        feed = new PythPriceFeed(mockOracle, ORACLE_DECIMALS, FEED_DECIMALS, IAaveV4PriceFeed(address(0)), "MOCK / USD");

        mockUnderlying = new MockUsdFeed(8);
        compositeFeed = new PythPriceFeed(mockOracle, ORACLE_DECIMALS, FEED_DECIMALS, mockUnderlying, "MOCK / USD via ETH");
    }

    function test_latestAnswer_scalesToFeedDecimals() public {
        mockOracle.setPrice(4.0918676e15); // $0.40918676 at 16 decimals
        assertEq(feed.latestAnswer(), 0.40918676e8);
    }

    function test_latestAnswer_revertsOnZeroPrice() public {
        mockOracle.setPrice(0);
        vm.expectRevert(PythPriceFeed.InvalidPrice.selector);
        feed.latestAnswer();
    }

    function test_constructor_revertsOnUnsupportedDecimals() public {
        vm.expectRevert(PythPriceFeed.UnsupportedDecimals.selector);
        new PythPriceFeed(mockOracle, 6, 8, IAaveV4PriceFeed(address(0)), "BAD / USD");
    }

    function test_decimalsAndDescription() public view {
        assertEq(feed.decimals(), FEED_DECIMALS);
        assertEq(feed.description(), "MOCK / USD");
    }

    // ----------------------------------------------------------------- underlying leg

    function test_underlying_latestAnswer_multipliesPairByUnderlying() public {
        // pair = 0.05 TOKEN/ETH at 16 decimals, ETH/USD = $2,000 at 8 decimals => $100
        mockOracle.setPrice(0.05e16);
        mockUnderlying.set(2000e8);
        assertEq(compositeFeed.latestAnswer(), 100e8);
    }

    function test_underlying_normalizesUnderlyingDecimals() public {
        MockUsdFeed underlying18 = new MockUsdFeed(18);
        PythPriceFeed composite18 = new PythPriceFeed(mockOracle, ORACLE_DECIMALS, FEED_DECIMALS, underlying18, "MOCK / USD via 18-dec");
        mockOracle.setPrice(0.05e16);
        underlying18.set(2000e18);
        assertEq(composite18.latestAnswer(), 100e8);
    }

    function test_underlying_revertsOnNonPositiveUnderlying() public {
        mockOracle.setPrice(0.05e16);
        mockUnderlying.set(0);
        vm.expectRevert(PythPriceFeed.InvalidPrice.selector);
        compositeFeed.latestAnswer();
    }

    // ----------------------------------------------------------------- fork

    /// @notice Live oracle: reported price matches the raw pair oracle and lands in a sane range.
    function test_fork_latestAnswer_matchesLiveOracle() public {
        vm.createSelectFork(vm.envOr("OPTIMISM_RPC", string("https://mainnet.optimism.io")));
        PythPriceFeed liveFeed = new PythPriceFeed(IPythPairOracle(ETHFI_USD_ORACLE), ORACLE_DECIMALS, FEED_DECIMALS, IAaveV4PriceFeed(address(0)), "ETHFI / USD");

        uint256 raw = IPythPairOracle(ETHFI_USD_ORACLE).price();
        uint256 price = liveFeed.latestAnswer().toUint256();

        assertEq(price, raw / 10 ** (ORACLE_DECIMALS - FEED_DECIMALS));
        // ETHFI should be between $0.01 and $100 at 8 decimals — catches a decimals mistake
        assertGt(price, 0.01e8, "price too low");
        assertLt(price, 100e8, "price too high");
    }
}
