// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAaveV4PriceFeed } from "../interfaces/IAaveV4PriceFeed.sol";
import { BaseAaveV4PriceFeed } from "./BaseAaveV4PriceFeed.sol";

/// @notice The slice of the MorphoPythOracle adapters (deployed per pair on OP) the feed reads: the
///         fixed-decimals price, plus the Pyth contract and feed ids baked into the adapter, so the
///         feed can enforce its own staleness directly against Pyth.
interface IPythPairOracle {
    function price() external view returns (uint256);
    function pyth() external view returns (address);
    function BASE_FEED_1() external view returns (bytes32);
    function BASE_FEED_2() external view returns (bytes32);
    function QUOTE_FEED_1() external view returns (bytes32);
    function QUOTE_FEED_2() external view returns (bytes32);
}

/// @notice The slice of the Pyth core contract the feed reads. `getPriceUnsafe` returns the latest
///         stored price without any age check — the feed applies its own.
interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    function getPriceUnsafe(bytes32 id) external view returns (Price memory);
}

/**
 * @title PythPriceFeed
 * @notice Prices a token for the Aave v4 oracle from one of the MorphoPythOracle pair adapters on OP.
 *         One instance per token, two modes like ChainlinkPriceFeed / VedaAccountantPriceFeed:
 *         - No underlying feed (address(0)): the pair is USD-quoted (e.g. ETHFI/USD) and the price is
 *           only scaled to feed decimals.
 *         - With an underlying feed: the pair is quoted in an underlying asset and the price is
 *           pair rate x underlying USD, where the underlying is any IAaveV4PriceFeed which enforces
 *           its own staleness.
 * @dev The adapter checks its own baked-in PRICE_FEED_MAX_AGE inside price(), but that bound is not
 *      ours to control. The feed therefore also reads each Pyth feed id the adapter uses (discovered
 *      from the adapter at construction) and enforces `maxStaleness` against the Pyth publish time
 *      directly — set it tighter than the adapter's max age to make the effective bound ours.
 *      Fails closed: latestAnswer reverts on a stale Pyth publish time, or a zero/reverting price.
 * @author ether.fi
 */
contract PythPriceFeed is BaseAaveV4PriceFeed {
    /// @notice The MorphoPythOracle pair adapter supplying the price
    IPythPairOracle public immutable oracle;
    /// @notice The Pyth core contract, discovered from the adapter
    IPyth public immutable pyth;
    /// @notice The Pyth feed ids the adapter prices with (zero = unused slot), discovered from the adapter
    bytes32 public immutable feedId1;
    bytes32 public immutable feedId2;
    bytes32 public immutable feedId3;
    bytes32 public immutable feedId4;
    /// @notice The maximum age in seconds for every Pyth publish time before the price is rejected
    uint256 public immutable maxStaleness;
    /// @notice The decimals of the oracle's price
    uint8 public immutable oracleDecimals;

    /// @notice Thrown when a USD-quoted oracle's decimals are lower than the feed decimals
    error UnsupportedDecimals();

    constructor(IPythPairOracle _oracle, uint8 _oracleDecimals, uint8 _feedDecimals, IAaveV4PriceFeed _underlyingUsdFeed, uint256 _maxStaleness, bool _isStableToken, string memory feedDescription) BaseAaveV4PriceFeed(_underlyingUsdFeed, _feedDecimals, _isStableToken, feedDescription) {
        // USD-quoted pair: the oracle must be at least as precise as the reported feed decimals
        if (address(_underlyingUsdFeed) == address(0)) require(_oracleDecimals >= _feedDecimals, UnsupportedDecimals());
        require(_maxStaleness > 0, InvalidMaxStaleness());

        oracle = _oracle;
        pyth = IPyth(_oracle.pyth());
        feedId1 = _oracle.BASE_FEED_1();
        feedId2 = _oracle.BASE_FEED_2();
        feedId3 = _oracle.QUOTE_FEED_1();
        feedId4 = _oracle.QUOTE_FEED_2();
        maxStaleness = _maxStaleness;
        oracleDecimals = _oracleDecimals;
    }

    /// @notice The latest USD price: the pair price, times the underlying USD price when configured
    function latestAnswer() external view returns (int256) {
        _requireFresh(feedId1);
        _requireFresh(feedId2);
        _requireFresh(feedId3);
        _requireFresh(feedId4);

        uint256 price = oracle.price();
        require(price > 0, InvalidPrice());

        return _composeUsd(price, oracleDecimals);
    }

    /// @dev Enforces the feed's own staleness bound against the Pyth publish time; zero ids are unused slots
    function _requireFresh(bytes32 feedId) private view {
        if (feedId == bytes32(0)) return;
        uint256 publishTime = pyth.getPriceUnsafe(feedId).publishTime;
        require(block.timestamp <= publishTime + maxStaleness, StalePrice());
    }
}
