// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ICashEventEmitter } from "../../interfaces/ICashEventEmitter.sol";
import { SafeCashConfig, SafeData, SafeTiers, WithdrawalRequest } from "../../interfaces/ICashModule.sol";
import { ICashbackDispatcher } from "../../interfaces/ICashbackDispatcher.sol";
import { IDebtManager } from "../../interfaces/IDebtManager.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { ILendGateway } from "../../interfaces/ILendGateway.sol";
import { ArrayDeDupLib } from "../../libraries/ArrayDeDupLib.sol";
import { CashVerificationLib } from "../../libraries/CashVerificationLib.sol";
import { SignatureUtils } from "../../libraries/SignatureUtils.sol";
import { SpendingLimit, SpendingLimitLib } from "../../libraries/SpendingLimitLib.sol";
import { UpgradeableProxy } from "../../utils/UpgradeableProxy.sol";
import { ModuleBase } from "../ModuleBase.sol";
import { CashLendLib } from "./CashLendLib.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

/**
 * @title CashModule
 * @notice Cash features for EtherFi Safe accounts
 * @author ether.fi
 */
contract CashModuleStorageContract is UpgradeableProxy, ModuleBase {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using SpendingLimitLib for SpendingLimit;
    using MessageHashUtils for bytes32;
    using ArrayDeDupLib for address[];

    /**
     * @dev Storage structure for CashModule using ERC-7201 namespaced diamond storage pattern
     * @custom:storage-location erc7201:etherfi.storage.CashModuleStorage
     */
    struct CashModuleStorage {
        /// @notice Safe Cash Config for each safe
        mapping(address safe => SafeCashConfig cashConfig) safeCashConfig;
        /// @notice Instance of the DebtManager for borrowing and repayment operations
        IDebtManager debtManager;
        /// @notice Address of the SettlementDispatcher for Reap
        address settlementDispatcherReap;
        /// @notice Delay in seconds before a withdrawal request can be finalized
        uint64 withdrawalDelay;
        /// @notice Delay in seconds before spending limit changes take effect
        uint64 spendLimitDelay;
        /// @notice Delay in seconds before a mode change (particularly to Credit mode) takes effect
        uint64 modeDelay;
        /// @notice Mapping of safe tiers to cashback percentages in basis points (100 = 1%)
        mapping(SafeTiers tier => uint256 cashbackPercentage) DEPRECATED_tierCashbackPercentage;
        /// @notice Tracks pending cashback amounts in USD for each account (safe or spender)
        mapping(address account => uint256 pendingCashback) DEPRECATED_pendingCashbackInUsd;
        /// @notice Reference to the cashback dispatcher contract that processes cashback rewards
        ICashbackDispatcher cashbackDispatcher;
        /// @notice Reference to the event emitter contract that standardizes event emissions
        ICashEventEmitter cashEventEmitter;
        /// @notice Address of cash module setters contract
        address cashModuleSetters;
        /// @notice Cashback percentage for referrer in bps
        uint64 DEPRECATED_referrerCashbackPercentageInBps;
        /// @notice Address of the SettlementDispatcher for Rain
        address settlementDispatcherRain;
        /// @notice Address of tokens that can be withdrawn from the safe
        EnumerableSetLib.AddressSet whitelistedWithdrawAssets;
        /// @notice Tracks pending cashback amounts for a token in USD for each account (safe or spender)
        mapping(address account => mapping(address token => uint256 pendingCashback)) pendingCashbackForTokenInUsd;
        /// @notice Addresses of modules that can request withdrawals on behalf of safes
        EnumerableSetLib.AddressSet whitelistedModulesCanRequestWithdraw;
        /// @notice Address of the SettlementDispatcher for PIX
        address settlementDispatcherPix;
        /// @notice Address of the SettlementDispatcher for CardOrder
        address settlementDispatcherCardOrder;
        /// @notice The Aave gateway that runs position operations (borrow/withdraw/repay) on a safe's behalf
        ILendGateway gateway;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.CashModuleStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CashModuleStorageLocation = 0xe000c7adec5855bcf51f74b73aa86172d0a325bc54c3f73cb406d259df90ea00;

    /// @notice Role identifier for EtherFi wallet access control
    bytes32 public constant ETHER_FI_WALLET_ROLE = keccak256("ETHER_FI_WALLET_ROLE");
    /// @notice Role identifier for Cash Moudle controller access control
    bytes32 public constant CASH_MODULE_CONTROLLER_ROLE = keccak256("CASH_MODULE_CONTROLLER_ROLE");
    /// @notice Limit for maximum cashback percentage at 10%
    uint256 public constant MAX_CASHBACK_PERCENTAGE = 1000; // 10%
    /// @notice 100% in bps
    uint256 public constant HUNDRED_PERCENT_IN_BPS = 10_000;

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

    /// @notice Error thrown when a lend-market operation targets a safe on the legacy DebtManager engine
    error OnlyLendGatewaySafe();

    /// @notice Error thrown when a non-DebtManager contract calls restricted functions
    error OnlyDebtManager();

    /// @notice Error thrown when a recipient address is set to zero
    error RecipientCannotBeAddressZero();

    /// @notice Error thrown when a function restricted to the Cash Module Controller is called by another address
    error OnlyCashModuleController();

    /// @notice Error thrown when attempting to process a withdrawal before the delay period has elapsed
    error CannotWithdrawYet();

    /// @notice Error thrown when transaction or withdrawal signatures are invalid or unauthorized
    error InvalidSignatures();

    /// @notice Error thrown when attempting to set a mode that is already active
    error ModeAlreadySet();

    /// @notice Error thrown when trying to change a safe's tier to its current tier
    /// @param index The index of the safe for which tier that is the same
    error AlreadyInSameTier(uint256 index);

    /// @notice Error thrown when a cashback percentage exceeds the maximum allowed value
    error CashbackPercentageGreaterThanMaxAllowed();

    /// @notice Error thrown when attempting to set a split ratio that is identical to the current split
    error SplitAlreadyTheSame();

    /// @notice Error thrown when trying to use multiple tokens in credit mode
    error OnlyOneTokenAllowedInCreditMode();

    /// @notice Error thrown when Settlement Dispatcher address is not set for the bin sponsor
    error SettlementDispatcherNotSetForBinSponsor();

    /// @notice Error thrown when trying to withdraw an non whitelisted asset
    /// @param asset The address of the invalid asset
    error InvalidWithdrawAsset(address asset);

    /// @notice Error thrown when a withdrawal request is made by a module that is not whitelisted
    error OnlyWhitelistedModuleCanRequestWithdraw();

    /// @notice Error thrown when a module tries to process a withdrawal that was not requested by it
    error OnlyModuleThatRequestedCanWithdraw();

    /// @notice Error thrown when a module tries to cancel a withdrawal that was not requested by it
    error OnlyModuleThatRequestedCanCancel();

    /// @notice Error thrown when a withdrawal request does not exist for a safe
    error WithdrawalDoesNotExist();

    /// @notice Error thrown when a module is not whitelisted on the data provider
    error ModuleNotWhitelistedOnDataProvider();

    /// @notice Error thrown when a withdrawal request is made by an invalid address or to an invalid recipient
    error InvalidWithdrawRequest();

    /// @notice Error thrown when attempting to configure the Aave gateway after the initial bootstrap
    error GatewayAlreadySet();
    /// @notice Error thrown when a lend op is attempted while the safe has opted out of lend
    error LendOptedOut();
    /// @notice Error thrown when opting out of lend while the safe still has open borrows
    error HasOpenBorrows();
    /// @notice Error thrown when executing a lend opt-out that was never requested
    error NoPendingLendOptOut();
    /// @notice Error thrown when executing a lend opt-out before its delay has elapsed
    error LendOptOutNotReady();
    /// @notice Error thrown when opting out while already opted out, or when a request is already pending
    error LendAlreadyOptedOut();
    /// @notice Error thrown when enabling lend that is already enabled
    error LendNotOptedOut();
    /// @notice Error thrown when the lend gateway has not been configured
    error LendGatewayNotSet();

    constructor(address _etherFiDataProvider) ModuleBase(_etherFiDataProvider) {
        _disableInitializers();
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
     * @notice Gets the debt manager contract
     * @return IDebtManager instance
     */
    function _getDebtManager() internal view returns (IDebtManager) {
        return _getCashModuleStorage().debtManager;
    }

    /**
     * @notice Whether the safe's borrow/collateral engine is the Aave gateway (vs the legacy DebtManager)
     * @dev The canonical routing flag: every engine-touching path must branch on this and nothing else.
     * @param safe Address of the EtherFi Safe
     * @return True if the safe uses the Aave gateway
     */
    function _usesLendGateway(address safe) internal view returns (bool) {
        return _getCashModuleStorage().safeCashConfig[safe].usesLendGateway;
    }

    /**
     * @dev Cancels pending withdrawal requests for a Safe; the logic lives in CashLendLib for code size
     * @param safe Address of the EtherFi Safe
     */
    function _cancelOldWithdrawal(address safe) internal {
        CashLendLib.cancelOldWithdrawal(_getCashModuleStorage(), etherFiDataProvider, safe);
    }

    /**
     * @dev Modifier to ensure caller has the EtherFi wallet role
     * @custom:throws OnlyEtherFiWallet if caller does not have the role
     */
    modifier onlyEtherFiWallet() {
        if (!roleRegistry().hasRole(ETHER_FI_WALLET_ROLE, msg.sender)) revert OnlyEtherFiWallet();
        _;
    }

    /**
     * @notice Updates the current mode of a safe if a pending mode change is ready
     * @dev Checks if a pending credit mode change has passed its delay and applies it
     * @param $ Storage reference to the SafeCashConfig for the safe
     */
    function _setCurrentMode(SafeCashConfig storage $) internal {
        if ($.incomingModeStartTime != 0 && block.timestamp > $.incomingModeStartTime) {
            $.mode = $.incomingMode;
            delete $.incomingModeStartTime;
            delete $.incomingMode;
        }
    }

    /**
     * @dev Checks if assets are whitelisted withdraw assets
     * @param $ Storage reference to the SafeCashConfig for the safe
     * @param tokens Array of token addresses to check
     * @custom:throws InvalidWithdrawAsset if an asset is not whitelisted for withdrawals
     */
    function _areAssetsWithdrawable(CashModuleStorage storage $, address[] memory tokens) internal view {
        uint256 len = tokens.length;

        for (uint256 i = 0; i < len;) {
            if (!$.whitelistedWithdrawAssets.contains(tokens[i])) revert InvalidWithdrawAsset(tokens[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Processes a pending withdrawal request for a Safe after delay period
     * @dev Transfers tokens to the designated recipient if the finalize time has passed
     * @param safe Address of the EtherFi Safe processing the withdrawal
     * @custom:throws CannotWithdrawYet if the withdrawal delay period has not elapsed
     */
    function _processWithdrawal(address safe) internal {
        CashModuleStorage storage $ = _getCashModuleStorage();
        SafeCashConfig storage $$ = _getCashModuleStorage().safeCashConfig[safe];

        // Ensure that the withdrawal request exists
        if ($$.pendingWithdrawalRequest.tokens.length == 0) revert WithdrawalDoesNotExist();

        if ($$.pendingWithdrawalRequest.finalizeTime > block.timestamp) revert CannotWithdrawYet();
        // Ensure that if the recipient of withdrawal is a whitelisted withdrawal module, only that module can process the withdrawal
        if ($.whitelistedModulesCanRequestWithdraw.contains($$.pendingWithdrawalRequest.recipient)) {
            if (msg.sender != $$.pendingWithdrawalRequest.recipient) revert OnlyModuleThatRequestedCanWithdraw();
        }
        _areAssetsWithdrawable($, $$.pendingWithdrawalRequest.tokens);

        address recipient = $$.pendingWithdrawalRequest.recipient;
        uint256 len = $$.pendingWithdrawalRequest.tokens.length;

        address[] memory to = new address[](len);
        bytes[] memory data = new bytes[](len);

        for (uint256 i = 0; i < len;) {
            to[i] = $$.pendingWithdrawalRequest.tokens[i];
            data[i] = abi.encodeWithSelector(IERC20.transfer.selector, recipient, $$.pendingWithdrawalRequest.amounts[i]);

            unchecked {
                ++i;
            }
        }

        IEtherFiSafe(safe).execTransactionFromModule(to, new uint256[](len), data);
        _getCashModuleStorage().cashEventEmitter.emitWithdrawalProcessed(safe, $$.pendingWithdrawalRequest.tokens, $$.pendingWithdrawalRequest.amounts, recipient);

        delete $$.pendingWithdrawalRequest;

        // Legacy safes only: see _requestWithdrawal. Gateway safes are health-gated by Aave at request time
        // and would revert here if DebtManager cannot price a supplied Aave asset.
        if (!_usesLendGateway(safe)) $.debtManager.ensureHealth(safe);
    }
}
