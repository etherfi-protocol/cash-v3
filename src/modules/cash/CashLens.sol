// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ArrayDeDupLib } from "../../libraries/ArrayDeDupLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { DebitModeMaxSpend, ICashModule, Mode, SafeCashData, SafeData } from "../../interfaces/ICashModule.sol";
import { IDebtManager } from "../../interfaces/IDebtManager.sol";
import { IEtherFiDataProvider } from "../../interfaces/IEtherFiDataProvider.sol";
import { IGateway } from "../../interfaces/IGateway.sol";
import { IPriceProvider } from "../../interfaces/IPriceProvider.sol";
import { SpendingLimit, SpendingLimitLib } from "../../libraries/SpendingLimitLib.sol";
import { UpgradeableProxy } from "../../utils/UpgradeableProxy.sol";

/**
 * @title CashLens
 * @notice Read-only contract providing views into a Safe's cash state
 * @dev Reads the Safe's position from the Aave gateway and the supported-token list from DebtManager.
 *      Credit capacity comes straight from Aave. Debit spendable is the raw Safe balance plus the
 *      withdrawable supplied amount; when the Safe has debt, the withdrawable part is capped by the
 *      borrowing headroom (collateral weighted by LTV, minus debt) so the leftover position keeps
 *      debt within its borrowing power. USD is 6 decimals throughout, matching PriceProvider.DECIMALS;
 *      the gateway returns its USD aggregates in the same scale.
 *
 *      The debit cap uses LTV, which is stricter than the sandwich's liquidation-threshold health gate
 *      (ModuleGatewaySandwich.minHealthFactor) only while minHealthFactor <= liqThreshold / LTV for every
 *      collateral. Keep that invariant at deploy time, or CashLens can over-report a debit spend that the
 *      sandwich then reverts on withdraw.
 * @author ether.fi
 */
contract CashLens is UpgradeableProxy {
    using SpendingLimitLib for SpendingLimit;
    using ArrayDeDupLib for address[];

    /// @notice Reference to the deployed CashModule contract
    ICashModule public immutable cashModule;
    /// @notice Reference to the deployed EtherFiDataProvider contract
    IEtherFiDataProvider public immutable dataProvider;
    /// @notice Reference to the Aave gateway that holds the Safe's position
    IGateway public immutable gateway;

    /// @notice Percentage denominator (100e18 = 100%), matching the gateway's ltv scale and DebtManager's CollateralTokenConfig.ltv
    uint256 internal constant HUNDRED_PERCENT = 100e18;

    /// @notice Error thrown when trying to use a token that is not on the collateral whitelist
    error NotACollateralToken();
    /// @notice Error thrown when trying to use a token that is not on the borrow whitelist
    error NotABorrowToken();

    /**
     * @notice Initializes the CashLens contract with its dependencies
     * @param _cashModule Address of the deployed CashModule contract
     * @param _dataProvider Address of the deployed EtherFiDataProvider contract
     * @param _gateway Address of the Aave gateway
     */
    constructor(address _cashModule, address _dataProvider, address _gateway) {
        cashModule = ICashModule(_cashModule);
        dataProvider = IEtherFiDataProvider(_dataProvider);
        gateway = IGateway(_gateway);

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
        return cashModule.getData(safe).spendingLimit.getCurrentLimit();
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
    function canSpend(address safe, bytes32 txId, address[] memory tokens, uint256[] memory amountsInUsd) public view returns (bool, string memory) {
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

    function canSpendSingleToken(address safe, bytes32 txId, address[] calldata creditModeTokenPreferences, address[] calldata debitModeTokenPreferences, uint256 amountInUsd) public view returns (Mode mode, address token, bool canSpendResult, string memory declineReason) {
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

    function _checkTokenPreferences(address safe, bytes32 txId, address[] memory tokenPreferences, uint256 amountInUsd) internal view returns (address token, bool canSpendResult, string memory declineReason) {
        uint256[] memory amountsInUsd = new uint256[](1);
        amountsInUsd[0] = amountInUsd;
        address[] memory singleToken = new address[](1);

        string memory firstError;

        for (uint256 i = 0; i < tokenPreferences.length;) {
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

    /// @notice Validates mode and spending limits, then runs the mode-specific check
    function _validateSpending(address safe, address[] memory tokens, uint256[] memory amountsInUsd, uint256 totalSpendingInUsd) internal view returns (bool, string memory) {
        SafeData memory safeData = cashModule.getData(safe);

        Mode mode = safeData.mode;
        // Update mode if necessary
        if (safeData.incomingModeStartTime != 0) mode = safeData.incomingMode;

        // In Credit mode, only one token is allowed
        if (mode == Mode.Credit && tokens.length > 1) return (false, "Only one token allowed in Credit mode");

        // Check spending limit
        (bool withinLimit, string memory limitMessage) = safeData.spendingLimit.canSpend(totalSpendingInUsd);
        if (!withinLimit) {
            return (false, limitMessage);
        }

        if (mode == Mode.Credit) {
            return _creditCheck(safe, tokens[0], totalSpendingInUsd, safeData);
        }
        return _debitCheck(safe, tokens, amountsInUsd, safeData);
    }

    /// @notice Credit mode check: the spend must fit the Aave borrowing capacity (net of pending withdrawals) and the reserve's liquidity
    function _creditCheck(address safe, address token, uint256 totalSpendingInUsd, SafeData memory safeData) internal view returns (bool, string memory) {
        if (!cashModule.getDebtManager().isBorrowToken(token)) {
            return (false, "Not a supported stable token");
        }

        if (gateway.availableCash(token) < _fromUsd(token, totalSpendingInUsd)) {
            return (false, "Insufficient liquidity in debt manager to cover the loan");
        }

        // Pending withdrawals will leave the position, so discount their borrowing power up front
        uint256 pending = _pendingWithdrawalHeadroom(safeData);
        uint256 capacityUsd = gateway.getAccountData(safe).availableBorrowsUsd;
        capacityUsd = capacityUsd > pending ? capacityUsd - pending : 0;
        if (totalSpendingInUsd > capacityUsd) {
            return (false, "Insufficient borrowing power");
        }

        return (true, "");
    }

    /// @notice Debit mode check: each token's spendable amount must cover its share of the spend, threading the borrowing headroom across tokens
    function _debitCheck(address safe, address[] memory tokens, uint256[] memory amountsInUsd, SafeData memory safeData) internal view returns (bool, string memory) {
        IDebtManager debtManager = cashModule.getDebtManager();
        IGateway.AccountData memory account = gateway.getAccountData(safe);
        bool hasDebt = account.debtUsd != 0;
        // Net of pending withdrawals, which will leave the position and reduce its borrowing power
        uint256 borrowHeadroom = _netBorrowHeadroom(account, safeData);

        for (uint256 i = 0; i < tokens.length; i++) {
            if (!debtManager.isBorrowToken(tokens[i])) {
                return (false, "Not a supported stable token");
            }

            uint256 needed = _fromUsd(tokens[i], amountsInUsd[i]);
            uint256 raw = IERC20(tokens[i]).balanceOf(safe);
            uint256 available = raw + _withdrawableSupplied(safe, tokens[i], borrowHeadroom, hasDebt);
            if (available < needed) {
                return (false, "Insufficient token balance for debit mode spending");
            }
            // available - pending < needed, written as an addition so a pending larger than available declines instead of underflowing
            if (available < _getPendingWithdrawalAmount(safeData, tokens[i]) + needed) {
                return (false, "Insufficient effective balance after withdrawal to spend with debit mode");
            }

            // Only the supplied portion (raw is spent first) consumes the borrowing headroom for later tokens
            if (hasDebt) {
                uint256 usedSupplied = needed > raw ? needed - raw : 0;
                uint256 used = _headroomConsumed(tokens[i], usedSupplied);
                borrowHeadroom = borrowHeadroom > used ? borrowHeadroom - used : 0;
            }
        }

        return (true, "");
    }

    /**
     * @notice Gets comprehensive cash data for a Safe
     * @dev Aggregates the Safe's Aave position (via the gateway) with its CashModule configuration
     * @param safe Address of the EtherFi Safe
     * @param debtServiceTokenPreference Optional ordered array of borrow tokens for debit calculations.
     *                                   If empty, uses all available borrow tokens.
     * @return Comprehensive data structure containing:
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
    function getSafeCashData(address safe, address[] memory debtServiceTokenPreference) external view returns (SafeCashData memory) {
        IDebtManager debtManager = cashModule.getDebtManager();
        IPriceProvider priceProvider = IPriceProvider(dataProvider.getPriceProvider());
        SafeData memory safeData = cashModule.getData(safe);
        IGateway.AccountData memory account = gateway.getAccountData(safe);

        SafeCashData memory data;

        address[] memory collateralTokens = debtManager.getCollateralTokens();
        address[] memory borrowTokens = debtManager.getBorrowTokens();

        data.collateralBalances = _suppliedBalances(safe, collateralTokens);
        data.borrows = _debtBalances(safe, borrowTokens);
        data.totalCollateral = account.collateralUsd;
        data.totalBorrow = account.debtUsd;
        // Gross borrowing power (collateral weighted by LTV), matching DebtManager's getMaxBorrowAmount: headroom plus current debt
        data.maxBorrow = account.availableBorrowsUsd + account.debtUsd;

        uint256 len = collateralTokens.length;
        data.tokenPrices = new IDebtManager.TokenData[](len);
        for (uint256 i = 0; i < len;) {
            data.tokenPrices[i].token = collateralTokens[i];
            data.tokenPrices[i].amount = priceProvider.price(collateralTokens[i]);
            unchecked {
                ++i;
            }
        }

        data.withdrawalRequest = safeData.pendingWithdrawalRequest;
        data.spendingLimitAllowance = safeData.spendingLimit.maxCanSpend();
        data.creditMaxSpend = getMaxSpendCredit(safe);

        if (debtServiceTokenPreference.length == 0) {
            data.debitMaxSpend = getMaxSpendDebit(safe, borrowTokens);
        } else {
            data.debitMaxSpend = getMaxSpendDebit(safe, debtServiceTokenPreference);
        }

        data.totalCashbackEarnedInUsd = safeData.totalCashbackEarnedInUsd;
        data.incomingModeStartTime = safeData.incomingModeStartTime;
        data.mode = safeData.mode;
        if (data.incomingModeStartTime > 0 && block.timestamp > data.incomingModeStartTime) {
            data.mode = safeData.incomingMode;
        }

        return data;
    }

    /**
     * @notice Calculates the maximum amounts that can be spent in debit mode across multiple tokens
     * @dev Each token's spendable amount is its raw Safe balance plus the withdrawable supplied amount,
     *      minus any pending withdrawal. When the Safe has debt, the withdrawable supplied amount is capped
     *      by the borrowing headroom (collateral weighted by LTV, minus debt), threaded across the
     *      preference order so each token only spends the headroom the earlier ones left. The headroom also
     *      excludes what pending withdrawals will consume; a token that has both a pending withdrawal and debt
     *      is treated conservatively, since its pending is netted from both its own amount and the headroom.
     * @param safe Address of the EtherFi Safe
     * @param debtServiceTokenPreference Ordered array of borrow token addresses (stablecoins). Order is
     *                                   preserved in the result.
     * @return DebitModeMaxSpend with:
     *   - spendableTokens: token addresses, mirrors debtServiceTokenPreference
     *   - spendableAmounts: max spendable per token in native units, after pending withdrawals
     *   - amountsInUsd: those amounts in USD, 1:1 with spendableAmounts
     *   - totalSpendableInUsd: aggregate USD value spendable across all tokens
     * @custom:reverts NotABorrowToken if any token in debtServiceTokenPreference is not whitelisted
     * @custom:reverts DuplicateElementFound if debtServiceTokenPreference contains duplicate addresses
     */
    function getMaxSpendDebit(address safe, address[] memory debtServiceTokenPreference) public view returns (DebitModeMaxSpend memory) {
        uint256 len = debtServiceTokenPreference.length;
        if (len == 0) return DebitModeMaxSpend(new address[](0), new uint256[](0), new uint256[](0), 0);
        if (len > 1) debtServiceTokenPreference.checkDuplicates();

        IDebtManager debtManager = cashModule.getDebtManager();
        SafeData memory safeData = cashModule.getData(safe);

        bool hasDebt;
        uint256 borrowHeadroom;
        {
            IGateway.AccountData memory account = gateway.getAccountData(safe);
            hasDebt = account.debtUsd != 0;
            // Net of pending withdrawals, which will leave the position and reduce its borrowing power
            borrowHeadroom = _netBorrowHeadroom(account, safeData);
        }

        uint256[] memory spendableAmounts = new uint256[](len);
        uint256[] memory amountsInUsd = new uint256[](len);
        uint256 totalSpendableInUsd = 0;

        for (uint256 i = 0; i < len;) {
            address token = debtServiceTokenPreference[i];
            if (!debtManager.isBorrowToken(token)) revert NotABorrowToken();

            (uint256 spendable, uint256 used) = _debitSpendable(safe, token, safeData, borrowHeadroom, hasDebt);
            borrowHeadroom = borrowHeadroom > used ? borrowHeadroom - used : 0;

            spendableAmounts[i] = spendable;
            if (spendable > 0) {
                amountsInUsd[i] = _toUsd(token, spendable);
                totalSpendableInUsd += amountsInUsd[i];
            }

            unchecked {
                ++i;
            }
        }

        return DebitModeMaxSpend(debtServiceTokenPreference, spendableAmounts, amountsInUsd, totalSpendableInUsd);
    }

    /**
     * @notice Calculates the maximum amount that can be spent in credit mode
     * @param safe Address of the EtherFi Safe
     * @return Maximum amount that can be spent in credit mode (USD, 6 decimals)
     */
    function getMaxSpendCredit(address safe) public view returns (uint256) {
        uint256 capacity = gateway.getAccountData(safe).availableBorrowsUsd;
        uint256 pending = _pendingWithdrawalHeadroom(cashModule.getData(safe));
        return capacity > pending ? capacity - pending : 0;
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
     * @dev Returns the raw Safe balance minus pending withdrawals. DebtManager reads this during its
     *      retirement window, so it stays on the raw balance until the Aave cutover.
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
     * @dev Returns the raw Safe balances minus pending withdrawals. DebtManager reads this during its
     *      retirement window, so it stays on the raw balance until the Aave cutover.
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
     * @notice Supplied amount of `token` withdrawable for a debit spend, in token units
     * @dev min(supplied, reserve cash). When the Safe has debt, also capped by the borrowing headroom: how much
     *      of this reserve can be withdrawn before the leftover debt exceeds its borrowing power, via its LTV.
     */
    function _withdrawableSupplied(address safe, address token, uint256 borrowHeadroomUsd, bool hasDebt) internal view returns (uint256) {
        uint256 supplied = gateway.suppliedOf(safe, token);
        uint256 cash = gateway.availableCash(token);
        uint256 cap = supplied < cash ? supplied : cash;

        if (hasDebt) {
            uint256 ltv = gateway.ltv(token);
            // A zero-LTV reserve has no borrow weight, so a withdrawal against debt cannot be sized safely; stay conservative
            if (ltv == 0) {
                return 0;
            }
            uint256 headroomCap = _fromUsd(token, (borrowHeadroomUsd * HUNDRED_PERCENT) / ltv);
            if (headroomCap < cap) {
                cap = headroomCap;
            }
        }

        return cap;
    }

    /// @notice Borrowing headroom (USD) consumed by withdrawing `amount` of `token`: its USD value weighted by the LTV
    function _headroomConsumed(address token, uint256 amount) internal view returns (uint256) {
        return (_toUsd(token, amount) * gateway.ltv(token)) / HUNDRED_PERCENT;
    }

    /// @notice Borrowing headroom (USD) available for a new spend: the gateway headroom less what queued withdrawals will consume. Zero without debt, since debit only uses the headroom when there is debt.
    function _netBorrowHeadroom(IGateway.AccountData memory account, SafeData memory safeData) internal view returns (uint256) {
        if (account.debtUsd == 0) return 0;
        uint256 pending = _pendingWithdrawalHeadroom(safeData);
        return account.availableBorrowsUsd > pending ? account.availableBorrowsUsd - pending : 0;
    }

    /// @notice Borrowing headroom (USD) tied up by pending withdrawal requests: each pending token's LTV-weighted USD value
    function _pendingWithdrawalHeadroom(SafeData memory safeData) internal view returns (uint256) {
        uint256 total = 0;
        uint256 len = safeData.pendingWithdrawalRequest.tokens.length;
        for (uint256 i = 0; i < len;) {
            uint256 amount = safeData.pendingWithdrawalRequest.amounts[i];
            if (amount != 0) {
                total += _headroomConsumed(safeData.pendingWithdrawalRequest.tokens[i], amount);
            }
            unchecked {
                ++i;
            }
        }

        return total;
    }

    /// @notice Debit spendable for `token` (token units) given the running borrowing headroom, and the headroom that withdrawal consumes
    function _debitSpendable(address safe, address token, SafeData memory safeData, uint256 borrowHeadroomUsd, bool hasDebt) internal view returns (uint256, uint256) {
        uint256 withdrawable = _withdrawableSupplied(safe, token, borrowHeadroomUsd, hasDebt);
        uint256 headroomUsed = hasDebt ? _headroomConsumed(token, withdrawable) : 0;

        uint256 total = IERC20(token).balanceOf(safe) + withdrawable;
        uint256 pending = _getPendingWithdrawalAmount(safeData, token);
        uint256 spendable = total > pending ? total - pending : 0;

        return (spendable, headroomUsed);
    }

    /// @notice Per-token supplied position in the Safe's Aave account, skipping zero balances
    function _suppliedBalances(address safe, address[] memory tokens) internal view returns (IDebtManager.TokenData[] memory) {
        IDebtManager.TokenData[] memory out = new IDebtManager.TokenData[](tokens.length);
        uint256 m = 0;
        for (uint256 i = 0; i < tokens.length;) {
            uint256 amount = gateway.suppliedOf(safe, tokens[i]);
            if (amount != 0) {
                out[m] = IDebtManager.TokenData({ token: tokens[i], amount: amount });
                unchecked {
                    ++m;
                }
            }
            unchecked {
                ++i;
            }
        }

        assembly ("memory-safe") {
            mstore(out, m)
        }

        return out;
    }

    /// @notice Per-token debt in the Safe's Aave account, skipping zero balances
    function _debtBalances(address safe, address[] memory tokens) internal view returns (IDebtManager.TokenData[] memory) {
        IDebtManager.TokenData[] memory out = new IDebtManager.TokenData[](tokens.length);
        uint256 m = 0;
        for (uint256 i = 0; i < tokens.length;) {
            uint256 amount = gateway.debtOf(safe, tokens[i]);
            if (amount != 0) {
                out[m] = IDebtManager.TokenData({ token: tokens[i], amount: amount });
                unchecked {
                    ++m;
                }
            }
            unchecked {
                ++i;
            }
        }

        assembly ("memory-safe") {
            mstore(out, m)
        }

        return out;
    }

    /// @notice Converts a token amount to USD (6 decimals), mirroring DebtManager's conversion
    function _toUsd(address token, uint256 amount) internal view returns (uint256) {
        return (amount * IPriceProvider(dataProvider.getPriceProvider()).price(token)) / (10 ** IERC20Metadata(token).decimals());
    }

    /// @notice Converts a USD amount (6 decimals) to token units, mirroring DebtManager's conversion
    function _fromUsd(address token, uint256 usd) internal view returns (uint256) {
        return (usd * (10 ** IERC20Metadata(token).decimals())) / IPriceProvider(dataProvider.getPriceProvider()).price(token);
    }
}
