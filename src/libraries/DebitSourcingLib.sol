// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ILendGateway } from "../interfaces/ILendGateway.sol";
import { IPriceProvider } from "../interfaces/IPriceProvider.sol";

/**
 * @title DebitSourcingLib
 * @notice Shared debit-sizing math for the Cash contracts: how much of a token's Aave-supplied balance can
 *         fund a debit within the gateway's Aave-priced collateral headroom. CashModuleCore (execution) and
 *         CashLens (canSpend) both call it so the two agree; PriceProvider's only role here is converting
 *         payment USD to and from token amounts.
 * @author ether.fi
 */
library DebitSourcingLib {
    /**
     * @notice Amount of `token` withdrawable from `safe`'s Aave-supplied balance to fund a debit
     * @dev min(supplied, reserve cash); when the safe carries debt the supplied side is what the gateway's
     *      Aave-priced headroom allows (collateralForHeadroom), including supply with no borrowing power,
     *      which Aave lets go freely.
     */
    function withdrawableSupplied(ILendGateway gateway, address safe, address token, uint256 headroom, bool hasDebt) public view returns (uint256) {
        uint256 supplied = hasDebt ? gateway.collateralForHeadroom(safe, token, headroom) : gateway.suppliedOf(safe, token);
        uint256 cash = gateway.withdrawalLiquidity(token);
        return supplied < cash ? supplied : cash;
    }

    /**
     * @notice Max credit-mode spend in 6-decimal payment USD
     * @dev For each settlement token, converts min(Aave-priced user capacity, Hub liquidity) through
     *      PriceProvider, rounding payment USD down; returns the largest executable candidate.
     */
    function maxSpendCredit(ILendGateway gateway, IPriceProvider priceProvider, address safe) public view returns (uint256) {
        // A credit spend draws ONE card-settleable token. For each candidate, cap its Aave-priced user
        // capacity by reserve-level liquidity, then use PriceProvider only to express that token amount in
        // payment USD. The largest candidate is the executable max spend.
        address[] memory spendTokens = gateway.spendAssets();
        uint256 maxSpendUsd = 0;
        for (uint256 i = 0; i < spendTokens.length;) {
            address token = spendTokens[i];
            if (gateway.isBorrowable(token)) {
                uint256 liquidity = gateway.borrowLiquidity(token);
                uint256 capacity = gateway.borrowCapacity(safe, token);
                uint256 executableAmount = liquidity < capacity ? liquidity : capacity;
                uint256 spendUsd = toUsd(priceProvider, token, executableAmount);
                if (spendUsd > maxSpendUsd) maxSpendUsd = spendUsd;
            }
            unchecked {
                ++i;
            }
        }
        return maxSpendUsd;
    }

    /**
     * @notice Credit authorization gate for token eligibility, Hub liquidity, and Aave-priced buffered capacity
     * @dev PriceProvider converts payment USD to the actual token amount, rounded up. borrowCapacity values that
     *      amount with Aave's oracle and the configured health-factor floor (the buffered quote). Loose collateral
     *      a spend could resupply is deliberately excluded because authorization must not cancel a pending withdrawal.
     */
    function creditCheck(ILendGateway gateway, IPriceProvider priceProvider, address safe, address token, uint256 totalSpendingInUsd) public view returns (bool, string memory) {
        // Matching spendCredit's execution gate: the drawn token settles the card, so it must be a
        // card-settleable spend asset AND borrowable on Aave
        if (!gateway.isBorrowable(token) || !gateway.isSpendAsset(token)) {
            return (false, "Not a supported borrow token");
        }

        uint256 borrowAmount = fromUsdUp(priceProvider, token, totalSpendingInUsd);
        if (gateway.borrowLiquidity(token) < borrowAmount) {
            return (false, "Insufficient liquidity to cover the loan");
        }

        if (gateway.borrowCapacity(safe, token) < borrowAmount) {
            return (false, "Insufficient borrowing power");
        }

        return (true, "");
    }

    /**
     * @notice Amount of `token` withdrawable from `safe`'s supplied balance to fund a repay whose loose leg
     *         repays `fromLoose` first
     * @dev Repaying the loose leg lowers the debt while the collateral is untouched, so the withdraw leg
     *      sizes against the headroom that repay frees (borrowValue). Raw headroom: a repay de-risks the
     *      position, so it is floor-exempt like spends. Callers only get here with debt remaining after
     *      the loose leg, so the headroom cap always applies.
     */
    function repayWithdrawable(ILendGateway gateway, address safe, address token, uint256 fromLoose) public view returns (uint256) {
        uint256 headroom = gateway.rawWithdrawHeadroom(safe) + gateway.borrowValue(token, fromLoose);
        return withdrawableSupplied(gateway, safe, token, headroom, true);
    }

    /// @notice USD value of `amount` of `token` at its current price, rounding down
    function toUsd(IPriceProvider priceProvider, address token, uint256 amount) public view returns (uint256) {
        return (amount * priceProvider.price(token)) / (10 ** IERC20Metadata(token).decimals());
    }

    /// @notice Amount of `token` worth no more than `usd` at its current price, rounding down
    function fromUsd(IPriceProvider priceProvider, address token, uint256 usd) public view returns (uint256) {
        return (usd * (10 ** IERC20Metadata(token).decimals())) / priceProvider.price(token);
    }

    /// @notice Amount of `token` needed to cover `usd` at its current price, rounding up
    function fromUsdUp(IPriceProvider priceProvider, address token, uint256 usd) public view returns (uint256) {
        return Math.mulDiv(usd, 10 ** IERC20Metadata(token).decimals(), priceProvider.price(token), Math.Rounding.Ceil);
    }
}
