// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAaveV4PriceFeed } from "../interfaces/IAaveV4PriceFeed.sol";

/**
 * @title ConstantPriceFeed
 * @notice An Aave v4 price feed that always reports one fixed positive answer. Used to hold a reserve at
 *         a placeholder price: a new reserve listed before its collateral is live, or a retired reserve
 *         whose collateral should count for nothing. The oracle rejects a zero price, so the smallest
 *         usable placeholder is 1 wei.
 * @author ether.fi
 */
contract ConstantPriceFeed is IAaveV4PriceFeed {
    int256 private immutable answer;
    uint8 private immutable feedDecimals;
    string private feedDescription;

    /// @notice Thrown when the fixed answer is not positive
    error InvalidAnswer();

    constructor(int256 _answer, uint8 _feedDecimals, string memory _feedDescription) {
        require(_answer > 0, InvalidAnswer());
        answer = _answer;
        feedDecimals = _feedDecimals;
        feedDescription = _feedDescription;
    }

    /// @notice The number of decimals used to represent the price
    function decimals() external view returns (uint8) {
        return feedDecimals;
    }

    /// @notice A human-readable description of the feed
    function description() external view returns (string memory) {
        return feedDescription;
    }

    /// @notice The fixed answer
    function latestAnswer() external view returns (int256) {
        return answer;
    }
}
