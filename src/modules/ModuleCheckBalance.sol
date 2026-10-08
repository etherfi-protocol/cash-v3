// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { ICashModule, WithdrawalRequest } from "../interfaces/ICashModule.sol";
import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { IEtherFiSafe } from "../interfaces/IEtherFiSafe.sol";
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
    /// @notice Thrown when the safe's balance no longer covers its pending withdrawal
    error PendingWithdrawalUnderBacked();

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

    /**
     * @notice Checks that the safe still holds every amount reserved by its pending withdrawal
     * @dev Run after handing control to an external integration: a callback during that call can place a
     *      hold against tokens the integration then pulls, which the hold's own request-time check cannot see
     * @param safe The Safe address to check
     * @custom:throws PendingWithdrawalUnderBacked if any reserved amount exceeds the safe's balance
     */
    function _checkPendingWithdrawalBacked(address safe) internal view {
        if (address(cashModule) == address(0)) return;
        WithdrawalRequest memory request = cashModule.getData(safe).pendingWithdrawalRequest;
        uint256 len = request.tokens.length;
        for (uint256 i = 0; i < len;) {
            address token = request.tokens[i];
            uint256 balance = token == ETH ? safe.balance : IERC20(token).balanceOf(safe);
            if (balance < request.amounts[i]) revert PendingWithdrawalUnderBacked();
            unchecked {
                ++i;
            }
        }
    }
}
