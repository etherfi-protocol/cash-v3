// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";
import { IDebtManager } from "../../interfaces/IDebtManager.sol";

contract CashLiquidationHelper {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    IDebtManager public immutable debtManager;
    EnumerableSetLib.AddressSet private stableAssets;

    error InvalidInput();

    constructor (address _debtManager,  address _eUsd) {
        debtManager = IDebtManager(_debtManager);
        stableAssets.add(_eUsd);
        address[] memory borrowTokens = debtManager.getBorrowTokens();
        for (uint256 i = 0; i < borrowTokens.length; i++) {
            stableAssets.add(borrowTokens[i]);
        }
    }

    struct CashLiquidationData {
        address user;                   
        bool isLiquidatable;
        bool isMostlyStables;
        uint256 maxBorrowAmount;           
        uint256 totalBorrowing;            
        uint256 liquidationBorrowAmount;   
        uint256 remainingAmtToLiquidation; 
    } 

    function getStableAssets() external view returns (address[] memory) {                                                                                                       
      return stableAssets.values();                                 
    }

    function updateStableAssets () external {
        address[] memory stableAssetsFromDebtManager = debtManager.getBorrowTokens();
        for (uint256 i = 0; i < stableAssetsFromDebtManager.length; i++) {
            stableAssets.add(stableAssetsFromDebtManager[i]);
        }
    }

    function getUserData(address user) external view returns (CashLiquidationData memory) {
        return _getUserData(user);
    }

    function getUserDataBatch(address[] calldata users) external view returns (CashLiquidationData[] memory) {
        uint256 len = users.length;
        if (len == 0) revert InvalidInput();

        CashLiquidationData[] memory data = new CashLiquidationData[](len);

        for (uint256 i = 0; i < len; ) {
            data[i] = _getUserData(users[i]);
            unchecked {
                ++i;
            }
        }

        return data;
    }

    function _getUserData(address user) internal view returns (CashLiquidationData memory data) {
        data.user = user;
        
        (IDebtManager.TokenData[] memory totalCollaterals, uint256 totalCollateralInUsd, , uint256 totalBorrowing) = debtManager.getUserCurrentState(user);
        
        uint256 stableCount = 0;
        for (uint256 i = 0; i < totalCollaterals.length; i++) {
            if (stableAssets.contains(totalCollaterals[i].token)) {
                stableCount += debtManager.convertCollateralTokenToUsd(totalCollaterals[i].token, totalCollaterals[i].amount);
            }
        }

        data.isMostlyStables = stableCount > (3 * totalCollateralInUsd) / 4;

        data.isLiquidatable = debtManager.liquidatable(user);
        data.maxBorrowAmount = debtManager.getMaxBorrowAmount(user, true);
        data.totalBorrowing = totalBorrowing;
        data.liquidationBorrowAmount = debtManager.getMaxBorrowAmount(user, false);

        if (data.liquidationBorrowAmount > data.totalBorrowing) data.remainingAmtToLiquidation = data.liquidationBorrowAmount - data.totalBorrowing;
    }                                                                                                                                                                 
}