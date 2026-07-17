// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ArrayDeDupLib } from "../../libraries/ArrayDeDupLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { DebitModeMaxSpend, ICashModule, Mode, SafeCashData, SafeData } from "../../interfaces/ICashModule.sol";
import { IDebtManager } from "../../interfaces/IDebtManager.sol";
import { IEtherFiDataProvider } from "../../interfaces/IEtherFiDataProvider.sol";
import { ILendGateway } from "../../interfaces/ILendGateway.sol";
import { IPriceProvider } from "../../interfaces/IPriceProvider.sol";
import { LendSourcingLib } from "../../libraries/LendSourcingLib.sol";
import { SpendingLimit, SpendingLimitLib } from "../../libraries/SpendingLimitLib.sol";
import { Constants } from "../../utils/Constants.sol";
import { UpgradeableProxy } from "../../utils/UpgradeableProxy.sol";
import { CashLensLegacyLib } from "./CashLensLegacyLib.sol";

/**
 * @title CashLens
 * @notice Read-only contract providing views into a Safe's cash state
 * @dev Every engine-touching view branches on CashModule.usesLendGateway: gateway safes are read from the
 *      Aave gateway (the logic in this contract), legacy safes from the DebtManager (preserved output-identical
 *      in the linked CashLensLegacyLib). The check side of a spend must always agree with what the execution
 *      side (CashLendLib) will do, so both read the same flag. Legacy code always sits inside an
 *      `if (!usesLendGateway(safe))` block (routing to CashLensLegacyLib, or a couple of master-verbatim
 *      lines inline), deleted wholesale when the legacy engine is retired; the gateway path is the unguarded
 *      fall-through.
 *
 *      LendGateway safes: the position and the supported-token lists (registered/borrowable assets) are read
 *      from the Aave gateway; nothing on the gateway path touches the DebtManager.
 *      Credit capacity comes straight from Aave. Debit spendable is the raw Safe balance plus the
 *      withdrawable supplied amount; when the Safe has debt, the withdrawable part is capped by the
 *      borrowing headroom (collateral weighted by LTV, minus debt) so the leftover position keeps
 *      debt within its borrowing power. USD is 6 decimals throughout, matching PriceProvider.DECIMALS;
 *      the gateway returns its USD aggregates in the same scale.
 *
 *      The debit cap uses LTV, the same bound Aave enforces on every collateral withdraw (v4's single
 *      collateralFactor doubles as LTV and liquidation threshold), so what CashLens reports as debit
 *      spendable is exactly what a gateway withdraw allows; there is no separate module-side health gate.
 *
 *      A pending withdrawal sits against the loose Safe balance, not the supplied position. CashLens reserves
 *      it from the loose balance and uses the gateway's figures (maxBorrow, credit/debit headroom)
 *      for the supplied position as-is.
 *
 *      Collateral views (getSafeCashData totals, getUserTotalCollateral, getUserCollateralForToken) report a
 *      gateway safe's supplied position plus its idle balance of registered assets — loose funds net of any
 *      pending-withdrawal reservation. Idle funds show as collateral but carry no borrowing power until
 *      supplied, so maxBorrow and the spend ceilings stay gateway-derived.
 * @author ether.fi
 */
contract CashLens is UpgradeableProxy, Constants {
    using SpendingLimitLib for SpendingLimit;
    using ArrayDeDupLib for address[];

    /// @notice Reference to the deployed CashModule contract
    ICashModule public immutable cashModule;
    /// @notice Reference to the deployed EtherFiDataProvider contract
    IEtherFiDataProvider public immutable dataProvider;

    /// @notice Error thrown when trying to use a token that is not on the collateral whitelist
    error NotACollateralToken();
    /// @notice Error thrown when trying to use a token that is not on the borrow whitelist
    error NotABorrowToken();

    /**
     * @notice Initializes the CashLens contract with its dependencies
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

    /// @notice Returns the Aave gateway currently configured on CashModule
    function gateway() public view returns (ILendGateway) {
        return cashModule.getLendGateway();
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

        string memory firstReason;

        for (uint256 i = 0; i < tokenPreferences.length;) {
            singleToken[0] = tokenPreferences[i];

            (bool success, string memory reason) = canSpend(safe, txId, singleToken, amountsInUsd);
            if (i == 0) firstReason = reason;

            if (success) return (tokenPreferences[i], true, "");

            unchecked {
                ++i;
            }
        }

        return (tokenPreferences[0], false, firstReason);
    }

    /// @notice Validates mode and spending limits, then runs the mode-specific check
    function _validateSpending(address safe, address[] memory tokens, uint256[] memory amountsInUsd, uint256 totalSpendingInUsd) internal view returns (bool, string memory) {
        SafeData memory safeData = cashModule.getData(safe);

        Mode mode = safeData.mode;
        if (safeData.incomingModeStartTime != 0) mode = safeData.incomingMode;

        // In Credit mode, only one token is allowed
        if (mode == Mode.Credit && tokens.length > 1) return (false, "Only one token allowed in Credit mode");

        // Check spending limit
        (bool withinLimit, string memory limitMessage) = safeData.spendingLimit.canSpend(totalSpendingInUsd);
        if (!withinLimit) {
            return (false, limitMessage);
        }

        // Route by engine, mirroring the spend execution: legacy safes get the pre-gateway DebtManager
        // checks (and decline strings) exactly as before the gateway existed.
        if (!cashModule.usesLendGateway(safe)) {
            return CashLensLegacyLib.check(cashModule, safe, tokens, amountsInUsd, totalSpendingInUsd, safeData, mode);
        }

        if (mode == Mode.Credit) {
            return _creditCheck(safe, tokens[0], totalSpendingInUsd);
        }
        return _debitCheck(safe, tokens, amountsInUsd, safeData);
    }

    /// @notice Credit mode check: the spend must fit the Aave borrowing capacity and the reserve's liquidity
    function _creditCheck(address safe, address token, uint256 totalSpendingInUsd) internal view returns (bool, string memory) {
        // Token gate, reserve liquidity, and the health-factor-floor-buffered borrowing power live in the
        // linked LendSourcingLib (code size); see creditCheck there for the quote-vs-execution contract.
        return LendSourcingLib.creditCheck(cashModule.getLendGateway(), IPriceProvider(dataProvider.getPriceProvider()), safe, token, totalSpendingInUsd);
    }

    /// @notice Debit mode check: each token's spendable amount must cover its share of the spend, threading the borrowing headroom across tokens
    function _debitCheck(address safe, address[] memory tokens, uint256[] memory amountsInUsd, SafeData memory safeData) internal view returns (bool, string memory) {
        ILendGateway lendGateway = gateway();
        bool hasDebt = lendGateway.hasDebt(safe);
        // Aave-priced and buffered by the health-factor floor: quotes size collateral withdrawals so the
        // position stays above the floor; debit execution keeps the raw bound (spends always settle)
        uint256 withdrawHeadroom = hasDebt ? lendGateway.withdrawHeadroom(safe) : 0;

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            if (!lendGateway.isSpendAsset(token)) {
                return (false, "Not a supported spend token");
            }

            uint256 needed = _fromUsd(token, amountsInUsd[i]);
            uint256 raw = IERC20(token).balanceOf(safe);
            {
                uint256 withdrawableSupplied = _withdrawableSupplied(safe, token, withdrawHeadroom, hasDebt);
                if (raw + withdrawableSupplied < needed) {
                    return (false, "Insufficient token balance for debit mode spending");
                }
                uint256 pending = _getPendingWithdrawalAmount(safeData, token);
                raw = raw > pending ? raw - pending : 0;
                if (raw + withdrawableSupplied < needed) {
                    return (false, "Insufficient effective balance after withdrawal to spend with debit mode");
                }
            }

            // Only the supplied portion (effective raw is spent first) consumes the borrowing headroom for later tokens
            if (hasDebt) {
                uint256 usedSupplied = needed > raw ? needed - raw : 0;
                uint256 used = _headroomRemoved(safe, token, usedSupplied);
                withdrawHeadroom = withdrawHeadroom > used ? withdrawHeadroom - used : 0;
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
        IPriceProvider priceProvider = IPriceProvider(dataProvider.getPriceProvider());
        SafeData memory safeData = cashModule.getData(safe);

        SafeCashData memory data;

        // Each engine names its own token universe: DebtManager's lists for a legacy safe, the gateway's
        // registered/spendable assets for an Aave safe. The spend list is the debitMaxSpend default; on
        // the legacy engine the borrow-token list is that same list.
        address[] memory collateralTokens;
        address[] memory debitSpendTokens;

        if (!cashModule.usesLendGateway(safe)) {
            IDebtManager debtManager = cashModule.getDebtManager();
            collateralTokens = debtManager.getCollateralTokens();
            debitSpendTokens = debtManager.getBorrowTokens();
            (data.collateralBalances, data.totalCollateral, data.borrows, data.totalBorrow) = debtManager.getUserCurrentState(safe);
            data.maxBorrow = debtManager.getMaxBorrowAmount(safe, true);
        } else {
            ILendGateway lendGateway = gateway();
            collateralTokens = lendGateway.registeredAssets();
            debitSpendTokens = lendGateway.spendAssets();
            ILendGateway.AccountData memory account = lendGateway.getAccountData(safe);
            uint256 idleUsd;
            (data.collateralBalances, idleUsd) = _collateralBalances(safe, collateralTokens, safeData);
            // Debt can sit on any registered reserve, including one that stopped being borrowable after
            // the borrow (borrowable flag turned off, or the reserve frozen/paused), so walk all
            // registered assets here to match totalBorrow and hasOpenBorrows.
            data.borrows = _debtBalances(safe, collateralTokens);
            // Supplied position (the gateway's Aave-priced aggregate) plus idle registered assets
            // (PriceProvider-priced, same 6-decimal scale). Idle funds add no borrowing power.
            data.totalCollateral = account.collateralUsd + idleUsd;
            data.totalBorrow = account.debtUsd;
            // Gross borrowing power (collateral weighted by LTV): the gateway headroom plus current debt
            data.maxBorrow = account.availableBorrowsUsd + account.debtUsd;
        }

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
            data.debitMaxSpend = getMaxSpendDebit(safe, debitSpendTokens);
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
     * @dev Each token's spendable amount is its loose Safe balance (less any pending withdrawal it has
     *      reserved) plus the withdrawable supplied amount. When the Safe has debt, the withdrawable supplied
     *      amount is capped by the borrowing headroom (collateral weighted by LTV, minus debt), threaded
     *      across the preference order so each token only spends the headroom the earlier ones left. Pending
     *      withdrawals are reserved from the raw Safe balance only; the supplied side is used as-is.
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

        if (!cashModule.usesLendGateway(safe)) {
            return CashLensLegacyLib.maxSpendDebit(cashModule, safe, debtServiceTokenPreference);
        }

        ILendGateway lendGateway = gateway();
        SafeData memory safeData = cashModule.getData(safe);

        bool hasDebt = lendGateway.hasDebt(safe);
        // Aave-priced and buffered by the health-factor floor, matching _debitCheck
        uint256 withdrawHeadroom = hasDebt ? lendGateway.withdrawHeadroom(safe) : 0;

        uint256[] memory spendableAmounts = new uint256[](len);
        uint256[] memory amountsInUsd = new uint256[](len);
        uint256 totalSpendableInUsd = 0;

        for (uint256 i = 0; i < len;) {
            address token = debtServiceTokenPreference[i];
            if (!lendGateway.isSpendAsset(token)) revert NotABorrowToken();

            (uint256 spendable, uint256 used) = _debitSpendable(safe, token, safeData, withdrawHeadroom, hasDebt);
            withdrawHeadroom = withdrawHeadroom > used ? withdrawHeadroom - used : 0;

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
     * @dev Borrowing power (collateral weighted by LTV, minus debt) bounded by pool liquidity: a credit
     *      spend draws a single borrow token, so the most liquid borrow token sets the achievable ceiling,
     *      matching the reserve-liquidity decline in _creditCheck.
     * @param safe Address of the EtherFi Safe
     * @return Maximum amount that can be spent in credit mode (USD, 6 decimals)
     */
    function getMaxSpendCredit(address safe) public view returns (uint256) {
        if (!cashModule.usesLendGateway(safe)) {
            return CashLensLegacyLib.maxSpendCredit(cashModule, safe);
        }

        // Floor-buffered borrowing power bounded by reserve liquidity; lives in the linked
        // LendSourcingLib (code size), matching _creditCheck's gates
        return LendSourcingLib.maxSpendCredit(cashModule.getLendGateway(), IPriceProvider(dataProvider.getPriceProvider()), safe);
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
     * @notice Max amount of `token` an operation can source from the safe: the loose balance (net of any
     *         pending-withdrawal reservation) plus the Aave-supplied amount withdrawable without leaving
     *         the position over-LTV
     * @dev The number a module's sandwich (swap input, Liquid deposit/withdraw) or a backend repay can
     *      actually pull, sized by the same LendSourcingLib math the spend paths use, so a frontend max
     *      never needs to reimplement LTV accounting. Works for any token: an unregistered token or ETH has no supplied part, and a legacy safe's funds
     *      are all loose. Conservative for a zero-LTV reserve while the safe has debt (it cannot be sized
     *      against debt), matching the debit-spend sizing. For a legacy safe with DebtManager debt the number
     *      is an upper bound, not a health promise: an operation that removes value from the safe (rather than
     *      swapping it in place) is still subject to the hook's DebtManager health check at execution,
     *      matching what the legacy engine has always enforced.
     * @param safe Address of the safe
     * @param token Address of the token (or the ETH marker address)
     * @return Max sourceable amount of `token`, in token units
     */
    function getMaxSourceable(address safe, address token) external view returns (uint256) {
        SafeData memory safeData = cashModule.getData(safe);
        uint256 loose = token == ETH ? safe.balance : IERC20(token).balanceOf(safe);
        uint256 pending = _getPendingWithdrawalAmount(safeData, token);
        uint256 looseAvailable = loose > pending ? loose - pending : 0;

        if (!cashModule.usesLendGateway(safe)) {
            return looseAvailable;
        }

        ILendGateway lendGateway = gateway();
        // Aave-priced and buffered by the health-factor floor: withdrawal sourcing enforces the floor at
        // execution, so this quote is exactly what a request (or module sandwich) can actually pull.
        return looseAvailable + _withdrawableSupplied(safe, token, lendGateway.withdrawHeadroom(safe), lendGateway.hasDebt(safe));
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
     * @dev A gateway safe's collateral is its Aave-supplied balance plus its idle balance (loose funds net
     *      of any pending-withdrawal reservation). A legacy safe's collateral is its raw balance minus pending
     *      withdrawals — DebtManager reads this branch for its health and borrow checks, so it must keep the
     *      exact pre-gateway semantics until the legacy engine is retired.
     * @param safe Address of the safe
     * @param token Address of the collateral token to check
     * @return Effective collateral amount
     * @custom:throws NotACollateralToken if token is not a collateral token on the safe's engine
     */
    function getUserCollateralForToken(address safe, address token) public view returns (uint256) {
        if (!cashModule.usesLendGateway(safe)) {
            if (!cashModule.getDebtManager().isCollateralToken(token)) revert NotACollateralToken();
            uint256 balance = IERC20(token).balanceOf(safe);
            uint256 pendingWithdrawalAmount = getPendingWithdrawalAmount(safe, token);

            return balance > pendingWithdrawalAmount ? balance - pendingWithdrawalAmount : 0;
        }

        ILendGateway lendGateway = gateway();
        if (!lendGateway.isRegistered(token)) revert NotACollateralToken();
        return lendGateway.suppliedOf(safe, token) + _idleBalance(safe, token, cashModule.getData(safe));
    }

    /**
     * @notice Gets all effective collateral balances for a safe
     * @dev A gateway safe's collateral is its Aave-supplied balances plus its idle balances of registered
     *      assets (loose funds net of pending-withdrawal reservations); a legacy safe's is its raw balances
     *      minus pending withdrawals. DebtManager reads the legacy branch for its health and borrow checks,
     *      so that branch must keep the exact pre-gateway semantics until the legacy engine is retired.
     * @param safe Address of the safe
     * @return Array of token data with token addresses and effective amounts
     */
    function getUserTotalCollateral(address safe) public view returns (IDebtManager.TokenData[] memory) {
        if (!cashModule.usesLendGateway(safe)) {
            return CashLensLegacyLib.userTotalCollateral(cashModule, safe, cashModule.getDebtManager().getCollateralTokens());
        }

        (IDebtManager.TokenData[] memory collateral,) = _collateralBalances(safe, gateway().registeredAssets(), cashModule.getData(safe));
        return collateral;
    }

    /**
     * @notice Supplied amount of `token` withdrawable for a debit spend, in token units
     * @dev min(supplied, reserve cash). When the Safe has debt, the supplied side is what the gateway's
     *      Aave-priced collateral headroom allows.
     */
    function _withdrawableSupplied(address safe, address token, uint256 headroom, bool hasDebt) internal view returns (uint256) {
        return LendSourcingLib.withdrawableSupplied(gateway(), safe, token, headroom, hasDebt);
    }

    /// @notice The weighted collateral value withdrawing `amount` of `token` consumes (gateway view; helper keeps call-site stacks flat)
    function _headroomRemoved(address safe, address token, uint256 amount) internal view returns (uint256) {
        return gateway().headroomRemoved(safe, token, amount);
    }

    /// @notice Debit spendable for `token` (token units) given the running borrowing headroom, and the headroom that withdrawal consumes
    function _debitSpendable(address safe, address token, SafeData memory safeData, uint256 withdrawHeadroom, bool hasDebt) internal view returns (uint256, uint256) {
        uint256 withdrawableSupplied = _withdrawableSupplied(safe, token, withdrawHeadroom, hasDebt);
        uint256 headroomUsed = hasDebt ? _headroomRemoved(safe, token, withdrawableSupplied) : 0;

        uint256 raw = IERC20(token).balanceOf(safe);
        uint256 pending = _getPendingWithdrawalAmount(safeData, token);
        uint256 spendable = _debitSpendableAmount(raw, withdrawableSupplied, pending);

        return (spendable, headroomUsed);
    }

    /**
     * @notice Spendable amount of one debit token: its loose Safe balance less the pending withdrawal it has reserved, plus the withdrawable supplied amount.
     * @dev A pending withdrawal sits against the loose Safe balance, so it is reserved from `raw` only;
     *      `withdrawableSupplied` (the supplied side) is unaffected.
     */
    function _debitSpendableAmount(uint256 raw, uint256 withdrawableSupplied, uint256 pending) internal pure returns (uint256) {
        uint256 rawAfterPending = raw > pending ? raw - pending : 0;
        return rawAfterPending + withdrawableSupplied;
    }

    /// @notice Per-token collateral of a gateway safe: the Aave-supplied position plus the idle Safe balance
    ///         (loose funds net of any pending-withdrawal reservation), skipping zero balances. Also returns
    ///         the idle part's total USD value (6 decimals) so getSafeCashData can extend the gateway's
    ///         Aave-priced collateral aggregate in the same scale.
    function _collateralBalances(address safe, address[] memory tokens, SafeData memory safeData) internal view returns (IDebtManager.TokenData[] memory, uint256) {
        ILendGateway lendGateway = cashModule.getLendGateway();
        IDebtManager.TokenData[] memory out = new IDebtManager.TokenData[](tokens.length);
        uint256 idleUsd = 0;
        uint256 m = 0;
        for (uint256 i = 0; i < tokens.length;) {
            uint256 idle = _idleBalance(safe, tokens[i], safeData);
            if (idle != 0) idleUsd += _toUsd(tokens[i], idle);
            uint256 amount = lendGateway.suppliedOf(safe, tokens[i]) + idle;
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

        return (out, idleUsd);
    }

    /// @notice Idle balance of `token` in the Safe: the loose balance less any pending-withdrawal reservation
    function _idleBalance(address safe, address token, SafeData memory safeData) internal view returns (uint256) {
        uint256 loose = IERC20(token).balanceOf(safe);
        uint256 pending = _getPendingWithdrawalAmount(safeData, token);
        return loose > pending ? loose - pending : 0;
    }

    /// @notice Per-token debt in the Safe's Aave account, skipping zero balances
    function _debtBalances(address safe, address[] memory tokens) internal view returns (IDebtManager.TokenData[] memory) {
        ILendGateway lendGateway = cashModule.getLendGateway();
        IDebtManager.TokenData[] memory out = new IDebtManager.TokenData[](tokens.length);
        uint256 m = 0;
        for (uint256 i = 0; i < tokens.length;) {
            uint256 amount = lendGateway.debtOf(safe, tokens[i]);
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
