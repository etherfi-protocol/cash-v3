// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";
import { ArrayDeDupLib } from "../../libraries/ArrayDeDupLib.sol";

import { ICashModule, Mode, SafeCashData, SafeData, WithdrawalRequest, DebitModeMaxSpend } from "../../interfaces/ICashModule.sol";
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
    using ArrayDeDupLib for address[];
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
    /// @notice Error thrown when trying to use a token that is not on the borrow whitelist
    error NotABorrowToken();

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
        if (safeData.incomingModeStartTime != 0) mode = safeData.incomingMode;
        else mode = safeData.mode;
        
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

        Mode mode = safeData.mode; 
        // Update mode if necessary
        if (safeData.incomingModeStartTime != 0) mode = safeData.incomingMode;

        // In Credit mode, only one token is allowed
        if (mode == Mode.Credit && tokens.length > 1) return (false, "Only one token allowed in Credit mode");
        
        // Check spending limit
        (bool withinLimit, string memory limitMessage) = safeData.spendingLimit.canSpend(totalSpendingInUsd);
        if (!withinLimit) return (false, limitMessage);
        
        // Validate tokens
        return _processTokensAndMode(safe, tokens, amountsInUsd, totalSpendingInUsd, debtManager, safeData, mode);
    }

    /**
     * @notice Process tokens and check mode-specific rules
     */
    function _processTokensAndMode(address safe, address[] memory tokens, uint256[] memory amountsInUsd, uint256 totalSpendingInUsd, IDebtManager debtManager, SafeData memory safeData, Mode mode) internal view returns (bool, string memory) {
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
            if (mode == Mode.Debit && IERC20(tokens[i]).balanceOf(safe) < amounts[i]) {
                return (false, "Insufficient token balance for debit mode spending");
            }
        }
        
        // Check mode-specific conditions
        if (mode == Mode.Credit) {
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
        (IDebtManager.TokenData[] memory collateralTokenAmounts, string memory error) = _getCollateralBalanceWithTokensSubtracted(debtManager, safe, safeData, tokens, amounts, Mode.Credit);
        
        if (bytes(error).length != 0) return (false, error);
        
        return _checkBorrowingPower(safe, collateralTokenAmounts, totalSpendingInUsd, debtManager);
    }

    /**
     * @notice Debit mode specific checks
     */
    function _debitModeCheck(address safe, address[] memory tokens, uint256[] memory amounts, IDebtManager debtManager, SafeData memory safeData) internal view returns (bool, string memory) {
        // Simulate the spending of multiple tokens
        (IDebtManager.TokenData[] memory collateralTokenAmounts, string memory error) =  _getCollateralBalanceWithTokensSubtracted(debtManager, safe, safeData, tokens, amounts, Mode.Debit);
        
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
     * @notice Gets comprehensive cash data for a Safe
     * @dev Aggregates data from multiple sources including DebtManager and CashModule
     * @param safe Address of the EtherFi Safe
     * @param debtServiceTokenPreference Optional ordered array of borrow tokens for debit calculations.
     *                                   If empty, uses all available borrow tokens from DebtManager.
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
     *   - debitMaxSpend: Detailed breakdown of debit mode spending limits per token
     *   - spendingLimitAllowance: Remaining spending limit allowance
     *   - totalCashbackEarnedInUsd: Running total of all cashback earned
     *   - incomingModeStartTime: Timestamp when Credit mode takes effect
     */
    function getSafeCashData(address safe, address[] memory debtServiceTokenPreference) external view returns (SafeCashData memory safeCashData) {
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

        safeCashData.spendingLimitAllowance = safeData.spendingLimit.maxCanSpend();
        
        safeCashData.creditMaxSpend = getMaxSpendCredit(safe);

        if (debtServiceTokenPreference.length == 0) safeCashData.debitMaxSpend = getMaxSpendDebit(safe, debtManager.getBorrowTokens());
        else safeCashData.debitMaxSpend = getMaxSpendDebit(safe, debtServiceTokenPreference);

        safeCashData.totalCashbackEarnedInUsd = safeData.totalCashbackEarnedInUsd;
        safeCashData.incomingModeStartTime = safeData.incomingModeStartTime;
        safeCashData.mode = safeData.mode;

        if (safeCashData.incomingModeStartTime > 0 && block.timestamp > safeCashData.incomingModeStartTime) safeCashData.mode = safeData.incomingMode;
    }

    /**
     * @notice Calculates the maximum amounts that can be spent in debit mode across multiple tokens
     * @dev Analyzes the safe's collateral health to determine spendable amounts for each token while
     *      maintaining solvency. When underwater (borrowings > max borrow), tokens are consumed in 
     *      preference order to restore health before allowing spending. The function strictly respects 
     *      token preference order.
     * 
     * @param safe Address of the EtherFi Safe to calculate spending limits for
     * @param debtServiceTokenPreference Ordered array of borrow token addresses. Order determines 
     *                                   priority for deficit coverage - earlier tokens are used first.
     *                                   Must contain only valid borrow tokens (stablecoins).
     * 
     * @return DebitModeMaxSpend
     *  - spendableTokens Array of token addresses (mirrors input debtServiceTokenPreference)
     *  - spendableAmounts Array of maximum spendable amounts per token in native token units.
     *                          Accounts for pending withdrawals. Zero for tokens needed as collateral.
     *  - amountsInUsd Array of spendable amounts converted to USD values. Corresponds 1:1 with
     *                      spendableAmounts. Zero for tokens reserved for collateral.
     *  - totalSpendableInUsd Aggregate USD value spendable across all tokens
     * 
     * @custom:reverts NotABorrowToken if any token in debtServiceTokenPreference is not whitelisted
     * @custom:reverts DuplicateElementFound if debtServiceTokenPreference contains duplicate addresses
     * 
     * @custom:example Healthy Position
     * // Safe: $1000 USDC, $500 USDT, no borrowings
     * // Returns: spendableAmounts=[1000e6, 500e6], amountsInUsd=[1000e18, 500e18], total=$1500
     * 
     * @custom:example Underwater Position  
     * // Safe: 1 weETH ($3000, 50% LTV), $1000 USDC (80% LTV), $500 USDT (80% LTV), $1700 borrowings
     * // $1500 borrowing covered by weETH
     * // Deficit: $200, needs $250 collateral at 80% LTV from USDC (first preference)
     * // Returns: spendableAmounts=[750e6, 500e6], amountsInUsd=[750e18, 500e18], total=$1250
     * 
     * @custom:edge-cases
     * - Empty token preference array returns empty results
     * - Zero effective balances after withdrawals are handled correctly  
     * - Tokens with zero value break the preference chain for subsequent tokens
     * - If deficit cannot be covered, returns empty arrays and zero total
     * 
     * @custom:security 
     * - Read-only view function with no state modifications
     * - Conservative calculations ensure safe remains solvent after spending
     * - Pending withdrawals reduce spendable amounts to prevent double-spending
     */
    function getMaxSpendDebit(address safe, address[] memory debtServiceTokenPreference) public view returns (DebitModeMaxSpend memory) {
        uint256 len = debtServiceTokenPreference.length;
        if (len == 0) return DebitModeMaxSpend(new address[](0), new uint256[](0), new uint256[](0), 0);
        if (len > 1) debtServiceTokenPreference.checkDuplicates();

        IDebtManager debtManager = cashModule.getDebtManager();
        SafeData memory safeData = cashModule.getData(safe);

        // Calculate token values
        (uint256[] memory effectiveBalances, uint256[] memory tokenValuesInUsd, uint256 totalValueInUsd) = _calculateTokenValues(debtManager, safe, debtServiceTokenPreference, len);

        if (totalValueInUsd == 0) return DebitModeMaxSpend(debtServiceTokenPreference, new uint256[](len), new uint256[](len), 0);

        // Check collateral after theoretical spending all debit tokens
        (IDebtManager.TokenData[] memory collateralTokenAmounts, string memory error) = _getCollateralBalanceWithTokensSubtracted(debtManager, safe, safeData, debtServiceTokenPreference, effectiveBalances, Mode.Debit);

        if (bytes(error).length != 0) return DebitModeMaxSpend(new address[](0), new uint256[](0), new uint256[](0), 0);

        // Get borrowing power
        (uint256 totalMaxBorrow, uint256 totalBorrowings) = debtManager.getBorrowingPowerAndTotalBorrowing(safe, collateralTokenAmounts);
        
        // Healthy position - can spend all effective balances
        if (totalBorrowings == 0 || totalMaxBorrow >= totalBorrowings) return DebitModeMaxSpend(debtServiceTokenPreference, effectiveBalances, tokenValuesInUsd, totalValueInUsd);
        
        // Underwater position - need to calculate deficit coverage
        return _processUnderwaterPosition(debtServiceTokenPreference, tokenValuesInUsd, effectiveBalances, debtManager, totalBorrowings - totalMaxBorrow);
    }

    function _calculateTokenValues(IDebtManager debtManager,address safe,address[] memory tokens,uint256 len) internal view returns (uint256[] memory effectiveBalances,uint256[] memory tokenValuesInUsd,uint256 totalValueInUsd) {
        effectiveBalances = new uint256[](len);
        tokenValuesInUsd = new uint256[](len);

        for (uint256 i = 0; i < len;) {
            address token = tokens[i];
            if (!debtManager.isBorrowToken(token)) revert NotABorrowToken();
            
            effectiveBalances[i] = IERC20(token).balanceOf(safe) - getPendingWithdrawalAmount(safe, token);
            
            if (effectiveBalances[i] > 0) {  
                tokenValuesInUsd[i] = debtManager.convertCollateralTokenToUsd(token, effectiveBalances[i]);
                totalValueInUsd += tokenValuesInUsd[i];
            }
            
            unchecked { ++i; }
        }
    }

    function _processUnderwaterPosition(address[] memory tokens,uint256[] memory tokenValuesInUsd,uint256[] memory effectiveBalances,IDebtManager debtManager,uint256 deficit) internal view returns (DebitModeMaxSpend memory) {
        uint256 len = tokens.length;
        
        // Cover deficit and calculate spendable amounts
        (uint256[] memory spendableAmounts, uint256[] memory spendableUsdValues, uint256 remainingDeficit, uint256 lastProcessedIndex) = _coverDeficitAndCalculateSpendable(tokens, tokenValuesInUsd, debtManager, deficit);
        
        // If deficit remains uncovered, can't spend anything
        if (remainingDeficit > 0) return DebitModeMaxSpend(new address[](0), new uint256[](0), new uint256[](0), 0);
        
        // Add remaining tokens and calculate total
        uint256 totalSpendableUsd = _addRemainingTokens(spendableAmounts,spendableUsdValues,effectiveBalances,tokenValuesInUsd,lastProcessedIndex,len);
        
        return DebitModeMaxSpend(tokens, spendableAmounts, spendableUsdValues, totalSpendableUsd);
    }

    function _coverDeficitAndCalculateSpendable(address[] memory tokens,uint256[] memory tokenValuesInUsd,IDebtManager debtManager,uint256 deficit) internal view returns (uint256[] memory spendableAmounts,uint256[] memory spendableUsdValues,uint256 remainingDeficit,uint256 lastProcessedIndex) {
        uint256 len = tokens.length;
        spendableAmounts = new uint256[](len);
        spendableUsdValues = new uint256[](len);
        remainingDeficit = deficit;
        
        for (uint256 i = 0; i < len && remainingDeficit > 0;) {
            uint256 tokenValue = tokenValuesInUsd[i];
            
            if (tokenValue > 0) {
                (uint256 spendableAmount, uint256 spendableUsd, uint256 deficitCovered) = _processTokenForDeficit(tokens[i], tokenValue, remainingDeficit, debtManager);
                
                spendableAmounts[i] = spendableAmount;
                spendableUsdValues[i] = spendableUsd;
                remainingDeficit -= deficitCovered;
                lastProcessedIndex = i;
                
                if (remainingDeficit == 0) break;
            }
            
            unchecked { ++i; }
        }
    }

    function _processTokenForDeficit(address token,uint256 tokenValue,uint256 remainingDeficit,IDebtManager debtManager) internal view returns (uint256 spendableAmount,uint256 spendableUsd,uint256 deficitCovered) {
        uint80 ltv = debtManager.collateralTokenConfig(token).ltv;
        uint256 borrowingPower = tokenValue.mulDiv(ltv, HUNDRED_PERCENT, Math.Rounding.Floor);
        
        if (borrowingPower >= remainingDeficit) {
            // This token can cover the remaining deficit
            uint256 collateralNeeded = remainingDeficit.mulDiv(HUNDRED_PERCENT, ltv, Math.Rounding.Ceil);
            spendableUsd = tokenValue - collateralNeeded;
            spendableAmount = debtManager.convertUsdToCollateralToken(token, spendableUsd);
            deficitCovered = remainingDeficit;
        } else {
            // This token can't cover deficit alone - use it all for collateral
            spendableAmount = 0;
            spendableUsd = 0;
            deficitCovered = borrowingPower;
        }
    }

    function _addRemainingTokens(uint256[] memory spendableAmounts,uint256[] memory spendableUsdValues,uint256[] memory effectiveBalances,uint256[] memory tokenValuesInUsd,uint256 lastProcessedIndex,uint256 len) internal pure returns (uint256 totalSpendableUsd) {
        // Sum up what we can spend from deficit coverage
        for (uint256 i = 0; i <= lastProcessedIndex;) {
            totalSpendableUsd += spendableUsdValues[i];
            unchecked { ++i; }
        }
        
        // Add remaining tokens that weren't needed for deficit
        for (uint256 i = lastProcessedIndex + 1; i < len;) {
            if (tokenValuesInUsd[i] > 0) {
                spendableAmounts[i] = effectiveBalances[i];
                spendableUsdValues[i] = tokenValuesInUsd[i];
                totalSpendableUsd += tokenValuesInUsd[i];
            }
            unchecked { ++i; }
        }
    }

    /**
     * @notice Calculates the maximum amount that can be spent in credit mode
     * @param safe Address of the EtherFi Safe
     * @return returnAmtInCreditModeUsd Maximum amount that can be spent in credit mode (USD)
     */
    function getMaxSpendCredit(address safe) public view returns (uint256 returnAmtInCreditModeUsd) {
        // Get debt manager and safe data once to avoid multiple calls
        IDebtManager debtManager = cashModule.getDebtManager();
        SafeData memory safeData = cashModule.getData(safe);

        bool isValidCredit;

        (returnAmtInCreditModeUsd, isValidCredit) = _calculateCreditModeAmount(debtManager, safe, safeData);
        if (!isValidCredit) return 0;
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

    /**
     * @notice Calculate the amount that can be spent in credit mode
     * @dev Internal helper that handles credit mode calculations
     * @param debtManager The debt manager instance
     * @param safe The address of the safe
     * @param safeData The safe data
     * @return creditModeAmount The amount that can be spent in credit mode
     * @return isValid Whether the calculation was successful
     */
    function _calculateCreditModeAmount(IDebtManager debtManager, address safe, SafeData memory safeData) internal view returns (uint256 creditModeAmount, bool isValid) {
        (IDebtManager.TokenData[] memory collateralTokenAmounts, string memory error) = _getCollateralBalanceWithTokensSubtracted(debtManager, safe, safeData, new address[](0), new uint256[](0), Mode.Credit);

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
        uint256[] memory amounts,
        Mode mode
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

                if (mode == Mode.Debit) {
    
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
