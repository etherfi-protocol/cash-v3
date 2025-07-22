// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { IEtherFiSafe } from "../interfaces/IEtherFiSafe.sol";
import { ICashModule } from "../interfaces/ICashModule.sol";
import { SignatureUtils } from "../libraries/SignatureUtils.sol";
import { Constants } from "../utils/Constants.sol";

/**
 * @title ModuleCheckBalance
 * @author ether.fi
 * @notice Contract for checking available balance of a user's safe
 */
abstract contract ModuleCheckBalance is Constants {
    using SignatureUtils for bytes32;

    ICashModule public immutable cashModule;

    /// @notice Thrown when insufficient amount is available for use from the safe
    error InsufficientAvailableBalanceOnSafe();

    constructor(address _etherFiDataProvider) {
        cashModule = ICashModule(IEtherFiDataProvider(_etherFiDataProvider).getCashModule());
    }

    /**
     * @notice Returns the available amount for an asset for a safe (balance - pendingWithdrawal)
     * @param safe The Safe address to query
     * @param asset Address of the asset
     * @return Available amount (balance - pendingWithdrawal)
     */
    function _getAvailableAmount(address safe, address asset) internal view returns (uint256) {
        uint256 pendingWithdrawalAmount = cashModule.getPendingWithdrawalAmount(safe, asset);
        uint256 balance;
        if (asset == ETH) balance = safe.balance;
        else balance = IERC20(asset).balanceOf(safe);
        
        if (pendingWithdrawalAmount > balance) return 0;
        
        return balance - pendingWithdrawalAmount;
    }

    /**
     * @notice Checks if amount is available to use from the safe
     * @param safe The Safe address to query
     * @param asset Address of the asset
     * @param amount Amount to check with
     * @custom:throws InsufficientAvailableBalanceOnSafe if amount not available
     */
    function _checkAmountAvailable(address safe, address asset, uint256 amount) internal view {
        if (amount > _getAvailableAmount(safe, asset)) revert InsufficientAvailableBalanceOnSafe();
    }
}
