// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IFraxCustodian {
    function deposit(uint256 amountIn, address receiver) external payable returns (uint256 shares);
    function redeem(uint256 sharesIn, address receiver, address owner) external returns (uint256 amountOut);
}