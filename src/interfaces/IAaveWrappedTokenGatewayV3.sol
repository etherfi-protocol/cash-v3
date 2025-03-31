// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAaveWrappedTokenGateway {
    function depositETH(address, address onBehalfOf, uint16 referralCode) external payable;   

    function withdrawETH(address, uint256 amount, address to) external;

    function repayETH(address, uint256 amount, address onBehalfOf) external payable;

    function borrowETH(address, uint256 amount, uint16 referralCode) external;

    function getWETHAddress() external view returns (address);
}