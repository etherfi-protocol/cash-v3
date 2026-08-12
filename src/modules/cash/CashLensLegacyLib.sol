// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { DebitModeMaxSpend, ICashModule, Mode, SafeData } from "../../interfaces/ICashModule.sol";
import { IDebtManager } from "../../interfaces/IDebtManager.sol";

/**
 * @title CashLensLegacyLib
 * @notice CashLens's legacy-engine branches: the pre-gateway, DebtManager-based spend checks and max-spend
 *         calculations, preserved output-identical (including decline strings) for safes still on the legacy
 *         engine. CashLens routes here when a safe's engine flag is off; the gateway logic lives in CashLens
 *         itself. Deployed as a linked external library so both engines' logic fits the lens under EIP-170.
 * @dev Deleted wholesale when the legacy DebtManager engine is retired.
 * @author ether.fi
 */
library CashLensLegacyLib {
    using Math for uint256;

    uint256 internal constant HUNDRED_PERCENT = 100e18;

    /// @notice Mirrors CashLens.NotABorrowToken selector-for-selector
    error NotABorrowToken();

    /// @dev Result of walking the preference order to cover an underwater position's deficit
    struct DeficitCoverage {
        uint256[] spendableAmounts;
        uint256[] spendableUsdValues;
        uint256 remainingDeficit;
        uint256 lastProcessedIndex;
    }

    /**
     * @notice Mode-specific spend check for a legacy safe: validates tokens, converts amounts, and checks
     *         DebtManager liquidity/borrowing power (credit) or post-spend health (debit)
     * @dev The caller has already validated array shapes, the tx id, the spending limit, and the
     *      one-token-in-credit rule; decline strings here are byte-identical to the pre-gateway lens.
     * @param cashModule The CashModule (for the DebtManager reference)
     * @param safe Address of the EtherFi Safe
     * @param tokens Addresses of the tokens to spend
     * @param amountsInUsd Amounts to spend in USD
     * @param totalSpendingInUsd Total spend in USD
     * @param safeData The safe's cash data (for pending withdrawal reservations)
     * @param mode The applicable spend mode
     * @return Whether the spend is allowed
     * @return The decline reason when it is not
     */
    function check(ICashModule cashModule, address safe, address[] memory tokens, uint256[] memory amountsInUsd, uint256 totalSpendingInUsd, SafeData memory safeData, Mode mode) external view returns (bool, string memory) {
        IDebtManager debtManager = cashModule.getDebtManager();
        uint256[] memory amounts = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            if (!debtManager.isBorrowToken(tokens[i])) {
                return (false, "Not a supported stable token");
            }

            amounts[i] = debtManager.convertUsdToCollateralToken(tokens[i], amountsInUsd[i]);

            if (mode == Mode.Debit && IERC20(tokens[i]).balanceOf(safe) < amounts[i]) {
                return (false, "Insufficient token balance for debit mode spending");
            }
        }

        if (mode == Mode.Credit) {
            return _creditModeCheck(debtManager, safe, tokens, amounts, totalSpendingInUsd, safeData);
        }
        return _debitModeCheck(debtManager, safe, tokens, amounts, safeData);
    }

    /**
     * @notice Maximum credit-mode spend for a legacy safe: borrowing power minus current borrowings on the
     *         DebtManager, after reserving pending withdrawals from the collateral
     * @param cashModule The CashModule (for the DebtManager reference)
     * @param safe Address of the EtherFi Safe
     * @return Maximum spendable in credit mode (USD, 6 decimals); 0 for an unhealthy or empty position
     */
    function maxSpendCredit(ICashModule cashModule, address safe) external view returns (uint256) {
        IDebtManager debtManager = cashModule.getDebtManager();
        SafeData memory safeData = cashModule.getData(safe);

        (IDebtManager.TokenData[] memory collateralTokenAmounts, string memory declineReason) = _getCollateralBalanceWithTokensSubtracted(debtManager, safe, safeData, new address[](0), new uint256[](0), Mode.Credit);
        if (bytes(declineReason).length != 0 || collateralTokenAmounts.length == 0) {
            return 0;
        }

        (uint256 totalMaxBorrow, uint256 totalBorrowings) = debtManager.getBorrowingPowerAndTotalBorrowing(safe, collateralTokenAmounts);
        if (totalBorrowings > totalMaxBorrow) {
            return 0;
        }

        return totalMaxBorrow - totalBorrowings;
    }

    /**
     * @notice Maximum debit-mode spend per token for a legacy safe, in preference order
     * @dev When the position is underwater (borrowings exceed max borrow), earlier tokens are consumed as
     *      collateral to restore health before later ones become spendable, exactly as the pre-gateway lens
     *      calculated it. The caller has already validated a non-empty, duplicate-free preference array.
     * @param cashModule The CashModule (for the DebtManager reference)
     * @param safe Address of the EtherFi Safe
     * @param debtServiceTokenPreference Ordered borrow-token preference; order determines deficit coverage
     * @return Per-token spendable amounts and USD values with the aggregate total
     */
    function maxSpendDebit(ICashModule cashModule, address safe, address[] memory debtServiceTokenPreference) external view returns (DebitModeMaxSpend memory) {
        uint256 len = debtServiceTokenPreference.length;
        IDebtManager debtManager = cashModule.getDebtManager();
        SafeData memory safeData = cashModule.getData(safe);

        (uint256[] memory effectiveBalances, uint256[] memory tokenValuesInUsd, uint256 totalValueInUsd) = _calculateTokenValues(debtManager, safe, safeData, debtServiceTokenPreference, len);

        if (totalValueInUsd == 0) {
            return DebitModeMaxSpend(debtServiceTokenPreference, new uint256[](len), new uint256[](len), 0);
        }

        // Check collateral after theoretically spending all debit tokens
        (IDebtManager.TokenData[] memory collateralTokenAmounts, string memory declineReason) = _getCollateralBalanceWithTokensSubtracted(debtManager, safe, safeData, debtServiceTokenPreference, effectiveBalances, Mode.Debit);
        if (bytes(declineReason).length != 0) {
            return DebitModeMaxSpend(new address[](0), new uint256[](0), new uint256[](0), 0);
        }

        (uint256 totalMaxBorrow, uint256 totalBorrowings) = debtManager.getBorrowingPowerAndTotalBorrowing(safe, collateralTokenAmounts);

        // Healthy position: every effective balance is spendable
        if (totalBorrowings == 0 || totalMaxBorrow >= totalBorrowings) {
            return DebitModeMaxSpend(debtServiceTokenPreference, effectiveBalances, tokenValuesInUsd, totalValueInUsd);
        }

        return _processUnderwaterPosition(debtServiceTokenPreference, tokenValuesInUsd, effectiveBalances, debtManager, totalBorrowings - totalMaxBorrow);
    }

    /**
     * @notice A legacy safe's effective collateral balances: raw loose balances minus pending withdrawals,
     *         zero balances skipped
     * @dev DebtManager reads this for its health and borrow checks; semantics must stay exactly pre-gateway.
     * @param cashModule The CashModule (for the pending withdrawal request)
     * @param safe Address of the EtherFi Safe
     * @param collateralTokens The DebtManager's collateral token list
     * @return Array of token data with token addresses and effective amounts
     */
    function userTotalCollateral(ICashModule cashModule, address safe, address[] memory collateralTokens) external view returns (IDebtManager.TokenData[] memory) {
        SafeData memory safeData = cashModule.getData(safe);
        uint256 len = collateralTokens.length;
        IDebtManager.TokenData[] memory tokenAmounts = new IDebtManager.TokenData[](collateralTokens.length);
        uint256 m = 0;
        for (uint256 i = 0; i < len;) {
            uint256 balance = IERC20(collateralTokens[i]).balanceOf(safe);
            uint256 pendingWithdrawalAmount = _pendingWithdrawalAmount(safeData, collateralTokens[i]);
            if (balance != 0) {
                balance = balance > pendingWithdrawalAmount ? balance - pendingWithdrawalAmount : 0;
                if (balance != 0) {
                    tokenAmounts[m] = IDebtManager.TokenData({ token: collateralTokens[i], amount: balance });
                    unchecked {
                        ++m;
                    }
                }
            }
            unchecked {
                ++i;
            }
        }

        assembly ("memory-safe") {
            mstore(tokenAmounts, m)
        }

        return tokenAmounts;
    }

    /// @dev Credit mode check: DebtManager liquidity, then borrowing power over the reserved collateral
    function _creditModeCheck(IDebtManager debtManager, address safe, address[] memory tokens, uint256[] memory amounts, uint256 totalSpendingInUsd, SafeData memory safeData) private view returns (bool, string memory) {
        if (IERC20(tokens[0]).balanceOf(address(debtManager)) < amounts[0]) {
            return (false, "Insufficient liquidity in debt manager to cover the loan");
        }

        (IDebtManager.TokenData[] memory collateralTokenAmounts, string memory declineReason) = _getCollateralBalanceWithTokensSubtracted(debtManager, safe, safeData, tokens, amounts, Mode.Credit);
        if (bytes(declineReason).length != 0) {
            return (false, declineReason);
        }

        (uint256 totalMaxBorrow, uint256 totalBorrowings) = debtManager.getBorrowingPowerAndTotalBorrowing(safe, collateralTokenAmounts);
        if (totalBorrowings > totalMaxBorrow) {
            return (false, "Borrowings greater than max borrow");
        }
        if (totalSpendingInUsd > totalMaxBorrow - totalBorrowings) {
            return (false, "Insufficient borrowing power");
        }

        return (true, "");
    }

    /// @dev Debit mode check: simulates the spend against the collateral and requires the position stays healthy
    function _debitModeCheck(IDebtManager debtManager, address safe, address[] memory tokens, uint256[] memory amounts, SafeData memory safeData) private view returns (bool, string memory) {
        (IDebtManager.TokenData[] memory collateralTokenAmounts, string memory declineReason) = _getCollateralBalanceWithTokensSubtracted(debtManager, safe, safeData, tokens, amounts, Mode.Debit);
        if (bytes(declineReason).length != 0) {
            return (false, declineReason);
        }

        (uint256 totalMaxBorrow, uint256 totalBorrowings) = debtManager.getBorrowingPowerAndTotalBorrowing(safe, collateralTokenAmounts);
        if (totalBorrowings > totalMaxBorrow) {
            return (false, "Borrowings greater than max borrow after spending");
        }

        return (true, "");
    }

    /// @dev Effective balance (loose minus pending withdrawal) and USD value per preference token
    function _calculateTokenValues(IDebtManager debtManager, address safe, SafeData memory safeData, address[] memory tokens, uint256 len) private view returns (uint256[] memory, uint256[] memory, uint256) {
        uint256[] memory effectiveBalances = new uint256[](len);
        uint256[] memory tokenValuesInUsd = new uint256[](len);
        uint256 totalValueInUsd = 0;

        for (uint256 i = 0; i < len;) {
            address token = tokens[i];
            if (!debtManager.isBorrowToken(token)) revert NotABorrowToken();

            effectiveBalances[i] = IERC20(token).balanceOf(safe) - _pendingWithdrawalAmount(safeData, token);

            if (effectiveBalances[i] > 0) {
                tokenValuesInUsd[i] = debtManager.convertCollateralTokenToUsd(token, effectiveBalances[i]);
                totalValueInUsd += tokenValuesInUsd[i];
            }

            unchecked {
                ++i;
            }
        }

        return (effectiveBalances, tokenValuesInUsd, totalValueInUsd);
    }

    /// @dev Consumes tokens in preference order to cover the health deficit; the rest stays spendable
    function _processUnderwaterPosition(address[] memory tokens, uint256[] memory tokenValuesInUsd, uint256[] memory effectiveBalances, IDebtManager debtManager, uint256 deficit) private view returns (DebitModeMaxSpend memory) {
        DeficitCoverage memory c = _coverDeficitAndCalculateSpendable(tokens, tokenValuesInUsd, debtManager, deficit);

        // If the deficit cannot be covered, nothing is spendable
        if (c.remainingDeficit > 0) {
            return DebitModeMaxSpend(new address[](0), new uint256[](0), new uint256[](0), 0);
        }

        uint256 totalSpendableUsd = _addRemainingTokens(c.spendableAmounts, c.spendableUsdValues, effectiveBalances, tokenValuesInUsd, c.lastProcessedIndex, tokens.length);

        return DebitModeMaxSpend(tokens, c.spendableAmounts, c.spendableUsdValues, totalSpendableUsd);
    }

    /// @dev Walks the preference order covering the deficit with each token's borrowing power
    function _coverDeficitAndCalculateSpendable(address[] memory tokens, uint256[] memory tokenValuesInUsd, IDebtManager debtManager, uint256 deficit) private view returns (DeficitCoverage memory) {
        uint256 len = tokens.length;
        DeficitCoverage memory c;
        c.spendableAmounts = new uint256[](len);
        c.spendableUsdValues = new uint256[](len);
        c.remainingDeficit = deficit;

        for (uint256 i = 0; i < len && c.remainingDeficit > 0;) {
            uint256 tokenValue = tokenValuesInUsd[i];

            if (tokenValue > 0) {
                (uint256 spendableAmount, uint256 spendableUsd, uint256 deficitCovered) = _processTokenForDeficit(tokens[i], tokenValue, c.remainingDeficit, debtManager);

                c.spendableAmounts[i] = spendableAmount;
                c.spendableUsdValues[i] = spendableUsd;
                c.remainingDeficit -= deficitCovered;
                c.lastProcessedIndex = i;

                if (c.remainingDeficit == 0) break;
            }

            unchecked {
                ++i;
            }
        }

        return c;
    }

    /// @dev How much of one token is spendable after it contributes borrowing power toward the deficit
    function _processTokenForDeficit(address token, uint256 tokenValue, uint256 remainingDeficit, IDebtManager debtManager) private view returns (uint256, uint256, uint256) {
        uint80 ltv = debtManager.collateralTokenConfig(token).ltv;
        uint256 borrowingPower = tokenValue.mulDiv(ltv, HUNDRED_PERCENT, Math.Rounding.Floor);

        if (borrowingPower >= remainingDeficit) {
            // This token covers the remaining deficit; the excess stays spendable
            uint256 collateralNeeded = remainingDeficit.mulDiv(HUNDRED_PERCENT, ltv, Math.Rounding.Ceil);
            uint256 spendableUsd = tokenValue - collateralNeeded;
            return (debtManager.convertUsdToCollateralToken(token, spendableUsd), spendableUsd, remainingDeficit);
        }

        // This token cannot cover the deficit alone: all of it is held back as collateral
        return (0, 0, borrowingPower);
    }

    /// @dev Sums the deficit-phase spendables and marks every later token fully spendable
    function _addRemainingTokens(uint256[] memory spendableAmounts, uint256[] memory spendableUsdValues, uint256[] memory effectiveBalances, uint256[] memory tokenValuesInUsd, uint256 lastProcessedIndex, uint256 len) private pure returns (uint256) {
        uint256 totalSpendableUsd = 0;

        for (uint256 i = 0; i <= lastProcessedIndex;) {
            totalSpendableUsd += spendableUsdValues[i];
            unchecked {
                ++i;
            }
        }

        for (uint256 i = lastProcessedIndex + 1; i < len;) {
            if (tokenValuesInUsd[i] > 0) {
                spendableAmounts[i] = effectiveBalances[i];
                spendableUsdValues[i] = tokenValuesInUsd[i];
                totalSpendableUsd += tokenValuesInUsd[i];
            }
            unchecked {
                ++i;
            }
        }

        return totalSpendableUsd;
    }

    /**
     * @dev Collateral balances net of pending withdrawals, with the spend amounts subtracted for tokens
     *      being spent (Debit mode simulation). Returns an error string when a spend amount exceeds the
     *      post-reservation balance.
     */
    function _getCollateralBalanceWithTokensSubtracted(IDebtManager debtManager, address safe, SafeData memory safeData, address[] memory tokens, uint256[] memory amounts, Mode mode) private view returns (IDebtManager.TokenData[] memory, string memory) {
        address[] memory collateralTokens = debtManager.getCollateralTokens();
        uint256 len = collateralTokens.length;

        IDebtManager.TokenData[] memory tokenAmounts = new IDebtManager.TokenData[](collateralTokens.length);
        uint256 m = 0;

        for (uint256 i = 0; i < len;) {
            uint256 balance = IERC20(collateralTokens[i]).balanceOf(safe);
            uint256 pendingWithdrawalAmount = _pendingWithdrawalAmount(safeData, collateralTokens[i]);

            if (balance != 0) {
                balance = balance - pendingWithdrawalAmount;

                if (mode == Mode.Debit) {
                    // Subtract the spend amount when this collateral token is being spent
                    for (uint256 j = 0; j < tokens.length; j++) {
                        if (collateralTokens[i] == tokens[j]) {
                            if (balance < amounts[j]) {
                                return (new IDebtManager.TokenData[](0), "Insufficient effective balance after withdrawal to spend with debit mode");
                            }

                            balance = balance - amounts[j];
                            break;
                        }
                    }
                }

                tokenAmounts[m] = IDebtManager.TokenData({ token: collateralTokens[i], amount: balance });

                unchecked {
                    ++m;
                }
            }
            unchecked {
                ++i;
            }
        }

        assembly ("memory-safe") {
            mstore(tokenAmounts, m)
        }

        return (tokenAmounts, "");
    }

    /// @dev The amount of `token` reserved by the safe's pending withdrawal request, or 0 if none holds it
    function _pendingWithdrawalAmount(SafeData memory safeData, address token) private pure returns (uint256) {
        uint256 len = safeData.pendingWithdrawalRequest.tokens.length;
        for (uint256 i = 0; i < len;) {
            if (safeData.pendingWithdrawalRequest.tokens[i] == token) {
                return safeData.pendingWithdrawalRequest.amounts[i];
            }
            unchecked {
                ++i;
            }
        }
        return 0;
    }
}
