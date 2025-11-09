// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IDebtManager } from "../../interfaces/IDebtManager.sol";

contract CashLiquidationHelper {
    IDebtManager public immutable debtManager;
    address public immutable usdc;
    address public immutable usdt;
    address public immutable liquidUsd;
    address public immutable eUsd;

    error InvalidInput();

    constructor (address _debtManager, address _usdc, address _usdt, address _liquidUsd, address _eUsd) {
        debtManager = IDebtManager(_debtManager);
        usdc = _usdc;
        usdt = _usdt;
        liquidUsd = _liquidUsd;
        eUsd = _eUsd;
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
            if (totalCollaterals[i].token == usdc || totalCollaterals[i].token == usdt || totalCollaterals[i].token == liquidUsd || totalCollaterals[i].token == eUsd) {
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