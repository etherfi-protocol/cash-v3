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
import { ArrayDeDupLib } from "../../libraries/ArrayDeDupLib.sol";

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
    using ArrayDeDupLib for address[];

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

        _disableInitializers();
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
     * @notice Checks if a spending transaction can be executed with multiple tokens
     * @dev In debit mode, allows spending multiple tokens; in credit mode, only one token
     * @param safe Address of the EtherFi Safe
     * @param txId Transaction identifier
     * @param tokens Array of addresses of the tokens to spend
     * @param amountsInUsd Array of amounts to spend in USD (must match tokens array length)
     * @return canSpend Boolean indicating if the spending is allowed
     * @return message Error message if spending is not allowed
     */
    function canSpend(address safe, bytes32 txId, address[] memory tokens,uint256[] memory amountsInUsd) public view returns (bool, string memory) {
        // Basic validation
        if (tokens.length == 0) return (false, "No tokens provided");
        if (tokens.length != amountsInUsd.length) return (false, "Tokens and amounts arrays length mismatch");
        if (cashModule.transactionCleared(safe, txId)) return (false, "Transaction already cleared");

        if (tokens.length > 1) tokens.checkDuplicates();
        
        // Check total spending amount
        uint256 totalSpendingInUsd = 0;
        for (uint256 i = 0; i < amountsInUsd.length; i++) {
            totalSpendingInUsd += amountsInUsd[i];
        }
        if (totalSpendingInUsd == 0) return (false, "Total amount zero in USD");
        
        // Validate mode and spending limits
        return _validateSpending(safe, tokens, amountsInUsd, totalSpendingInUsd);
    }

    function canSpendSingleToken(
        address safe, 
        bytes32 txId, 
        address[] calldata creditModeTokenPreferences, 
        address[] calldata debitModeTokenPreferences, 
        uint256 amountInUsd
    ) public view returns (Mode mode, address token, bool canSpendResult, string memory declineReason) {
        SafeData memory safeData = cashModule.getData(safe);
        if (safeData.incomingCreditModeStartTime != 0) mode = Mode.Credit;
        mode = safeData.mode;
        
        address[] memory tokenPreferences = mode == Mode.Debit ? debitModeTokenPreferences : creditModeTokenPreferences;
        
        if (tokenPreferences.length == 0) return (mode, address(0), false, "No token preferences provided");
        if (amountInUsd == 0) return (mode, tokenPreferences[0], false, "Amount cannot be zero");
        if (cashModule.transactionCleared(safe, txId)) return (mode, tokenPreferences[0], false, "Transaction already cleared");
        
        (token, canSpendResult, declineReason) = _checkTokenPreferences(safe, txId, tokenPreferences, amountInUsd);
        
        return (mode, token, canSpendResult, declineReason);
    }

    function _checkTokenPreferences(
        address safe,
        bytes32 txId,
        address[] memory tokenPreferences,
        uint256 amountInUsd
    ) internal view returns (address token, bool canSpendResult, string memory declineReason) {
        uint256[] memory amountsInUsd = new uint256[](1);
        amountsInUsd[0] = amountInUsd;
        address[] memory singleToken = new address[](1);
        
        string memory firstError;
        
        for (uint256 i = 0; i < tokenPreferences.length; ) {
            singleToken[0] = tokenPreferences[i];
            
            (bool success, string memory error) = canSpend(safe, txId, singleToken, amountsInUsd);
            if (i == 0) firstError = error;
            
            if (success) return (tokenPreferences[i], true, "");
            
            unchecked {
                ++i;
            }
        }
        
        return (tokenPreferences[0], false, firstError);
    }

    /**
     * @notice Validates mode, limits and completes spending checks
     */
    function _validateSpending(address safe, address[] memory tokens, uint256[] memory amountsInUsd, uint256 totalSpendingInUsd) internal view returns (bool, string memory) {
        IDebtManager debtManager = cashModule.getDebtManager();
        SafeData memory safeData = cashModule.getData(safe);
        
        // Update mode if necessary
        if (safeData.incomingCreditModeStartTime != 0) safeData.mode = Mode.Credit;
        
        // In Credit mode, only one token is allowed
        if (safeData.mode == Mode.Credit && tokens.length > 1) return (false, "Only one token allowed in Credit mode");
        
        // Check spending limit
        (bool withinLimit, string memory limitMessage) = safeData.spendingLimit.canSpend(totalSpendingInUsd);
        if (!withinLimit) return (false, limitMessage);
        
        // Validate tokens
        return _processTokensAndMode(safe, tokens, amountsInUsd, totalSpendingInUsd, debtManager, safeData);
    }

    /**
     * @notice Process tokens and check mode-specific rules
     */
    function _processTokensAndMode(address safe, address[] memory tokens, uint256[] memory amountsInUsd, uint256 totalSpendingInUsd, IDebtManager debtManager, SafeData memory safeData) internal view returns (bool, string memory) {
        // Convert USD to token amounts and validate each token
        uint256[] memory amounts = new uint256[](tokens.length);
        
        for (uint256 i = 0; i < tokens.length; i++) {
            // Check if token is supported
            if (!debtManager.isBorrowToken(tokens[i])) {
                return (false, "Not a supported stable token");
            }
            
            // Convert USD to token amount
            amounts[i] = debtManager.convertUsdToCollateralToken(tokens[i], amountsInUsd[i]);
            
            // In Debit mode, check each token's balance
            if (safeData.mode == Mode.Debit && IERC20(tokens[i]).balanceOf(safe) < amounts[i]) {
                return (false, "Insufficient token balance for debit mode spending");
            }
        }
        
        // Check mode-specific conditions
        if (safeData.mode == Mode.Credit) {
            return _creditModeCheck(safe, tokens, amounts, totalSpendingInUsd, debtManager, safeData);
        } else {
            return _debitModeCheck(safe, tokens, amounts, debtManager, safeData);
        }
    }

    /**
     * @notice Credit mode specific checks
     */
    function _creditModeCheck(address safe, address[] memory tokens, uint256[] memory amounts, uint256 totalSpendingInUsd, IDebtManager debtManager, SafeData memory safeData) internal view returns (bool, string memory) {
        // credit mode should only have 1 token
        // Check if debt manager has enough liquidity
        if (IERC20(tokens[0]).balanceOf(address(debtManager)) < amounts[0]) return (false, "Insufficient liquidity in debt manager to cover the loan");
        
        // Get collateral balances with pending withdrawals factored in
        (IDebtManager.TokenData[] memory collateralTokenAmounts, string memory error) = _getCollateralBalanceWithTokensSubtracted(debtManager, safe, safeData, tokens, amounts);
        
        if (bytes(error).length != 0) return (false, error);
        
        return _checkBorrowingPower(safe, collateralTokenAmounts, totalSpendingInUsd, debtManager);
    }

    /**
     * @notice Debit mode specific checks
     */
    function _debitModeCheck(address safe, address[] memory tokens, uint256[] memory amounts, IDebtManager debtManager, SafeData memory safeData) internal view returns (bool, string memory) {
        // Simulate the spending of multiple tokens
        (IDebtManager.TokenData[] memory collateralTokenAmounts, string memory error) =  _getCollateralBalanceWithTokensSubtracted(debtManager, safe, safeData, tokens, amounts);
        
        if (bytes(error).length != 0) return (false, error);
        
        // Check if spending would cause collateral ratio issues
        (uint256 totalMaxBorrow, uint256 totalBorrowings) = debtManager.getBorrowingPowerAndTotalBorrowing(safe, collateralTokenAmounts);
        
        if (totalBorrowings > totalMaxBorrow) return (false, "Borrowings greater than max borrow after spending");
        
        return (true, "");
    }

    /**
     * @notice Check borrowing power for credit mode
     */
    function _checkBorrowingPower(address safe, IDebtManager.TokenData[] memory collateralTokenAmounts, uint256 totalSpendingInUsd, IDebtManager debtManager) internal view returns (bool, string memory) {
        (uint256 totalMaxBorrow, uint256 totalBorrowings) = debtManager.getBorrowingPowerAndTotalBorrowing(safe, collateralTokenAmounts);
        
        if (totalBorrowings > totalMaxBorrow) {
            return (false, "Borrowings greater than max borrow");
        }
        
        if (totalSpendingInUsd > totalMaxBorrow - totalBorrowings) {
            return (false, "Insufficient borrowing power");
        }
        
        return (true, "");
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
        safeData.mode = Mode.Credit;
        (returnAmtInCreditModeUsd, isValidCredit) = _calculateCreditModeAmount(debtManager, safe, token, safeData, 0);
        if (!isValidCredit) {
            return (0, 0, spendingLimitAllowance);
        }

        safeData.mode = Mode.Debit;
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
        safeCashData.totalCashbackEarnedInUsd = safeData.totalCashbackEarnedInUsd;
        safeCashData.incomingCreditModeStartTime = safeData.incomingCreditModeStartTime;
        safeCashData.mode = safeData.mode;
        
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
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountToSubtract;

        (IDebtManager.TokenData[] memory collateralTokenAmounts, string memory error) = _getCollateralBalanceWithTokensSubtracted(debtManager, safe, safeData, tokens, amounts);

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

        // Calculate credit mode amount  
        return (totalMaxBorrow - totalBorrowings, true);
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
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        uint256 effectiveBal = IERC20(token).balanceOf(safe) - getPendingWithdrawalAmount(safe, token);
        amounts[0] = effectiveBal;

        // Get collateral balance with token subtracted
        (IDebtManager.TokenData[] memory collateralTokenAmounts, string memory error) = _getCollateralBalanceWithTokensSubtracted(debtManager, safe, safeData, tokens, amounts);

        // Check for errors - return early if invalid
        if (bytes(error).length != 0 || collateralTokenAmounts.length == 0) {
            return 0;
        }

        // Get borrowing power and total borrowing
        (uint256 totalMaxBorrow, uint256 totalBorrowings) = debtManager.getBorrowingPowerAndTotalBorrowing(address(safe), collateralTokenAmounts);

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

        return debitModeAmount;
    }

    /**
     * @notice Gets collateral balances with multiple token amounts subtracted
     * @dev Internal helper for simulating multi-token debit spending
     * @param debtManager Reference to the debt manager contract
     * @param safe Address of the EtherFi Safe
     * @param safeData Safe data structure containing withdrawal requests
     * @param tokens Array of addresses of tokens to subtract
     * @param amounts Array of amounts to subtract (must match tokens array)
     * @return tokenAmounts Array of token data with updated balances
     * @return error Error message if calculation fails
     */
    function _getCollateralBalanceWithTokensSubtracted(
        IDebtManager debtManager,
        address safe,
        SafeData memory safeData,
        address[] memory tokens,
        uint256[] memory amounts
    ) internal view returns (IDebtManager.TokenData[] memory, string memory) {
        address[] memory collateralTokens = debtManager.getCollateralTokens();
        uint256 len = collateralTokens.length;
        IDebtManager.TokenData[] memory tokenAmounts = new IDebtManager.TokenData[](collateralTokens.length);
        uint256 m = 0;
        
        for (uint256 i = 0; i < len;) {
            uint256 balance = IERC20(collateralTokens[i]).balanceOf(safe);
            uint256 pendingWithdrawalAmount = _getPendingWithdrawalAmount(safeData, collateralTokens[i]);
            
            if (balance != 0) {
                balance = balance - pendingWithdrawalAmount;

                if (safeData.mode == Mode.Debit) {
                    // Check if this token is in the tokens array
                    for (uint256 j = 0; j < tokens.length; j++) {
                        if (collateralTokens[i] == tokens[j]) {
                            if (balance < amounts[j]) {
                                return (
                                    new IDebtManager.TokenData[](0), 
                                    "Insufficient effective balance after withdrawal to spend with debit mode"
                                );
                            }
                            balance = balance - amounts[j];
                            break;
                        }
                    }
                }
                
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
        
        return (tokenAmounts, "");
    }
}
