// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IAaveV4PriceFeed } from "../interfaces/IAaveV4PriceFeed.sol";

/// @notice The slice of the ether.fi Pyth per-pair oracle the feed reads: a bare fixed-decimals
///         price.
interface IPythPairOracle {
    function price() external view returns (uint256);
}

/**
 * @title PythPriceFeed
 * @dev Implements the Aave v4 price-feed interface and fails closed on a zero or reverting price.
 *      The pair oracles expose only `price()` — staleness is already enforced at
 *      the pyth adapter layer; the optional underlying leg enforces its own staleness.
 * @author ether.fi
 */
contract PythPriceFeed is IAaveV4PriceFeed {
    using Math for uint256;
    using SafeCast for uint256;

    /// @notice The Pyth per-pair oracle supplying the price
    IPythPairOracle public immutable oracle;
    /// @notice The decimals of the oracle's price
    uint8 public immutable oracleDecimals;
    /// @notice The decimals of the price this feed reports
    uint8 public immutable feedDecimals;
    /// @notice USD feed for the pair's underlying; address(0) when the pair is USD-quoted
    IAaveV4PriceFeed public immutable underlyingUsdFeed;
    /// @notice The decimals of the underlying feed (0 when unset)
    uint8 public immutable underlyingDecimals;

    string private _description;

    /// @notice Thrown when the oracle or the underlying reports a zero or negative price
    error InvalidPrice();
    /// @notice Thrown when a USD-quoted oracle's decimals are lower than the feed decimals
    error UnsupportedDecimals();

    constructor(
        IPythPairOracle _oracle,
        uint8 _oracleDecimals,
        uint8 _feedDecimals,
        IAaveV4PriceFeed _underlyingUsdFeed,
        string memory feedDescription
    ) {
        if (address(_underlyingUsdFeed) == address(0)) {
            // USD-quoted pair: scaling is a plain division, so the oracle must be at least as precise
            require(_oracleDecimals >= _feedDecimals, UnsupportedDecimals());
        } else {
            underlyingDecimals = _underlyingUsdFeed.decimals();
        }
        oracle = _oracle;
        oracleDecimals = _oracleDecimals;
        feedDecimals = _feedDecimals;
        underlyingUsdFeed = _underlyingUsdFeed;
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
        uint256 price = oracle.price();
        require(price > 0, InvalidPrice());

        if (address(underlyingUsdFeed) == address(0)) {
            return (price / 10 ** (oracleDecimals - feedDecimals)).toInt256();
        }

        int256 underlyingPrice = underlyingUsdFeed.latestAnswer();
        require(underlyingPrice > 0, InvalidPrice());

        return price.mulDiv(uint256(underlyingPrice) * 10 ** feedDecimals, 10 ** (oracleDecimals + underlyingDecimals)).toInt256();
    }
}
