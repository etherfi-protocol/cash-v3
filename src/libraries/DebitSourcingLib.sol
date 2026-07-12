// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

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
        uint256 cash = gateway.availableCash(token);
        uint256 cap = supplied < cash ? supplied : cash;

        if (hasDebt) {
            uint256 tokenLtv = gateway.ltv(token);
            if (tokenLtv == 0) {
                return 0;
            }
            uint256 headroomCap = _fromUsd(priceProvider, token, (borrowHeadroomUsd * LTV_SCALE) / tokenLtv);
            if (headroomCap < cap) {
                cap = headroomCap;
            }
        }

        return cap;
    }

    /// @notice Borrowing headroom (USD) consumed by withdrawing `amount` of `token`: its USD value weighted by the LTV
    function headroomConsumed(ILendGateway gateway, IPriceProvider priceProvider, address token, uint256 amount) public view returns (uint256) {
        return (_toUsd(priceProvider, token, amount) * gateway.ltv(token)) / LTV_SCALE;
    }

    /**
     * @notice Amount of `token` withdrawable from `safe`'s supplied balance to fund a repay whose loose leg
     *         repays `fromLoose` first
     * @dev Repaying the loose leg lowers the debt by its full USD value while the collateral is untouched,
     *      so the withdraw leg sizes against that much extra headroom. Callers only get here with debt
     *      remaining after the loose leg, so the headroom cap always applies.
     */
    function repayWithdrawable(ILendGateway gateway, IPriceProvider priceProvider, address safe, address token, uint256 fromLoose) public view returns (uint256) {
        uint256 headroomUsd = gateway.getAccountData(safe).availableBorrowsUsd + _toUsd(priceProvider, token, fromLoose);
        return withdrawableSupplied(gateway, priceProvider, safe, token, headroomUsd, true);
    }

    /// @dev USD value of `amount` of `token` at its current price, on PriceProvider's USD scale
    function _toUsd(IPriceProvider priceProvider, address token, uint256 amount) private view returns (uint256) {
        return (amount * priceProvider.price(token)) / (10 ** IERC20Metadata(token).decimals());
    }

    /// @dev Amount of `token` worth `usd` at its current price, inverting _toUsd
    function _fromUsd(IPriceProvider priceProvider, address token, uint256 usd) private view returns (uint256) {
        return (usd * (10 ** IERC20Metadata(token).decimals())) / priceProvider.price(token);
    }
}
