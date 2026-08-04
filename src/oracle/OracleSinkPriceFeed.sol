// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IAaveV4PriceFeed } from "../interfaces/IAaveV4PriceFeed.sol";
import { IOracleSink } from "../interfaces/IOracleSink.sol";
import { BaseAaveV4PriceFeed } from "./BaseAaveV4PriceFeed.sol";

/**
 * @title OracleSinkPriceFeed
 * @notice Prices a token for the Aave v4 oracle from the OracleSink, the destination-chain store of
 *         prices relayed from the mainnet PriceProvider over LayerZero.
 *         One instance per token, two modes like ChainlinkPriceFeed / PythPriceFeed:
 *         - No underlying feed (address(0)): the relayed price is USD-quoted (the case today) and is
 *           only scaled to feed decimals.
 *         - With an underlying feed: the relayed value is a rate in an underlying asset and the price
 *           is rate x underlying USD, where the underlying is any IAaveV4PriceFeed which enforces its
 *           own staleness.
 * @dev The sink's token-keyed `latestRoundData` applies no staleness bound of its own (that is the
 *      consumer's job, per its NatSpec); this feed enforces an immutable `rateMaxStaleness` against
 *      the reported `updatedAt` — the source-chain read time the relay stamped — so a delayed
 *      LayerZero delivery cannot present a stale price as fresh. The relayed answer may already be up
 *      to the mainnet-side source staleness bound old at that read time, so the two windows compound;
 *      size `rateMaxStaleness` to the total age budget minus the source bound. Fails closed:
 *      latestAnswer reverts when the relayed price is stale or non-positive, and the sink itself
 *      reverts for a token it has never priced.
 * @author ether.fi
 */
contract OracleSinkPriceFeed is BaseAaveV4PriceFeed {
    using SafeCast for int256;

    /// @notice The OracleSink storing relayed prices for many tokens
    IOracleSink public immutable sink;
    /// @notice The token this feed prices, baked in because the sink is token-keyed
    address public immutable token;
    /// @notice The maximum age in seconds of the relay's source-chain read before the price is rejected
    uint256 public immutable rateMaxStaleness;

    /// @notice Thrown when the priced token is the zero address
    error InvalidToken();

    constructor(IOracleSink _sink, address _token, IAaveV4PriceFeed _underlyingUsdFeed, uint8 _feedDecimals, uint256 _rateMaxStaleness, bool _isStableToken, string memory feedDescription) BaseAaveV4PriceFeed(_underlyingUsdFeed, _feedDecimals, _sink.decimals(), _isStableToken, feedDescription) {
        require(_rateMaxStaleness > 0, InvalidMaxStaleness());
        require(_token != address(0), InvalidToken());
        sink = _sink;
        token = _token;
        rateMaxStaleness = _rateMaxStaleness;
    }

    /**
     * @notice The token's price: the relayed sink price, times the underlying USD price when configured
     * @dev Reverts if the relayed price's source read time is older than `rateMaxStaleness`, or either
     *      leg is non-positive or reverts. The underlying leg enforces its own staleness.
     */
    function latestAnswer() external view returns (int256) {
        (, int256 answer,, uint256 updatedAt,) = sink.latestRoundData(token);
        if (answer <= 0) revert InvalidPrice();
        if (block.timestamp > updatedAt + rateMaxStaleness) revert StalePrice();
        return _composeUsd(answer.toUint256());
    }
}
