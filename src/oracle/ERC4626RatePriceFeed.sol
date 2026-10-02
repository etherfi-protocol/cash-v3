// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IAaveV4PriceFeed } from "../interfaces/IAaveV4PriceFeed.sol";
import { BaseAaveV4PriceFeed } from "./BaseAaveV4PriceFeed.sol";

/**
 * @title ERC4626RatePriceFeed
 * @notice Prices an ERC-4626 vault share for the Aave v4 oracle as the vault's own redemption rate, read
 *         on this chain, times the underlying asset's USD price. One instance per vault. Used for the
 *         Backed xStock wrappers on Optimism, where the wrapper and its underlying both live locally so
 *         no relayed rate is needed.
 * @dev The rate is `convertToAssets(one share)` at read time, so it carries no timestamp and no staleness
 *      bound of its own; freshness comes from the required underlying USD feed, an IAaveV4PriceFeed that
 *      enforces its own. Fails closed when that leg reverts or is non-positive.
 * @author ether.fi
 */
contract ERC4626RatePriceFeed is BaseAaveV4PriceFeed {
    /// @notice The vault whose share this feed prices
    IERC4626 public immutable vault;
    /// @dev 10 ** vault.decimals(): one whole share
    uint256 private immutable oneShare;

    /// @notice Thrown when no underlying USD feed is given; a vault rate is never USD-quoted on its own
    error MissingUnderlyingFeed();

    constructor(IERC4626 _vault, IAaveV4PriceFeed _underlyingUsdFeed, uint8 _feedDecimals, string memory feedDescription) BaseAaveV4PriceFeed(_underlyingUsdFeed, _feedDecimals, IERC20Metadata(_vault.asset()).decimals(), false, feedDescription) {
        require(address(_underlyingUsdFeed) != address(0), MissingUnderlyingFeed());
        vault = _vault;
        oneShare = 10 ** _vault.decimals();
    }

    /// @notice One share's redemption value in the underlying, times the underlying's USD price
    function latestAnswer() external view returns (int256) {
        return _composeUsd(vault.convertToAssets(oneShare));
    }
}
