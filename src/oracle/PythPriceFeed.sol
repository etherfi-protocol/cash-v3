// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IAaveV4PriceFeed } from "../interfaces/IAaveV4PriceFeed.sol";

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
contract PythPriceFeed is IAaveV4PriceFeed {
    using Math for uint256;
    using SafeCast for uint256;

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
    /// @notice The decimals of the price this feed reports
    uint8 public immutable feedDecimals;
    /// @notice USD feed for the pair's underlying; address(0) when the pair is USD-quoted
    IAaveV4PriceFeed public immutable underlyingUsdFeed;
    /// @notice The decimals of the underlying feed (0 when unset)
    uint8 public immutable underlyingDecimals;
    /// @notice Whether the price snaps to exactly 1 USD when within 1% of it (USD stables only)
    bool public immutable isStableToken;

    string private _description;

    /// @notice Thrown when the oracle or the underlying reports a zero or negative price
    error InvalidPrice();
    /// @notice Thrown when a Pyth feed's publish time is older than maxStaleness
    error StalePrice();
    /// @notice Thrown when a USD-quoted oracle's decimals are lower than the feed decimals
    error UnsupportedDecimals();
    /// @notice Thrown when the staleness bound is zero
    error InvalidMaxStaleness();

    constructor(
        IPythPairOracle _oracle,
        uint8 _oracleDecimals,
        uint8 _feedDecimals,
        IAaveV4PriceFeed _underlyingUsdFeed,
        uint256 _maxStaleness,
        bool _isStableToken,
        string memory feedDescription
    ) {
        if (address(_underlyingUsdFeed) == address(0)) {
            // USD-quoted pair: scaling is a plain division, so the oracle must be at least as precise
            require(_oracleDecimals >= _feedDecimals, UnsupportedDecimals());
        } else {
            underlyingDecimals = _underlyingUsdFeed.decimals();
        }
        require(_maxStaleness > 0, InvalidMaxStaleness());

        oracle = _oracle;
        pyth = IPyth(_oracle.pyth());
        feedId1 = _oracle.BASE_FEED_1();
        feedId2 = _oracle.BASE_FEED_2();
        feedId3 = _oracle.QUOTE_FEED_1();
        feedId4 = _oracle.QUOTE_FEED_2();
        maxStaleness = _maxStaleness;
        oracleDecimals = _oracleDecimals;
        feedDecimals = _feedDecimals;
        underlyingUsdFeed = _underlyingUsdFeed;
        isStableToken = _isStableToken;
        _description = feedDescription;
    }

    /// @notice The number of decimals used to represent the price
    function decimals() external view returns (uint8) {
        return feedDecimals;
    }

    /// @notice A human-readable description of the feed
    function description() external view returns (string memory) {
        return _description;
    }

    /// @notice The latest USD price: the pair price, times the underlying USD price when configured
    function latestAnswer() external view returns (int256) {
        _requireFresh(feedId1);
        _requireFresh(feedId2);
        _requireFresh(feedId3);
        _requireFresh(feedId4);

        uint256 price = oracle.price();
        require(price > 0, InvalidPrice());

        if (address(underlyingUsdFeed) == address(0)) {
            return _snapStable(price / 10 ** (oracleDecimals - feedDecimals)).toInt256();
        }

        int256 underlyingPrice = underlyingUsdFeed.latestAnswer();
        require(underlyingPrice > 0, InvalidPrice());

        // price = pair rate * underlying USD, normalized from (oracleDecimals + underlyingDecimals) to feedDecimals
        return _snapStable(price.mulDiv(uint256(underlyingPrice) * 10 ** feedDecimals, 10 ** (oracleDecimals + underlyingDecimals))).toInt256();
    }

    /// @dev Snaps a USD-stable price to exactly 1 USD when it is within 1% of it, mirroring PriceProviderV2
    function _snapStable(uint256 price) private view returns (uint256) {
        if (!isStableToken) return price;
        uint256 stablePrice = 10 ** feedDecimals;
        uint256 maxDeviation = stablePrice / 100;
        if (price > stablePrice - maxDeviation && price < stablePrice + maxDeviation) return stablePrice;
        return price;
    }

    /// @dev Enforces the feed's own staleness bound against the Pyth publish time; zero ids are unused slots
    function _requireFresh(bytes32 feedId) private view {
        if (feedId == bytes32(0)) return;
        uint256 publishTime = pyth.getPriceUnsafe(feedId).publishTime;
        require(block.timestamp <= publishTime + maxStaleness, StalePrice());
    }
}
