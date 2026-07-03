// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { ICashEventEmitter } from "../interfaces/ICashEventEmitter.sol";
import { WithdrawalRequest } from "../interfaces/ICashModule.sol";
import { IDebtManager } from "../interfaces/IDebtManager.sol";
import { IGateway } from "../interfaces/IGateway.sol";
import { IPriceProvider } from "../interfaces/IPriceProvider.sol";
import { DebitSourcingLib } from "./DebitSourcingLib.sol";

/**
 * @title CreditSourcingLib
 * @notice Sources borrowing capacity for a credit spend that no longer fits the safe's Aave position:
 *         resupplies loose collateral to Aave so an auth approved before an instant
 *         collateral withdrawal still lands. Only CashModuleCore calls it; CashLens must never count
 *         this capacity, so it stays out of DebitSourcingLib's shared math.
 * @dev Deployed as a linked library (public function) so the resupply machinery does not count against
 *      CashModuleCore's EIP-170 size. It runs via delegatecall in the module's context.
 * @author ether.fi
 */
library CreditSourcingLib {
    /// @dev Pad on resupply sizing so Aave share rounding cannot leave the headroom short; excess supply is harmless
    uint256 internal constant RESUPPLY_BUFFER_BPS = 10;

    /**
     * @notice Supplies loose collateral from the safe as Aave collateral to cover the part of a credit
     *         spend that its borrowing capacity no longer covers
     * @dev The first pass sizes only against balance not reserved by the pending withdrawal request; the
     *      reserved remainder is taken only when the spend cannot be funded otherwise. Sizing finishes
     *      before any supply, so it does not depend on the gateway's transfer timing. If loose collateral
     *      cannot fully cover, it supplies what fits and the caller's subsequent borrow reverts the spend.
     * @param gateway The Aave gateway
     * @param debtManager The debt manager, for the collateral token list
     * @param priceProvider The price provider
     * @param emitter The cash event emitter
     * @param pendingRequest The safe's pending withdrawal request
     * @param safe Address of the EtherFi Safe
     * @param spendUsd Credit spend amount in USD
     * @return Whether sizing dipped into balance reserved by the pending withdrawal request, in which
     *         case the caller must cancel the request
     */
    function resupplyCollateral(IGateway gateway, IDebtManager debtManager, IPriceProvider priceProvider, ICashEventEmitter emitter, WithdrawalRequest storage pendingRequest, address safe, uint256 spendUsd) public returns (bool) {
        uint256 availableUsd = gateway.getAccountData(safe).availableBorrowsUsd;
        if (spendUsd <= availableUsd) {
            return false;
        }
        uint256 shortfallUsd = spendUsd - availableUsd;

        address[] memory tokens = debtManager.getCollateralTokens();
        uint256[] memory supplyAmounts = new uint256[](tokens.length);

        bool dippedReserved = false;
        shortfallUsd = _sizingPass(gateway, priceProvider, pendingRequest, safe, tokens, supplyAmounts, shortfallUsd, false);
        if (shortfallUsd != 0) {
            dippedReserved = true;
            _sizingPass(gateway, priceProvider, pendingRequest, safe, tokens, supplyAmounts, shortfallUsd, true);
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            if (supplyAmounts[i] != 0) {
                gateway.supply(safe, tokens[i], supplyAmounts[i]);
                gateway.setUsingAsCollateral(safe, tokens[i], true);
                emitter.emitCollateralResupplied(safe, tokens[i], supplyAmounts[i]);
            }
        }
        return dippedReserved;
    }

    /**
     * @dev One resupply sizing pass over the collateral tokens, accumulating into `supplyAmounts`. Skips the
     *      balance reserved by the pending withdrawal unless `useReserved` is set.
     * @return The USD shortfall left after the pass
     */
    function _sizingPass(IGateway gateway, IPriceProvider priceProvider, WithdrawalRequest storage pendingRequest, address safe, address[] memory tokens, uint256[] memory supplyAmounts, uint256 shortfallUsd, bool useReserved) private view returns (uint256) {
        for (uint256 i = 0; i < tokens.length && shortfallUsd != 0; i++) {
            uint256 tokenLtv = gateway.ltv(tokens[i]);
            if (tokenLtv == 0) {
                continue;
            }
            uint256 capacity = IERC20(tokens[i]).balanceOf(safe) - supplyAmounts[i];
            if (!useReserved) {
                uint256 pending = _pendingAmount(pendingRequest, tokens[i]);
                capacity = capacity > pending ? capacity - pending : 0;
            }
            if (capacity == 0) {
                continue;
            }

            uint256 needed = _supplyAmount(priceProvider, tokens[i], tokenLtv, shortfallUsd);
            if (needed <= capacity) {
                supplyAmounts[i] += needed;
                return 0;
            }
            supplyAmounts[i] += capacity;
            // Taking capacity of the needed amount covers the same fraction of the shortfall; floor keeps the remainder conservative
            shortfallUsd -= (shortfallUsd * capacity) / needed;
        }
        return shortfallUsd;
    }

    /**
     * @dev Amount of `token` to supply so its LTV-weighted USD value adds `neededUsd` of borrowing
     *      headroom: inverts DebitSourcingLib.headroomConsumed in one ceil-div, padded by
     *      RESUPPLY_BUFFER_BPS. Caller guarantees tokenLtv != 0.
     */
    function _supplyAmount(IPriceProvider priceProvider, address token, uint256 tokenLtv, uint256 neededUsd) private view returns (uint256) {
        uint256 numerator = neededUsd * DebitSourcingLib.LTV_SCALE * (10 ** IERC20Metadata(token).decimals()) * (10_000 + RESUPPLY_BUFFER_BPS);
        uint256 denominator = tokenLtv * priceProvider.price(token) * 10_000;
        return (numerator + denominator - 1) / denominator;
    }

    /// @dev Amount of `token` in the pending withdrawal request, zero if absent
    function _pendingAmount(WithdrawalRequest storage pendingRequest, address token) private view returns (uint256) {
        uint256 len = pendingRequest.tokens.length;
        for (uint256 i = 0; i < len; i++) {
            if (pendingRequest.tokens[i] == token) {
                return pendingRequest.amounts[i];
            }
        }
        return 0;
    }
}
