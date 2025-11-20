// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";
import { Constants } from "../utils/Constants.sol";

/**
 * @title Physical Card SettlementDispatcher
 * @notice Physical Card Escrow that receives funds from CashModule spend function and returns them once they reach the membership points threshold
 * @dev Tracks payment states per safe and provides admin functions for withdrawal and refunds
 */
contract PhysicalCardSettlementDispatcher is UpgradeableProxy, Constants {
    using SafeERC20 for IERC20;

    /**
     * @notice Payment state enum
     */
    enum PaymentState {
        NoPayment,      // 0 - No payment received
        Payment,        // 1 - Payment received and held in escrow
        PaymentRefunded // 2 - Payment was refunded to user
    }

    /**
     * @notice Payment information for a safe
     */
    struct PaymentInfo {
        PaymentState state;
        address paymentToken;
        uint256 amount;
    }

    /**
     * @notice Contract admin
     */
    bytes32 public constant PHYSICAL_CARD_ADMIN_ROLE = keccak256("PHYSICAL_CARD_ADMIN_ROLE");

    /**
     * @notice BE key with the ability to refund users
     */
    bytes32 public constant PHYSICAL_CARD_REFUND_ROLE = keccak256("PHYSICAL_CARD_REFUND_ROLE");

    /**
     * @notice Instance of the EtherFiDataProvider 
     */
    IEtherFiDataProvider public immutable dataProvider;

    /// @custom:storage-location erc7201:etherfi.storage.EscrowSettlementDispatcher
    /**
     * @dev Storage struct for EscrowSettlementDispatcher (follows ERC-7201 naming convention)
     */
    struct EscrowSettlementDispatcherStorage {
        /// @notice Mapping of safe address to payment information
        mapping(address safe => PaymentInfo) payments;
        /// @notice Total amount of each token held in escrow
        mapping(address => uint256) totalEscrowed;
    }

    /**
     * @notice Storage location for EscrowSettlementDispatcher (ERC-7201 compliant)
     * @dev keccak256(abi.encode(uint256(keccak256("etherfi.storage.EscrowSettlementDispatcher")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32 private constant EscrowSettlementDispatcherStorageLocation = 0xf904ac565180ef91228b22b0f57e8e0feebdc79e25f18f5f1c3c7ac80f958900;

    /**
     * @notice Emitted when tokens are received from a safe
     * @param safe Address of the safe that sent the payment
     * @param token Address of the token received
     * @param amount Amount of tokens received
     */
    event PaymentReceived(address indexed safe, address indexed token, uint256 amount);

    /**
     * @notice Emitted when a payment is refunded to a safe
     * @param safe Address of the safe receiving the refund
     * @param token Address of the token refunded
     * @param amount Amount of tokens refunded
     */
    event PaymentRefunded(address indexed safe, address indexed token, uint256 amount);

    /**
     * @notice Emitted when funds are withdrawn by admin
     * @param token Address of the token withdrawn (address(0) for ETH)
     * @param amount Amount withdrawn
     * @param recipient Address that received the funds
     */
    event FundsWithdrawn(address indexed token, uint256 amount, address indexed recipient);

    /**
     * @notice Thrown when an invalid input is provided
     */
    error InvalidInput();

    /**
     * @notice Thrown when a payment already exists for a safe
     */
    error PaymentAlreadyExists();

    /**
     * @notice Thrown when no payment exists for a safe
     */
    error NoPaymentExists();

    /**
     * @notice Thrown when payment state is invalid for the operation
     */
    error InvalidPaymentState();

    /**
     * @notice Thrown when attempting to withdraw zero amount
     */
    error CannotWithdrawZeroAmount();

    /**
     * @notice Thrown when ETH transfer fails
     */
    error WithdrawFundsFailed();

    /**
     * @notice Thrown when a function is called by an account other than the Cash Module
     */
    error OnlyCashModule();

    /**
     * @notice Constructor that disables initializers
     * @param _dataProvider Address of the EtherFi data provider
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _dataProvider) {
        _disableInitializers();
        if (_dataProvider == address(0)) revert InvalidInput();
        dataProvider = IEtherFiDataProvider(_dataProvider);
    }

    /**
     * @notice Initializes the contract with role registry
     * @param _roleRegistry Address of the role registry contract
     */
    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
    }

    /**
     * @dev Returns the storage struct for EscrowSettlementDispatcher
     * @return $ Reference to the EscrowSettlementDispatcherStorage struct
     */
    function _getEscrowSettlementDispatcherStorage() internal pure returns (EscrowSettlementDispatcherStorage storage $) {
        assembly {
            $.slot := EscrowSettlementDispatcherStorageLocation
        }
    }

    /**
     * @notice Records a payment received from CashModule spend function
     * @dev Called by CashModule after tokens have been transferred from Safe to this contract
     *      CashModule transfers tokens via Safe's execTransactionFromModule, then calls this to record the payment
     *      Only callable by the CashModule contract
     * @param safe Address of the safe that sent the payment
     * @param token Address of the token that was received
     * @param amount Amount of tokens that were received
     * @custom:throws OnlyCashModule if caller is not the CashModule
     * @custom:throws InvalidInput if any parameter is invalid
     * @custom:throws PaymentAlreadyExists if a payment already exists for this safe
     */
    function receivePayment(address safe, address token, uint256 amount) external {
        if (msg.sender != dataProvider.getCashModule()) revert OnlyCashModule();
        if (safe == address(0) || token == address(0) || amount == 0) revert InvalidInput();

        EscrowSettlementDispatcherStorage storage $ = _getEscrowSettlementDispatcherStorage();
        
        if ($.payments[safe].state != PaymentState.NoPayment) revert PaymentAlreadyExists();

        $.payments[safe] = PaymentInfo({
            state: PaymentState.Payment,
            paymentToken: token,
            amount: amount
        });

        $.totalEscrowed[token] += amount;

        emit PaymentReceived(safe, token, amount);
    }

    /**
     * @notice Gets payment information for a safe
     * @param safe Address of the safe
     * @return PaymentInfo struct containing payment state, token, and amount
     */
    function getPayment(address safe) external view returns (PaymentInfo memory) {
        return _getEscrowSettlementDispatcherStorage().payments[safe];
    }

    /**
     * @notice Gets total amount of a token held in escrow (in Payment state)
     * @param token Address of the token to query
     * @return Total amount currently held in escrow (Payment state)
     * @dev This returns the total escrowed amount. To get amounts by state for all safes,
     *      off-chain indexing of PaymentReceived and PaymentRefunded events is recommended.
     */
    function getEscrowedAmount(address token) external view returns (uint256) {
        return _getEscrowSettlementDispatcherStorage().totalEscrowed[token];
    }

    /**
     * @notice Processes a refund for a safe when user reaches membership points threshold
     * @dev Only callable by BE key with PHYSICAL_CARD_REFUND_ROLE
     * @param safe Address of the safe to refund
     * @custom:throws NoPaymentExists if no payment exists for the safe
     * @custom:throws InvalidPaymentState if payment is not in Payment state
     */
    function processRefund(address safe) external nonReentrant onlyRole(PHYSICAL_CARD_REFUND_ROLE) {
        if (safe == address(0)) revert InvalidInput();

        EscrowSettlementDispatcherStorage storage $ = _getEscrowSettlementDispatcherStorage();
        PaymentInfo storage paymentInfo = $.payments[safe];

        if (paymentInfo.state == PaymentState.NoPayment) revert NoPaymentExists();
        if (paymentInfo.state != PaymentState.Payment) revert InvalidPaymentState();

        address token = paymentInfo.paymentToken;
        uint256 amount = paymentInfo.amount;

        paymentInfo.state = PaymentState.PaymentRefunded;
        $.totalEscrowed[token] -= amount;

        IERC20(token).safeTransfer(safe, amount);

        emit PaymentRefunded(safe, token, amount);
    }

    /**
     * @notice Withdraws funds from the contract to pay for shipping costs
     * @dev Only callable by accounts with PHYSICAL_CARD_ADMIN_ROLE
     * @param token Address of the token to withdraw (address(0) for ETH)
     * @param recipient Address to send the withdrawn funds to
     * @param amount Amount to withdraw (0 to withdraw all available)
     * @custom:throws InvalidInput if recipient is address(0)
     * @custom:throws CannotWithdrawZeroAmount if attempting to withdraw zero
     * @custom:throws WithdrawFundsFailed if ETH transfer fails
     * @custom:throws Unauthorized if caller doesn't have PHYSICAL_CARD_ADMIN_ROLE
     */
    function withdrawFunds(address token, address recipient, uint256 amount) external nonReentrant onlyRole(PHYSICAL_CARD_ADMIN_ROLE) {
        if (recipient == address(0)) revert InvalidInput();
        amount = _withdrawFunds(token, recipient, amount);
        emit FundsWithdrawn(token, amount, recipient);
    }

    /**
     * @notice Internal function to handle withdrawal of tokens or ETH
     * @param token Address of the token to withdraw 
     * @param recipient Address to receive the withdrawn funds
     * @param amount Amount to withdraw (0 to withdraw all available balance)
     * @return The amount withdrawn
     * @custom:throws CannotWithdrawZeroAmount if attempting to withdraw zero tokens or ETH
     * @custom:throws WithdrawFundsFailed if ETH transfer fails
     */
    function _withdrawFunds(address token, address recipient, uint256 amount) internal returns (uint256) {
        if (token == ETH) {
            if (amount == 0) amount = address(this).balance;
            if (amount == 0) revert CannotWithdrawZeroAmount();
            (bool success, ) = payable(recipient).call{value: amount}("");
            if (!success) revert WithdrawFundsFailed();
        } else {
            if (amount == 0) amount = IERC20(token).balanceOf(address(this));
            if (amount == 0) revert CannotWithdrawZeroAmount();
            IERC20(token).safeTransfer(recipient, amount);
        }

        return amount;
    }

    /**
     * @notice Fallback function to receive ETH
     */
    receive() external payable {}
}

