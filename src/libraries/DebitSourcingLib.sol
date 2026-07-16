// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ILendGateway } from "../interfaces/ILendGateway.sol";
import { IPriceProvider } from "../interfaces/IPriceProvider.sol";

/**
 * @title DebitSourcingLib
 * @notice Shared debit-sizing math for the Cash contracts: how much of a token's Aave-supplied balance can fund
 *         a debit without pushing the safe past its LTV max borrow, and how much borrowing headroom a supplied
 *         withdrawal consumes. CashModuleCore (execution) and CashLens (canSpend) both call it so the two agree.
 * @author ether.fi
 */
library DebitSourcingLib {
    /// @dev The gateway reports LTV on the 100e18 = 100% scale (see ILendGateway.ltv)
    uint256 internal constant LTV_SCALE = 100e18;

    /**
     * @notice Amount of `token` withdrawable from `safe`'s Aave-supplied balance to fund a debit
     * @dev min(supplied, reserve cash); when the safe carries debt this is further capped by the borrowing
     *      headroom, and is zero for a zero-LTV reserve (no borrow weight, so it cannot be sized against debt).
     */
    function withdrawableSupplied(ILendGateway gateway, IPriceProvider priceProvider, address safe, address token, uint256 borrowHeadroomUsd, bool hasDebt) public view returns (uint256) {
        uint256 supplied = gateway.suppliedOf(safe, token);
        uint256 cash = gateway.withdrawalLiquidity(token);
        uint256 cap = supplied < cash ? supplied : cash;

        if (hasDebt) {
            uint256 tokenLtv = gateway.ltv(token);
            if (tokenLtv == 0) {
                return 0;
            }
            uint256 headroomCap = fromUsd(priceProvider, token, (borrowHeadroomUsd * LTV_SCALE) / tokenLtv);
            if (headroomCap < cap) {
                cap = headroomCap;
            }
        }

        return cap;
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
     * @notice Borrow headroom (USD) the lens may size collateral withdrawals against: consuming it keeps
     *         the post-withdraw health factor at or above the gateway's floor; raw availableBorrowsUsd
     *         while no floor is set
     * @dev HF' = (maxBorrowUsd - consumed) / debtUsd >= floor <=> consumed <= maxBorrowUsd - debtUsd * floor.
     *      Withdrawal requests also enforce the floor at execution, so this quote is what a request can pull
     *      while Cash and Aave prices agree.
     */
    function bufferedDebitHeadroom(ILendGateway gateway, ILendGateway.AccountData memory account) public view returns (uint256) {
        uint256 floor = gateway.minHealthFactor();
        if (floor == 0) return account.availableBorrowsUsd;
        // required is a MINIMUM, so it rounds up: rounding down would let the exact max quote sit one
        // micro-dollar past the floor and fail the post-op health check
        uint256 required = (account.debtUsd * floor + 1e18 - 1) / 1e18;
        uint256 maxBorrow = account.availableBorrowsUsd + account.debtUsd;
        return maxBorrow > required ? maxBorrow - required : 0;
    }

    /// @notice Borrowing headroom (USD) consumed by withdrawing `amount` of `token`: its USD value weighted by the LTV
    function headroomConsumed(ILendGateway gateway, IPriceProvider priceProvider, address token, uint256 amount) public view returns (uint256) {
        return (toUsd(priceProvider, token, amount) * gateway.ltv(token)) / LTV_SCALE;
    }

    /**
     * @notice Amount of `token` withdrawable from `safe`'s supplied balance to fund a repay whose loose leg
     *         repays `fromLoose` first
     * @dev Repaying the loose leg lowers the debt by its full USD value while the collateral is untouched,
     *      so the withdraw leg sizes against that much extra headroom. Callers only get here with debt
     *      remaining after the loose leg, so the headroom cap always applies.
     */
    function repayWithdrawable(ILendGateway gateway, IPriceProvider priceProvider, address safe, address token, uint256 fromLoose) public view returns (uint256) {
        uint256 headroomUsd = gateway.getAccountData(safe).availableBorrowsUsd + toUsd(priceProvider, token, fromLoose);
        return withdrawableSupplied(gateway, priceProvider, safe, token, headroomUsd, true);
    }

    /// @notice USD value of `amount` of `token` at its current price, rounding down
    function toUsd(IPriceProvider priceProvider, address token, uint256 amount) public view returns (uint256) {
        return (amount * priceProvider.price(token)) / (10 ** IERC20Metadata(token).decimals());
    }

    /// @notice USD value of `amount` of `token` at its current price, rounding up
    function toUsdUp(IPriceProvider priceProvider, address token, uint256 amount) public view returns (uint256) {
        return Math.mulDiv(amount, priceProvider.price(token), 10 ** IERC20Metadata(token).decimals(), Math.Rounding.Ceil);
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
