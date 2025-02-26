// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAavePoolV3 {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}
