// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { ICashModule, Mode, SafeCashData, SafeData, WithdrawalRequest } from "../../interfaces/ICashModule.sol";
import { IDebtManager } from "../../interfaces/IDebtManager.sol";
import { IEtherFiDataProvider } from "../../interfaces/IEtherFiDataProvider.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { IPriceProvider } from "../../interfaces/IPriceProvider.sol";
import { SpendingLimit, SpendingLimitLib } from "../../libraries/SpendingLimitLib.sol";

import { UpgradeableProxy } from "../../utils/UpgradeableProxy.sol";

/**
 * @title CashLens
 * @notice Read-only contract providing views into the state of the CashModule system
 * @dev Extends UpgradeableProxy to provide upgrade functionality
 * @author ether.fi
 */
contract CashLens is UpgradeableProxy {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using SpendingLimitLib for SpendingLimit;
    using Math for uint256;

    /// @notice Reference to the deployed CashModule contract
    ICashModule public immutable cashModule;
    /// @notice Reference to the deployed EtherFiDataProvider contract
    IEtherFiDataProvider public immutable dataProvider;

    /// @notice Constant representing 100% with 18 decimal places
    uint256 public constant HUNDRED_PERCENT = 100e18;

    /// @notice Error thrown when trying to use a token that is not on the collateral whitelist
    error NotACollateralToken();

    /**
     * @notice Initializes the CashLens contract with a reference to the CashModule
     * @param _cashModule Address of the deployed CashModule contract
     * @param _dataProvider Address of the deployed EtherFiDataProvider contract
     */
    constructor(address _cashModule, address _dataProvider) {
        cashModule = ICashModule(_cashModule);
        dataProvider = IEtherFiDataProvider(_dataProvider);
    }

    /**
     * @notice Initializes the UpgradeableProxy base contract
     * @dev Sets up the role registry for access control
     * @param _roleRegistry Address of the role registry contract
     */
    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
    }

    /**
     * @notice Gets the currently applicable spending limit for a safe
     * @dev Returns the spending limit considering current time and renewal logic
     * @param safe Address of the EtherFi Safe
     * @return Current applicable spending limit
     */
    function applicableSpendingLimit(address safe) external view returns (SpendingLimit memory) {
        SafeData memory safeData = cashModule.getData(address(safe));
        return safeData.spendingLimit.getCurrentLimit();
    }

    /**
     * @notice Checks if a spending transaction can be executed
     * @dev Simulates the spending process and checks for potential issues
     * @param safe Address of the EtherFi Safe
     * @param txId Transaction identifier
     * @param token Address of the token to spend
     * @param amountInUsd Amount to spend in USD
     * @return canSpend Boolean indicating if the spending is allowed
     * @return message Error message if spending is not allowed
     */
    function canSpend(address safe, bytes32 txId, address token, uint256 amountInUsd) public view returns (bool, string memory) {
        IDebtManager debtManager = cashModule.getDebtManager();
        if (cashModule.transactionCleared(safe, txId)) return (false, "Transaction already cleared");
        if (!debtManager.isBorrowToken(token)) return (false, "Not a supported stable token");

        uint256 amount = debtManager.convertUsdToCollateralToken(token, amountInUsd);
        if (amount == 0) return (false, "Amount zero");

        SafeData memory safeData = cashModule.getData(safe);
        if (safeData.incomingCreditModeStartTime != 0) safeData.mode = Mode.Credit;

        if (safeData.mode == Mode.Debit && IERC20(token).balanceOf(safe) < amount) return (false, "Insufficient balance to spend with Debit flow");

        (IDebtManager.TokenData[] memory collateralTokenAmounts, string memory error) = _getCollateralBalanceWithTokenSubtracted(debtManager, safe, safeData, token, amount);
        if (bytes(error).length != 0) return (false, error);
        (uint256 totalMaxBorrow, uint256 totalBorrowings) = debtManager.getBorrowingPowerAndTotalBorrowing(safe, collateralTokenAmounts);
        if (totalBorrowings > totalMaxBorrow) return (false, "Borrowings greater than max borrow after spending");
        if (safeData.mode == Mode.Credit) {
            if (amountInUsd > totalMaxBorrow - totalBorrowings) return (false, "Insufficient borrowing power");
            if (IERC20(token).balanceOf(address(debtManager)) < amount) return (false, "Insufficient liquidity in debt manager to cover the loan");
        }

        return safeData.spendingLimit.canSpend(amountInUsd);
    }

    /**
     * @notice Calculates the maximum amount that can be spent in both credit and debit modes
     * @dev Performs separate calculations for credit and debit modes
     * @param safe Address of the EtherFi Safe
     * @param token Address of the token to spend
     * @return returnAmtInCreditModeUsd Maximum amount that can be spent in credit mode (USD)
     * @return returnAmtInDebitModeUsd Maximum amount that can be spent in debit mode (USD)
     * @return spendingLimitAllowance Remaining spending limit allowance
     */
    function maxCanSpend(address safe, address token) public view returns (uint256 returnAmtInCreditModeUsd, uint256 returnAmtInDebitModeUsd, uint256 spendingLimitAllowance) {
        // Get debt manager and safe data once to avoid multiple calls
        IDebtManager debtManager = cashModule.getDebtManager();
        SafeData memory safeData = cashModule.getData(safe);
        spendingLimitAllowance = safeData.spendingLimit.maxCanSpend();

        bool isValidCredit;

        // Handle credit mode calculation
        (returnAmtInCreditModeUsd, isValidCredit) = _calculateCreditModeAmount(debtManager, safe, token, safeData, 0);
        if (!isValidCredit) {
            return (0, 0, spendingLimitAllowance);
        }

        // Handle debit mode calculation - only if credit mode was valid
        returnAmtInDebitModeUsd = _calculateDebitModeAmount(debtManager, safe, token, safeData);
    }

    /**
     * @notice Gets comprehensive cash data for a Safe
     * @dev Aggregates data from multiple sources including DebtManager and CashModule
     * @param safe Address of the EtherFi Safe
     * @return safeCashData Comprehensive data structure containing:
     *   - mode: Current operating mode (Credit or Debit)
     *   - collateralBalances: Array of collateral token balances
     *   - borrows: Array of borrowed token balances
     *   - tokenPrices: Array of token prices
     *   - withdrawalRequest: Current withdrawal request
     *   - totalCollateral: Total value of collateral in USD
     *   - totalBorrow: Total value of borrows in USD
     *   - maxBorrow: Maximum borrowing power in USD
     *   - creditMaxSpend: Maximum spendable amount in Credit mode (USD)
     *   - debitMaxSpend: Maximum spendable amount in Debit mode (USD)
     *   - spendingLimitAllowance: Remaining spending limit allowance
     *   - totalCashbackEarnedInUsd: Running total of all cashback earned by this safe (and its spenders) in USD
     *   - incomingCreditModeStartTime: Timestamp when a pending change to Credit mode will take effect (0 if no pending change)
     */
    function getSafeCashData(address safe) external view returns (SafeCashData memory safeCashData) {
        IDebtManager debtManager = cashModule.getDebtManager();
        IPriceProvider priceProvider = IPriceProvider(dataProvider.getPriceProvider());
        SafeData memory safeData = cashModule.getData(safe);

        (safeCashData.collateralBalances, safeCashData.totalCollateral, safeCashData.borrows, safeCashData.totalBorrow) = debtManager.getUserCurrentState(safe);

        safeCashData.withdrawalRequest = safeData.pendingWithdrawalRequest;
        safeCashData.maxBorrow = debtManager.getMaxBorrowAmount(safe, true);

        address[] memory supportedTokens = debtManager.getCollateralTokens();
        uint256 len = supportedTokens.length;
        safeCashData.tokenPrices = new IDebtManager.TokenData[](len);

        for (uint256 i = 0; i < len;) {
            safeCashData.tokenPrices[i].token = supportedTokens[i];
            safeCashData.tokenPrices[i].amount = priceProvider.price(supportedTokens[i]);
            unchecked {
                ++i;
            }
        }

        (safeCashData.creditMaxSpend, safeCashData.debitMaxSpend, safeCashData.spendingLimitAllowance) = maxCanSpend(safe, debtManager.getBorrowTokens()[0]);
        safeCashData.mode = safeData.mode;
        safeCashData.totalCashbackEarnedInUsd = safeData.totalCashbackEarnedInUsd;
        safeCashData.incomingCreditModeStartTime = safeData.incomingCreditModeStartTime;

        if (safeCashData.incomingCreditModeStartTime > 0 && block.timestamp > safeCashData.incomingCreditModeStartTime) safeCashData.mode = Mode.Credit;
    }

    /**
     * @notice Gets the pending withdrawal amount for a token
     * @dev Searches through the withdrawal request tokens array for the specified token
     * @param safe Address of the safe
     * @param token Address of the token to check
     * @return Amount of tokens pending withdrawal
     */
    function getPendingWithdrawalAmount(address safe, address token) public view returns (uint256) {
        SafeData memory safeData = cashModule.getData(safe);
        return _getPendingWithdrawalAmount(safeData, token);
    }

    /**
     * @notice Gets the pending withdrawal amount for a token from safe data
     * @dev Internal helper that searches through the withdrawal request tokens array
     * @param safeData Safe data structure containing the withdrawal requests
     * @param token Address of the token to check
     * @return Amount of tokens pending withdrawal
     */
    function _getPendingWithdrawalAmount(SafeData memory safeData, address token) internal pure returns (uint256) {
        uint256 len = safeData.pendingWithdrawalRequest.tokens.length;
        uint256 tokenIndex = len;
        for (uint256 i = 0; i < len;) {
            if (safeData.pendingWithdrawalRequest.tokens[i] == token) {
                tokenIndex = i;
                break;
            }
            unchecked {
                ++i;
            }
        }

        return tokenIndex != len ? safeData.pendingWithdrawalRequest.amounts[tokenIndex] : 0;
    }

    /**
     * @notice Gets the effective collateral amount for a specific token
     * @dev Returns balance minus pending withdrawals
     * @param safe Address of the safe
     * @param token Address of the collateral token to check
     * @return Effective collateral amount
     * @custom:throws NotACollateralToken if token is not a valid collateral token
     */
    function getUserCollateralForToken(address safe, address token) public view returns (uint256) {
        IDebtManager debtManager = cashModule.getDebtManager();

        if (!debtManager.isCollateralToken(token)) revert NotACollateralToken();
        uint256 balance = IERC20(token).balanceOf(safe);
        uint256 pendingWithdrawalAmount = getPendingWithdrawalAmount(safe, token);

        return balance - pendingWithdrawalAmount;
    }

    /**
     * @notice Gets all effective collateral balances for a safe
     * @dev Returns array of token addresses and their effective amounts (balance minus pending withdrawals)
     * @param safe Address of the safe
     * @return Array of token data with token addresses and effective amounts
     */
    function getUserTotalCollateral(address safe) public view returns (IDebtManager.TokenData[] memory) {
        IDebtManager debtManager = cashModule.getDebtManager();
        address[] memory collateralTokens = debtManager.getCollateralTokens();
        uint256 len = collateralTokens.length;
        IDebtManager.TokenData[] memory tokenAmounts = new IDebtManager.TokenData[](collateralTokens.length);
        uint256 m = 0;
        for (uint256 i = 0; i < len;) {
            uint256 balance = IERC20(collateralTokens[i]).balanceOf(safe);
            uint256 pendingWithdrawalAmount = getPendingWithdrawalAmount(safe, collateralTokens[i]);
            if (balance != 0) {
                balance = balance - pendingWithdrawalAmount;
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

        return tokenAmounts;
    }

    /**
     * @notice Calculate the amount that can be spent in credit mode
     * @dev Internal helper for maxCanSpend that handles credit mode calculations
     * @param debtManager The debt manager instance
     * @param safe The address of the safe
     * @param token The token address
     * @param safeData The safe data
     * @param amountToSubtract Amount of collateral to subtract for simulation
     * @return creditModeAmount The amount that can be spent in credit mode
     * @return isValid Whether the calculation was successful
     */
    function _calculateCreditModeAmount(IDebtManager debtManager, address safe, address token, SafeData memory safeData, uint256 amountToSubtract) internal view returns (uint256 creditModeAmount, bool isValid) {
        // Get collateral balance with token subtracted
        (IDebtManager.TokenData[] memory collateralTokenAmounts, string memory error) = _getCollateralBalanceWithTokenSubtracted(debtManager, safe, safeData, token, amountToSubtract);

        // Check for errors - short circuit to save gas
        if (bytes(error).length != 0 || collateralTokenAmounts.length == 0) {
            return (0, false);
        }

        // Get borrowing power and total borrowing
        (uint256 totalMaxBorrow, uint256 totalBorrowings) = debtManager.getBorrowingPowerAndTotalBorrowing(safe, collateralTokenAmounts);

        // Check if borrowings exceed max borrow
        if (totalBorrowings > totalMaxBorrow) {
            return (0, false);
        }

        // Calculate credit mode amount and round to 4 decimals in one operation
        return (((totalMaxBorrow - totalBorrowings) * 10 ** 4) / 10 ** 4, true);
    }

    /**
     * @notice Calculate the amount that can be spent in debit mode
     * @dev Internal helper for maxCanSpend that handles debit mode calculations
     * @param debtManager The debt manager instance
     * @param safe The address of the safe
     * @param token The token address
     * @param safeData The safe data
     * @return debitModeAmount The amount that can be spent in debit mode
     */
    function _calculateDebitModeAmount(IDebtManager debtManager, address safe, address token, SafeData memory safeData) internal view returns (uint256 debitModeAmount) {
        // Get effective balance - return early if zero
        uint256 effectiveBal = IERC20(token).balanceOf(safe) - _getPendingWithdrawalAmount(safeData, token);
        if (effectiveBal == 0) {
            return 0;
        }

        // Get collateral balance with token subtracted
        (IDebtManager.TokenData[] memory collateralTokenAmounts, string memory error) = _getCollateralBalanceWithTokenSubtracted(debtManager, safe, safeData, token, effectiveBal);

        // Check for errors - return early if invalid
        if (bytes(error).length != 0 || collateralTokenAmounts.length == 0) {
            return 0;
        }

        // Get borrowing power and total borrowing
        (uint256 totalMaxBorrow, uint256 totalBorrowings) = debtManager.getBorrowingPowerAndTotalBorrowing(address(0), collateralTokenAmounts);

        // Calculate debit mode amount based on borrowing status
        if (totalMaxBorrow < totalBorrowings) {
            uint256 deficit = totalBorrowings - totalMaxBorrow;
            uint80 ltv = debtManager.collateralTokenConfig(token).ltv;
            uint256 amountRequiredToCoverDebt = deficit.mulDiv(HUNDRED_PERCENT, ltv, Math.Rounding.Ceil);
            uint256 tokenValueInUsd = debtManager.convertCollateralTokenToUsd(token, effectiveBal);

            // Check if there's enough token value to cover debt
            if (tokenValueInUsd <= amountRequiredToCoverDebt) {
                return 0;
            }

            debitModeAmount = tokenValueInUsd - amountRequiredToCoverDebt;
        } else {
            debitModeAmount = debtManager.convertCollateralTokenToUsd(token, effectiveBal);
        }

        // Round to 4 decimals
        return (debitModeAmount * 10 ** 4) / 10 ** 4;
    }

    /**
     * @notice Gets collateral balances with a token amount subtracted
     * @dev Internal helper that calculates effective balances for spending simulation
     * @param debtManager Reference to the debt manager contract
     * @param safe Address of the EtherFi Safe
     * @param safeData Safe data structure containing mode and withdrawal requests
     * @param token Address of the token to subtract
     * @param amount Amount to subtract
     * @return tokenAmounts Array of token data with updated balances
     * @return error Error message if calculation fails
     */
    function _getCollateralBalanceWithTokenSubtracted(IDebtManager debtManager, address safe, SafeData memory safeData, address token, uint256 amount) internal view returns (IDebtManager.TokenData[] memory, string memory error) {
        address[] memory collateralTokens = debtManager.getCollateralTokens();
        uint256 len = collateralTokens.length;
        IDebtManager.TokenData[] memory tokenAmounts = new IDebtManager.TokenData[](collateralTokens.length);
        uint256 m = 0;
        for (uint256 i = 0; i < len;) {
            uint256 balance = IERC20(collateralTokens[i]).balanceOf(safe);
            uint256 pendingWithdrawalAmount = _getPendingWithdrawalAmount(safeData, collateralTokens[i]);
            if (balance != 0) {
                balance = balance - pendingWithdrawalAmount;
                if (safeData.mode == Mode.Debit && token == collateralTokens[i]) {
                    if (balance == 0 || balance < amount) return (new IDebtManager.TokenData[](0), "Insufficient effective balance after withdrawal to spend with debit mode");
                    balance = balance - amount;
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
}
