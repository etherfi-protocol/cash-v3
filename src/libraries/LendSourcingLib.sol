// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ILendGateway } from "../interfaces/ILendGateway.sol";
import { IPriceProvider } from "../interfaces/IPriceProvider.sol";

/**
 * @title LendSourcingLib
 * @notice Shared sourcing math for the Cash contracts: how debit spends and repays draw on a safe's
 *         Aave-supplied balance within the gateway's collateral headroom, and how credit spends are
 *         quoted and gated against its Aave capacity. CashModuleCore (execution) and CashLens (canSpend)
 *         both call it so the two agree; PriceProvider's only role here is converting payment USD to and
 *         from token amounts.
 * @author ether.fi
 */
library LendSourcingLib {
    /**
     * @notice Amount of `token` withdrawable from `safe`'s Aave-supplied balance to fund a debit
     * @dev min(supplied, reserve cash); when the safe carries debt the supplied side is what the gateway's
     *      Aave-priced headroom allows (collateralForHeadroom), including supply with no borrowing power,
     *      which Aave lets go freely.
     */
    function withdrawableSupplied(ILendGateway gateway, address safe, address token, uint256 headroom, bool hasDebt) public view returns (uint256) {
        (, uint256 withdrawable) = suppliedParts(gateway, safe, token, headroom, hasDebt);
        return withdrawable;
    }

    /**
     * @notice The two legs of withdrawableSupplied: the safe-side supplied amount (headroom-capped when the
     *         safe carries debt) and the amount actually withdrawable once reserve cash is applied
     * @dev Callers that decline a spend use the pair to attribute the shortfall: supplied covering the need
     *      while withdrawable does not means the Hub's cash, not the user's balance, is the binding constraint.
     */
    function suppliedParts(ILendGateway gateway, address safe, address token, uint256 headroom, bool hasDebt) public view returns (uint256 supplied, uint256 withdrawable) {
        supplied = hasDebt ? gateway.collateralForHeadroom(safe, token, headroom) : gateway.suppliedOf(safe, token);
        uint256 cash = gateway.withdrawalLiquidity(token);
        withdrawable = supplied < cash ? supplied : cash;
    }

    /**
     * @notice Sourcing gate for one debit token: loose balance plus the withdrawable supplied amount must
     *         cover `needed`, before and after reserving the `pending` withdrawal against the loose balance
     * @dev The supplied leg is headroom-capped when the safe carries debt; withdrawable further caps it by
     *      reserve cash. A shortfall is the Hub's liquidity failing the user only if the spend would clear
     *      all gates with the cash cap lifted — i.e. the pending-net loose balance plus the full supplied leg
     *      covers the need; both branches attribute against that same predicate, so a spend also blocked by
     *      its pending reservation keeps a user-side reason. On success `raw` is the loose balance net of its
     *      pending-withdrawal reservation, for the caller's headroom accounting.
     */
    function debitTokenCheck(ILendGateway gateway, address safe, address token, uint256 needed, uint256 pending, uint256 headroom, bool hasDebt) public view returns (bool ok, string memory reason, uint256 raw) {
        raw = IERC20Metadata(token).balanceOf(safe);
        (uint256 supplied, uint256 withdrawable) = suppliedParts(gateway, safe, token, headroom, hasDebt);
        uint256 rawNet = raw > pending ? raw - pending : 0;
        if (raw + withdrawable < needed) {
            if (rawNet + supplied >= needed) return (false, "Insufficient Lend withdrawal liquidity, please try again later", 0);
            return (false, "Insufficient token balance for debit mode spending", 0);
        }
        if (rawNet + withdrawable < needed) {
            if (rawNet + supplied >= needed) return (false, "Insufficient Lend withdrawal liquidity, please try again later", 0);
            return (false, "Insufficient effective balance after withdrawal to spend with debit mode", 0);
        }
        return (true, "", rawNet);
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
        // Check the Safe-specific constraint first. A shared-market decline therefore guarantees this Safe
        // had sufficient borrowing power for the quote, which lets downstream systems distinguish a user
        // shortfall from a temporary Hub-side availability problem.
        if (gateway.borrowCapacity(safe, token) < borrowAmount) {
            return (false, "Insufficient borrowing power");
        }

        if (gateway.borrowLiquidity(token) < borrowAmount) {
            // borrowLiquidity folds Hub cash and the spoke's draw cap into one bound; withdrawalLiquidity is
            // the cash alone (zero under the same pause/halt gates), so cash covering the loan means the draw
            // cap (or reported deficit) is what blocks the borrow.
            if (gateway.withdrawalLiquidity(token) >= borrowAmount) {
                return (false, "Lend borrow cap reached, please try again later");
            }
            return (false, "Insufficient Lend liquidity to cover the loan");
        }

        return (true, "");
    }

    /**
     * @notice Amount of `token` withdrawable from `safe`'s supplied balance to fund a repay whose loose leg
     *         repays `fromLoose` first
     * @dev Repaying the loose leg lowers the debt while the collateral is untouched, so the withdraw leg
     *      sizes against the headroom that repay frees (repayValue, exact against Aave's restore share
     *      rounding — the ideal borrowValue can overstate the freed cover by a share and fail Aave's
     *      health check at the exact boundary). Raw headroom: a repay de-risks the position, so it is
     *      floor-exempt like spends. Callers only get here with debt remaining after the loose leg, so
     *      the headroom cap always applies.
     *
     *      Any existing deficit is netted out first: rawWithdrawHeadroom clamps to zero for an underwater
     *      position, so adding the freed value to the clamped figure would over-credit the quote by the
     *      deficit and the sized withdraw would fail Aave's own health check (audit L-08). The loose leg
     *      must therefore free more than the deficit before anything is withdrawable.
     */
    function repayWithdrawable(ILendGateway gateway, address safe, address token, uint256 fromLoose) public view returns (uint256) {
        uint256 headroom = gateway.rawWithdrawHeadroom(safe) + gateway.repayValue(safe, token, fromLoose);
        // Saturating, so a healthy position (deficit 0) keeps the unmodified quote and an underwater one
        // only becomes withdrawable once the repay frees more than the deficit
        uint256 deficit = gateway.deficitValue(safe);
        headroom = headroom > deficit ? headroom - deficit : 0;
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
