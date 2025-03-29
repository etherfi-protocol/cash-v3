// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IL2SyncPool {
    function deposit(address tokenIn, uint256 amountIn, uint256 minAmountOut) external payable returns (uint256 amountOut);
}
