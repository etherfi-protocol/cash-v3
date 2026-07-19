// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Test } from "forge-std/Test.sol";

import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { L2SequencerGuardLib } from "../../src/libraries/L2SequencerGuardLib.sol";
import { IPyth, IPythPairOracle, PythPriceFeed } from "../../src/oracle/PythPriceFeed.sol";

contract MockPyth {
    mapping(bytes32 => IPyth.Price) private prices;

    function setPublishTime(bytes32 id, uint256 publishTime) external {
        prices[id].publishTime = publishTime;
    }

    function getPriceUnsafe(bytes32 id) external view returns (IPyth.Price memory) {
        return prices[id];
    }
}

contract MockPythPairOracle is IPythPairOracle {
    uint256 public price;
    address public pyth;
    bytes32 public BASE_FEED_1;
    bytes32 public BASE_FEED_2;
    bytes32 public QUOTE_FEED_1;
    bytes32 public QUOTE_FEED_2;

    constructor(address pyth_, bytes32 baseFeed1) {
        pyth = pyth_;
        BASE_FEED_1 = baseFeed1;
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }
}

/// @notice Unit tests on mocks plus a fork test against the live ETHFI/USD pair adapter on OP.
contract PythPriceFeedTest is Test {
    using SafeCast for int256;

    // ETHFI/USD MorphoPythOracle adapter on Optimism (see scripts/gnosis-txs/SetPythOraclesOP.s.sol)
    address constant ETHFI_USD_ORACLE = 0x3E377b4e02bc848Ade3c289477F21441b7e014C2;
    bytes32 constant FEED_ID = keccak256("mock-feed-id");
    uint8 constant ORACLE_DECIMALS = 16;
    uint8 constant FEED_DECIMALS = 8;
    uint256 constant MAX_STALENESS = 1 hours;

    MockPyth mockPyth;
    MockPythPairOracle mockOracle;
    MockUsdFeed mockUnderlying;
    PythPriceFeed feed;
    PythPriceFeed compositeFeed;

    function setUp() public {
        vm.warp(1_800_000_000);
        mockPyth = new MockPyth();
        mockOracle = new MockPythPairOracle(address(mockPyth), FEED_ID);
        mockPyth.setPublishTime(FEED_ID, block.timestamp);
        feed = new PythPriceFeed(mockOracle, ORACLE_DECIMALS, FEED_DECIMALS, IAaveV4PriceFeed(address(0)), MAX_STALENESS, false, "MOCK / USD", IAggregatorV3(address(0)), 0);

        mockUnderlying = new MockUsdFeed(8);
        compositeFeed = new PythPriceFeed(mockOracle, ORACLE_DECIMALS, FEED_DECIMALS, mockUnderlying, MAX_STALENESS, false, "MOCK / USD via ETH", IAggregatorV3(address(0)), 0);
    }

    function test_latestAnswer_scalesToFeedDecimals() public {
        mockOracle.setPrice(4.0918676e15); // $0.40918676 at 16 decimals
        assertEq(feed.latestAnswer(), 0.40918676e8);
    }

    /// @notice A Pyth-backed Aave feed rejects prices while the L2 sequencer is down.
    function test_latestAnswer_revertsWhenSequencerIsDown() public {
        address sequencer = makeAddr("sequencer");
        vm.mockCall(sequencer, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), abi.encode(uint80(1), int256(1), block.timestamp - 2 hours, block.timestamp, uint80(1)));
        PythPriceFeed guardedFeed = new PythPriceFeed(mockOracle, ORACLE_DECIMALS, FEED_DECIMALS, IAaveV4PriceFeed(address(0)), MAX_STALENESS, false, "MOCK / USD", IAggregatorV3(sequencer), 1 hours);

        vm.expectRevert(L2SequencerGuardLib.SequencerDown.selector);
        guardedFeed.latestAnswer();
    }

    function test_latestAnswer_revertsOnZeroPrice() public {
        mockOracle.setPrice(0);
        vm.expectRevert(PythPriceFeed.InvalidPrice.selector);
        feed.latestAnswer();
    }

    function test_latestAnswer_revertsOnStalePublishTime() public {
        mockOracle.setPrice(4.0918676e15);
        vm.warp(block.timestamp + MAX_STALENESS + 1);
        vm.expectRevert(PythPriceFeed.StalePrice.selector);
        feed.latestAnswer();
    }

    /// @notice A stable feed snaps to exactly 1 USD inside the 1% band and passes the raw price outside it.
    function test_stable_snapsWithinOnePercent() public {
        PythPriceFeed stableFeed = new PythPriceFeed(mockOracle, ORACLE_DECIMALS, FEED_DECIMALS, IAaveV4PriceFeed(address(0)), MAX_STALENESS, true, "STABLE / USD", IAggregatorV3(address(0)), 0);
        mockOracle.setPrice(0.995e16);
        assertEq(stableFeed.latestAnswer(), 1e8);
        mockOracle.setPrice(1.02e16);
        assertEq(stableFeed.latestAnswer(), 1.02e8);
    }

    function test_constructor_readsPythWiringFromAdapter() public view {
        assertEq(address(feed.pyth()), address(mockPyth));
        assertEq(feed.feedId1(), FEED_ID);
        assertEq(feed.feedId2(), bytes32(0));
        assertEq(feed.maxStaleness(), MAX_STALENESS);
    }

    function test_constructor_revertsOnUnsupportedDecimals() public {
        vm.expectRevert(PythPriceFeed.UnsupportedDecimals.selector);
        new PythPriceFeed(mockOracle, 6, 8, IAaveV4PriceFeed(address(0)), MAX_STALENESS, false, "BAD / USD", IAggregatorV3(address(0)), 0);
    }

    function test_constructor_revertsOnZeroStaleness() public {
        vm.expectRevert(PythPriceFeed.InvalidMaxStaleness.selector);
        new PythPriceFeed(mockOracle, ORACLE_DECIMALS, FEED_DECIMALS, IAaveV4PriceFeed(address(0)), 0, false, "BAD / USD", IAggregatorV3(address(0)), 0);
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
        PythPriceFeed composite18 = new PythPriceFeed(mockOracle, ORACLE_DECIMALS, FEED_DECIMALS, underlying18, MAX_STALENESS, false, "MOCK / USD via 18-dec", IAggregatorV3(address(0)), 0);
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

    /// @notice Live adapter: wiring is discovered on-chain, price matches, staleness bound holds.
    function test_fork_latestAnswer_matchesLiveOracle() public {
        vm.createSelectFork(vm.envOr("OPTIMISM_RPC", string("https://mainnet.optimism.io")));
        PythPriceFeed liveFeed = new PythPriceFeed(IPythPairOracle(ETHFI_USD_ORACLE), ORACLE_DECIMALS, FEED_DECIMALS, IAaveV4PriceFeed(address(0)), 1 days, false, "ETHFI / USD", IAggregatorV3(address(0)), 0);

        assertEq(address(liveFeed.pyth()), IPythPairOracle(ETHFI_USD_ORACLE).pyth());
        assertEq(liveFeed.feedId1(), IPythPairOracle(ETHFI_USD_ORACLE).BASE_FEED_1());

        uint256 raw = IPythPairOracle(ETHFI_USD_ORACLE).price();
        uint256 price = liveFeed.latestAnswer().toUint256();

        assertEq(price, raw / 10 ** (ORACLE_DECIMALS - FEED_DECIMALS));
        // ETHFI should be between $0.01 and $100 at 8 decimals — catches a decimals mistake
        assertGt(price, 0.01e8, "price too low");
        assertLt(price, 100e8, "price too high");
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
