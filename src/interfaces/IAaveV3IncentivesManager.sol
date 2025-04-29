// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAaveV3IncentivesManager {
    function claimRewardsToSelf(address[] calldata assets, uint256 amount, address reward) external returns (uint256);

    function claimAllRewardsToSelf(address[] calldata assets) external returns (address[] memory rewardsList, uint256[] memory claimedAmounts);
}