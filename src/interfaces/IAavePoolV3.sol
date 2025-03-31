// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAavePoolV3 {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;

    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256);
}
