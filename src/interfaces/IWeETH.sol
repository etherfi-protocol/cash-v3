// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IWeETH {
    function getEETHByWeETH(
        uint256 _weETHAmount
    ) external view returns (uint256);
}