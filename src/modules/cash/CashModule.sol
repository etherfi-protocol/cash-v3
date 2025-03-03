// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { SignatureUtils } from "../../libraries/SignatureUtils.sol";
import { SpendingLimit, SpendingLimitLib } from "../../libraries/SpendingLimitLib.sol";
import { IEtherFiDataProvider } from "../../interfaces/IEtherFiDataProvider.sol";
import { IDebtManager } from "../../interfaces/IDebtManager.sol";
import { IPriceProvider } from "../../interfaces/IPriceProvider.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { UpgradeableProxy } from "../../utils/UpgradeableProxy.sol";
import { SafeCashConfig, WithdrawalRequest, Mode, SafeData } from "../../interfaces/ICashModule.sol";
import {ModuleBase} from "../ModuleBase.sol";
import { CashVerificationLib } from "../../libraries/CashVerificationLib.sol";
import { EnumerableAddressWhitelistLib } from "../../libraries/EnumerableAddressWhitelistLib.sol";
import { ArrayDeDupLib } from "../../libraries/ArrayDeDupLib.sol";

/**
 * @title CashModule
 * @notice Cash features for EtherFi Safe accounts
 * @author ether.fi
 */
contract CashModule is UpgradeableProxy, ModuleBase {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using EnumerableAddressWhitelistLib for EnumerableSetLib.AddressSet;
    using SpendingLimitLib for SpendingLimit;
    using MessageHashUtils for bytes32;
    using ArrayDeDupLib for address[];

    /**
     * @dev Storage structure for CashModule using ERC-7201 namespaced diamond storage pattern
     * @custom:storage-location erc7201:etherfi.storage.CashModuleStorage
     */
    struct CashModuleStorage {
        /// @notice Safe Cash Config for each safe
        mapping (address safe => SafeCashConfig cashConfig) safeCashConfig; 
        /// @notice Instance of the DebtManager
        IDebtManager debtManager;
        /// @notice Address of the SettlementDispatcher
        address settlementDispatcher;
        /// @notice Instance of the PriceProvider
        IPriceProvider priceProvider;
        uint64 withdrawalDelay;
        uint64 spendLimitDelay;
        uint64 modeDelay;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.CashModuleStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CashModuleStorageLocation = 0xe000c7adec5855bcf51f74b73aa86172d0a325bc54c3f73cb406d259df90ea00;

    /// @notice Role identifier for EtherFi wallet access control
    bytes32 public constant ETHER_FI_WALLET_ROLE = keccak256("ETHER_FI_WALLET_ROLE");
    bytes32 public constant CASH_MODULE_CONTROLLER_ROLE = keccak256("CASH_MODULE_CONTROLLER_ROLE");

    
    /// @notice Error thrown when a transaction has already been cleared
    error TransactionAlreadyCleared();
    
    
    /// @notice Error thrown when a non-EtherFi wallet tries to access restricted functions
    error OnlyEtherFiWallet();
    
    
    /// @notice Error thrown when an unsupported token is used
    error UnsupportedToken();
    
    
    /// @notice Error thrown when a token that is not a borrow token is used in certain operations
    error OnlyBorrowToken();
    
    
    /// @notice Error thrown when an operation amount is zero
    error AmountZero();
    
    
    /// @notice Error thrown when a balance is insufficient for an operation
    error InsufficientBalance();
    
    /// @notice Error thrown when borrowings would exceed maximum allowed after a spending operation
    error BorrowingsExceedMaxBorrowAfterSpending();
    error RecipientCannotBeAddressZero();
    error OnlyCashModuleController();
    error CannotWithdrawYet();
    error OnlyWhitelistedWithdrawRecipients();
    error InvalidSignatures();
    error ModeAlreadySet();

    constructor(address _etherFiDataProvider) ModuleBase(_etherFiDataProvider) {}

    /**
     * @notice Initializes the CashModule contract
     * @dev Sets up the role registry, debt manager, settlement dispatcher, and data providers
     * @param _roleRegistry Address of the role registry contract
     * @param _debtManager Address of the debt manager contract
     * @param _settlementDispatcher Address of the settlement dispatcher
     * @param _priceProvider Address of the price provider
     */
    function initialize(address _roleRegistry, address _debtManager, address _settlementDispatcher, address _priceProvider) external {
        __UpgradeableProxy_init(_roleRegistry);

        CashModuleStorage storage $ = _getCashModuleStorage();

        $.debtManager = IDebtManager(_debtManager);
        $.settlementDispatcher = _settlementDispatcher;
        $.priceProvider = IPriceProvider(_priceProvider);

        $.withdrawalDelay = 60; // 1 min
        $.spendLimitDelay = 3600; // 1 hour
        $.modeDelay = 60; // 1 min
    }

    function setupModule(bytes calldata data) external override onlyEtherFiSafe(msg.sender) {
        (uint256 dailyLimitInUsd, uint256 monthlyLimitInUsd, int256 timezoneOffset) = abi.decode(data, (uint256, uint256, int256));

        SafeCashConfig storage $ = _getCashModuleStorage().safeCashConfig[msg.sender];
        $.spendingLimit.initialize(dailyLimitInUsd, monthlyLimitInUsd, timezoneOffset);
        $.mode = Mode.Debit;        
    }

    function setDelays(uint64 withdrawalDelay, uint64 spendLimitDelay, uint64 modeDelay) external {
        if (!roleRegistry().hasRole(CASH_MODULE_CONTROLLER_ROLE, msg.sender)) revert OnlyCashModuleController();
        CashModuleStorage storage $ = _getCashModuleStorage();

        $.withdrawalDelay = withdrawalDelay;
        $.spendLimitDelay = spendLimitDelay;
        $.modeDelay = modeDelay;
    }

    function getDelays() external view returns (uint64, uint64, uint64) {
        CashModuleStorage storage $ = _getCashModuleStorage();

        return ($.withdrawalDelay, $.spendLimitDelay, $.modeDelay);
    }

    function setMode(address safe, Mode mode, address signer, bytes calldata signature) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        CashModuleStorage storage $ =_getCashModuleStorage();

        if (mode == $.safeCashConfig[safe].mode) revert ModeAlreadySet();

        CashVerificationLib.verifySetModeSig(safe, signer, _useNonce(safe), mode, signature);

        if ($.modeDelay == 0) {
            // If delay = 0, just set the value 
            $.safeCashConfig[safe].mode = mode;
        } else {
            // If delay != 0, debit to credit mode should incur delay
            if (mode == Mode.Credit) $.safeCashConfig[safe].incomingCreditModeStartTime = block.timestamp + $.modeDelay;
            else {
                // If mode is debit, no problem, just set the mode
                $.safeCashConfig[safe].incomingCreditModeStartTime = 0;
                $.safeCashConfig[safe].mode = mode;
            }
        }
    }

    function getMode(address safe) external view returns (Mode) {
        SafeCashConfig storage $ =_getCashModuleStorage().safeCashConfig[safe];

        if ($.incomingCreditModeStartTime != 0 && block.timestamp > $.incomingCreditModeStartTime) return Mode.Credit;
        return $.mode;
    }


    function incomingCreditModeStartTime(address safe) external view returns (uint256) {
        return _getCashModuleStorage().safeCashConfig[safe].incomingCreditModeStartTime;
    }

    function updateSpendingLimit(address safe, uint256 dailyLimitInUsd, uint256 monthlyLimitInUsd, address signer, bytes calldata signature) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        CashVerificationLib.verifyUpdateSpendingLimitSig(safe, signer, _useNonce(safe), dailyLimitInUsd, monthlyLimitInUsd, signature);
        _getCashModuleStorage().safeCashConfig[safe].spendingLimit.updateSpendingLimit(dailyLimitInUsd, monthlyLimitInUsd, _getCashModuleStorage().spendLimitDelay);
    }

    function configureWithdrawRecipients(address safe, address[] calldata withdrawRecipients, bool[] calldata shouldWhitelist, address[] calldata signers, bytes[] calldata signatures) external onlyEtherFiSafe(safe) {
        CashVerificationLib.verifyConfigureWithdrawRecipients(safe, _useNonce(safe), withdrawRecipients, shouldWhitelist, signers, signatures);

        SafeCashConfig storage $ = _getCashModuleStorage().safeCashConfig[safe];
        $.withdrawRecipients.configure(withdrawRecipients, shouldWhitelist);
    }

    function requestWithdrawal(address safe, address[] calldata tokens, uint256[] calldata amounts, address recipient, address[] calldata signers, bytes[] calldata signatures) external onlyEtherFiSafe(safe) {
        CashVerificationLib.verifyRequestWithdrawalSig(safe, _useNonce(safe), tokens, amounts, recipient, signers, signatures);
        _requestWithdrawal(safe, tokens, amounts, recipient);
    }

    function processWithdrawal(address safe) public onlyEtherFiSafe(safe) {
        SafeCashConfig storage $ = _getCashModuleStorage().safeCashConfig[safe];

        if ($.pendingWithdrawalRequest.finalizeTime > block.timestamp) revert CannotWithdrawYet();
        address recipient = $.pendingWithdrawalRequest.recipient;
        uint256 len = $.pendingWithdrawalRequest.tokens.length;

        address[] memory to = new address[](len);
        bytes[] memory data = new bytes[](len);

        for (uint256 i = 0; i < len; ) {
            to[i] = $.pendingWithdrawalRequest.tokens[i];
            data[i] = abi.encodeWithSelector(IERC20.transfer.selector, recipient, $.pendingWithdrawalRequest.amounts[i]);

            unchecked {
                ++i;
            }
        }

        delete $.pendingWithdrawalRequest;

        IEtherFiSafe(safe).execTransactionFromModule(to, new uint256[](len), data);
    }

    /**
     * @dev Returns the storage struct for CashModule
     * @return $ Reference to the CashModuleStorage struct
     */
    function _getCashModuleStorage() internal pure returns (CashModuleStorage storage $) {
        assembly {
            $.slot := CashModuleStorageLocation
        }
    }

    /**
     * @notice Retrieves cash configuration data for a Safe
     * @dev Only callable for valid EtherFi Safe addresses
     * @param safe Address of the EtherFi Safe
     * @return Data structure containing Safe cash configuration
     * @custom:throws If the address is not a valid EtherFi Safe
     */
    function getData(address safe) external view onlyEtherFiSafe(safe) returns (SafeData memory) {
        SafeCashConfig storage $ =_getCashModuleStorage().safeCashConfig[safe];
        SafeData memory data = SafeData({
            spendingLimit: $.spendingLimit,
            pendingWithdrawalRequest: $.pendingWithdrawalRequest,
            mode: $.mode
        });

        return data;
    } 

    /**
     * @notice Checks if a transaction has been cleared
     * @dev Only callable for valid EtherFi Safe addresses
     * @param safe Address of the EtherFi Safe
     * @param txId Transaction identifier
     * @return Boolean indicating if the transaction is cleared
     * @custom:throws If the address is not a valid EtherFi Safe
     */
    function transactionCleared(address safe, bytes32 txId) public view onlyEtherFiSafe(safe) returns(bool) {
        return _getCashModuleStorage().safeCashConfig[safe].transactionCleared[txId];
    }

    /**
     * @notice Gets the debt manager contract
     * @return IDebtManager instance
     */
    function getDebtManager() public view returns (IDebtManager) {
        return _getCashModuleStorage().debtManager;
    }

    /**
     * @notice Gets the price provider contract
     * @return IPriceProvider instance
     */
    function getPriceProvider() external view returns (IPriceProvider) {
        return _getCashModuleStorage().priceProvider;
    }

    /**
     * @notice Processes a spending transaction
     * @dev Only callable by EtherFi wallet for valid EtherFi Safe addresses
     * @param safe Address of the EtherFi Safe
     * @param txId Transaction identifier
     * @param token Address of the token to spend
     * @param amountInUsd Amount to spend in USD
     * @custom:throws TransactionAlreadyCleared if the transaction was already processed
     * @custom:throws UnsupportedToken if the token is not supported
     * @custom:throws AmountZero if the converted amount is zero
     * @custom:throws If spending would exceed limits or balances
     */
    function spend(address safe, bytes32 txId, address token, uint256 amountInUsd) external onlyEtherFiWallet onlyEtherFiSafe(safe) {
        CashModuleStorage storage $ = _getCashModuleStorage();
        SafeCashConfig storage $$ = $.safeCashConfig[safe];
        IDebtManager debtManager = $.debtManager;
        
        _setCurrentMode($$);

        if ($$.transactionCleared[txId]) revert TransactionAlreadyCleared();
        if (!_isBorrowToken(debtManager, token)) revert UnsupportedToken();
        uint256 amount = debtManager.convertUsdToCollateralToken(token, amountInUsd);
        if (amount == 0) revert AmountZero();

        $$.transactionCleared[txId] = true;
        $$.spendingLimit.spend(amountInUsd);

        _spend($$, debtManager, safe, token, amount);
    }

    /**
     * @dev Internal function to execute the spending transaction
     * @param $$ Storage reference to the SafeCashConfig
     * @param debtManager Reference to the debt manager contract
     * @param safe Address of the EtherFi Safe
     * @param token Address of the token to spend
     * @param amount Amount of tokens to spend
     * @custom:throws BorrowingsExceedMaxBorrowAfterSpending if spending would exceed borrowing limits
     */
    function _spend(SafeCashConfig storage $$, IDebtManager debtManager, address safe, address token, uint256 amount) internal {
        address[] memory to = new address[](1);
        bytes[] memory data = new bytes[](1);
        uint256[] memory values = new uint256[](1);

        if ($$.mode == Mode.Credit) {
            to[0] = address(debtManager);
            data[0] = abi.encodeWithSelector(IDebtManager.borrow.selector, token, amount);
            values[0] = 0;

            try IEtherFiSafe(safe).execTransactionFromModule(to, values, data) {}
            catch {
                _cancelOldWithdrawal(safe);
                IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
            }
        } else {
            _updateWithdrawalRequestIfNecessary(safe, token, amount);
            (IDebtManager.TokenData[] memory collateralTokenAmounts, ) = _getCollateralBalanceWithTokenSubtracted(debtManager, safe, token, amount, $$.mode);
            (uint256 totalMaxBorrow, uint256 totalBorrowings) =  debtManager.getBorrowingPowerAndTotalBorrowing(safe, collateralTokenAmounts);

            if (totalBorrowings > totalMaxBorrow && $$.pendingWithdrawalRequest.tokens.length != 0) {
                _cancelOldWithdrawal(safe);
                (collateralTokenAmounts, ) = _getCollateralBalanceWithTokenSubtracted(debtManager, safe, token, amount, $$.mode);
                (totalMaxBorrow, totalBorrowings) =  debtManager.getBorrowingPowerAndTotalBorrowing(safe, collateralTokenAmounts);
            }
            if (totalBorrowings > totalMaxBorrow) revert BorrowingsExceedMaxBorrowAfterSpending();

            to[0] = token;
            data[0] = abi.encodeWithSelector(IERC20.transfer.selector, _getCashModuleStorage().settlementDispatcher, amount);
            values[0] = 0;
        }
        
        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
    }

    /**
     * @notice Repays borrowed tokens
     * @dev Only callable by EtherFi wallet for valid EtherFi Safe addresses
     * @param safe Address of the EtherFi Safe
     * @param token Address of the token to repay
     * @param amountInUsd Amount to repay in USD
     * @custom:throws OnlyBorrowToken if token is not a valid borrow token
     */
    function repay(address safe, address token, uint256 amountInUsd) public onlyEtherFiWallet onlyEtherFiSafe(safe) {
        IDebtManager debtManager = getDebtManager();
        if (!_isBorrowToken(debtManager, token)) revert OnlyBorrowToken();
        _repay(safe, debtManager, token, amountInUsd);
    }

    /**
     * @dev Internal function to execute the repayment transaction
     * @param safe Address of the EtherFi Safe
     * @param debtManager Reference to the debt manager contract
     * @param token Address of the token to repay
     * @param amountInUsd Amount to repay in USD
     * @custom:throws AmountZero if the converted amount is zero
     */
    function _repay(address safe, IDebtManager debtManager, address token, uint256 amountInUsd) internal {
        uint256 amount = IDebtManager(debtManager).convertUsdToCollateralToken(token, amountInUsd);
        if (amount == 0) revert AmountZero();
        _updateWithdrawalRequestIfNecessary(safe, token, amount);

        address[] memory to = new address[](2);
        bytes[] memory data = new bytes[](2);
        uint256[] memory values = new uint256[](2);

        to[0] = token;
        to[1] = address(debtManager);

        data[0] = abi.encodeWithSelector(IERC20.approve.selector, address(debtManager), amount);
        data[1] = abi.encodeWithSelector(IDebtManager.repay.selector, safe, token, amount);

        values[0] = 0;
        values[1] = 0;

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
    }

    /**
     * @notice Gets the pending withdrawal amount for a token
     * @dev Only callable for valid EtherFi Safe addresses
     * @param safe Address of the EtherFi Safe
     * @param token Address of the token to check
     * @return Amount of tokens pending withdrawal
     * @custom:throws If the address is not a valid EtherFi Safe
     */
    function getPendingWithdrawalAmount(address safe, address token) public view onlyEtherFiSafe(safe) returns (uint256) {
        WithdrawalRequest memory withdrawalRequest = _getCashModuleStorage().safeCashConfig[safe].pendingWithdrawalRequest;
        uint256 len = withdrawalRequest.tokens.length;
        uint256 tokenIndex = len;
        for (uint256 i = 0; i < len; ) {
            if (withdrawalRequest.tokens[i] == token) {
                tokenIndex = i;
                break;
            }
            unchecked {
                ++i;
            }
        }

        return tokenIndex != len ? withdrawalRequest.amounts[tokenIndex] : 0;
    }

    /**
     * @dev Calculates collateral balance with a token amount subtracted
     * @param debtManager Reference to the debt manager contract
     * @param safe Address of the EtherFi Safe
     * @param token Address of the token to subtract
     * @param amount Amount to subtract
     * @param __mode Operating mode (Credit or Debit)
     * @return tokenAmounts Array of token data with updated balances
     * @return error Error message if calculation fails
     */
    function _getCollateralBalanceWithTokenSubtracted(IDebtManager debtManager, address safe, address token, uint256 amount, Mode __mode) internal view returns (IDebtManager.TokenData[] memory, string memory error) {
        address[] memory collateralTokens = debtManager.getCollateralTokens();
        uint256 len = collateralTokens.length;
        IDebtManager.TokenData[] memory tokenAmounts = new IDebtManager.TokenData[](collateralTokens.length);
        uint256 m = 0;
        for (uint256 i = 0; i < len; ) {
            uint256 balance = IERC20(collateralTokens[i]).balanceOf(safe); 
            uint256 pendingWithdrawalAmount = getPendingWithdrawalAmount(safe, collateralTokens[i]);
            if (balance != 0) {
                balance = balance - pendingWithdrawalAmount;
                if (__mode == Mode.Debit && token == collateralTokens[i]) {
                    if (balance == 0 || balance < amount) return(new IDebtManager.TokenData[](0), "Insufficient effective balance after withdrawal to spend with debit mode");
                    balance = balance - amount;
                }
                tokenAmounts[m] = IDebtManager.TokenData({token: collateralTokens[i], amount: balance});
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

    /**
     * @dev Cancels pending withdrawal requests for a Safe
     * @param safe Address of the EtherFi Safe
     */
    function _cancelOldWithdrawal(address safe) internal {
        SafeCashConfig storage safeCashConfig = _getCashModuleStorage().safeCashConfig[safe];
        if (safeCashConfig.pendingWithdrawalRequest.tokens.length > 0) {
            delete safeCashConfig.pendingWithdrawalRequest;
        }
    }

    /**
     * @dev Updates withdrawal request if necessary based on available balance
     * @param safe Address of the EtherFi Safe
     * @param token Address of the token to update
     * @param amount Amount being processed
     * @custom:throws InsufficientBalance if there is not enough balance for the operation
     */
    function _updateWithdrawalRequestIfNecessary(address safe, address token, uint256 amount) internal {
        SafeCashConfig storage safeCashConfig = _getCashModuleStorage().safeCashConfig[safe];
        uint256 balance = IERC20(token).balanceOf(safe);

        if (amount > balance) revert InsufficientBalance();

        uint256 len = safeCashConfig.pendingWithdrawalRequest.tokens.length;
        uint256 tokenIndex = len;
        for (uint256 i = 0; i < len; ) {
            if (safeCashConfig.pendingWithdrawalRequest.tokens[i] == token) {
                tokenIndex = i;
                break;
            }
            unchecked {
                ++i;
            }
        }

        // If the token does not exist in withdrawal request, return
        if (tokenIndex == len) return;

        if (amount + safeCashConfig.pendingWithdrawalRequest.amounts[tokenIndex] > balance) {
            safeCashConfig.pendingWithdrawalRequest.amounts[tokenIndex] = balance - amount;
        }
    }

    /**
     * @dev Checks if a token is a valid borrow token
     * @param debtManager Reference to the debt manager contract
     * @param token Address of the token to check
     * @return Boolean indicating if the token is a borrow token
     */
    function _isBorrowToken(IDebtManager debtManager, address token) internal view returns (bool) {
        return debtManager.isBorrowToken(token);
    }

    /**
     * @dev Modifier to ensure caller has the EtherFi wallet role
     * @custom:throws OnlyEtherFiWallet if caller does not have the role
     */
    modifier onlyEtherFiWallet() {
        if (!roleRegistry().hasRole(ETHER_FI_WALLET_ROLE, msg.sender)) revert OnlyEtherFiWallet();
        _;
    }

    function _setCurrentMode(SafeCashConfig storage $) internal {
        if ($.incomingCreditModeStartTime != 0 && block.timestamp > $.incomingCreditModeStartTime) {
            $.mode = Mode.Credit;
            delete $.incomingCreditModeStartTime;
        }
    }

    function _checkBalance(address safe, address[] calldata tokens, uint256[] calldata amounts) internal view {
        uint256 len = tokens.length;
        if (len != amounts.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < len; ) {
            if (IERC20(tokens[i]).balanceOf(safe) < amounts[i]) revert InsufficientBalance();

            unchecked {
                ++i;
            }
        }
    }

    function _requestWithdrawal(address safe, address[] calldata tokens, uint256[] calldata amounts, address recipient) internal {
        CashModuleStorage storage $ = _getCashModuleStorage();

        if (recipient == address(0)) revert RecipientCannotBeAddressZero();
        if(!$.safeCashConfig[safe].withdrawRecipients.contains(recipient)) revert OnlyWhitelistedWithdrawRecipients();
        
        if (tokens.length > 1) tokens.checkDuplicates();
        
        _cancelOldWithdrawal(safe);
        
        uint96 finalTime = uint96(block.timestamp) + $.withdrawalDelay;

        _checkBalance(safe, tokens, amounts);

        $.safeCashConfig[safe].pendingWithdrawalRequest = WithdrawalRequest({
            tokens: tokens,
            amounts: amounts,
            recipient: recipient,
            finalizeTime: finalTime
        });

        getDebtManager().ensureHealth(safe);

        if ($.withdrawalDelay == 0) processWithdrawal(safe);
    }
}