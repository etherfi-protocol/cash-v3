// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IDebtManager } from "../../interfaces/IDebtManager.sol";

contract CashLiquidationHelper {
    IDebtManager public immutable debtManager;
    address public immutable usdc;

    error InvalidInput();

    constructor (address _debtManager, address _usdc) {
        debtManager = IDebtManager(_debtManager);
        usdc = _usdc;
    }

    struct CashLiquidationData {
        address user;                   
        bool isLiquidatable;
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
        data.isLiquidatable = debtManager.liquidatable(user);
        data.maxBorrowAmount = debtManager.getMaxBorrowAmount(user, true);
        data.totalBorrowing = debtManager.borrowingOf(user, usdc);
        data.liquidationBorrowAmount = debtManager.getMaxBorrowAmount(user, false);

        if (data.liquidationBorrowAmount > data.totalBorrowing) data.remainingAmtToLiquidation = data.liquidationBorrowAmount - data.totalBorrowing;
    }
}