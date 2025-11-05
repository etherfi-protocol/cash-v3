// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IL2BeHYPEOAppStaker
 * @notice Interface for the L2BeHYPEOAppStaker contract that handles cross-chain WHYPE staking
 */
interface IL2BeHYPEOAppStaker {
    /**
     * @notice Quotes the total fee required to stake WHYPE tokens
     * @param hypeAmountIn The amount of WHYPE tokens to stake
     * @param receiver The user's cash safe address where beHYPE will be asynchronously delivered
     * @return totalFee The total fee required for the cross-chain transaction
     */
    function quoteStake(uint256 hypeAmountIn, address receiver) external view returns (uint256 totalFee);

    /**
     * @notice Stakes WHYPE tokens by sending them cross-chain to be staked on HyperEVM
     * @dev Reverts if the amount contains dust beyond shared decimal precision
     * @param hypeAmountIn The amount of WHYPE tokens to stake
     * @param receiver The user's cash safe address where beHYPE will be asynchronously delivered after staking completes
     */
    function stake(uint256 hypeAmountIn, address receiver) external payable;
}

