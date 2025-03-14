// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ICashModule } from "../interfaces/ICashModule.sol";
import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { IPriceProvider } from "../interfaces/IPriceProvider.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title CashbackDispatcher
 * @author ether.fi
 * @notice This contract dispatches cashback to ether.fi cash users
 * @dev Implements upgradeable proxy pattern and role-based access control for cashback distribution
 */
contract CashbackDispatcher is UpgradeableProxy {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @notice Constant representing 100% in basis points (10,000)
    uint256 public constant HUNDRED_PERCENT_IN_BPS = 10_000;
    
    /// @notice Role identifier for administrative privileges over the cashback dispatcher
    bytes32 public constant CASHBACK_DISPATCHER_ADMIN_ROLE = keccak256("CASHBACK_DISPATCHER_ADMIN_ROLE");
    
    /// @notice Reference to the ether.fi data provider contract
    IEtherFiDataProvider public immutable etherFiDataProvider;

    /// @custom:storage-location erc7201:etherfi.storage.CashbackDispatcher
    struct CashbackDispatcherStorage {
        /// @notice Reference to the Cash Module contract
        ICashModule cashModule;
        /// @notice Reference to the Price Provider contract
        IPriceProvider priceProvider;
        /// @notice Address of the token used for cashback payments
        address cashbackToken;
    }

    /**
     * @notice Storage location for CashbackDispatcher (ERC-7201 compliant)
     * @dev keccak256(abi.encode(uint256(keccak256("etherfi.storage.CashbackDispatcher")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32 private constant CashbackDispatcherLocation = 0xa811d98743cf5c2254d5b85d74a3edcffad2f9de84faa2d8191ebc4345a03b00;

    /**
     * @notice Emitted when the Cash Module address is updated
     * @param oldModule Previous Cash Module address
     * @param newModule New Cash Module address
     */
    event CashModuleSet(address oldModule, address newModule);
    
    /**
     * @notice Emitted when the Price Provider address is updated
     * @param oldPriceProvider Previous Price Provider address
     * @param newPriceProvider New Price Provider address
     */
    event PriceProviderSet(address oldPriceProvider, address newPriceProvider);
    
    /**
     * @notice Emitted when the cashback token address is updated
     * @param oldToken Previous cashback token address
     * @param newToken New cashback token address
     */
    event CashbackTokenSet(address oldToken, address newToken);

    /**
     * @notice Thrown when the price of the cashback token is not configured in the price provider
     */
    error CashbackTokenPriceNotConfigured();
    
    /**
     * @notice Thrown when a zero or invalid address is provided
     */
    error InvalidValue();
    
    /**
     * @notice Thrown when an operation requires an ether.fi safe but account is not one
     */
    error OnlyEtherFiSafe();
    
    /**
     * @notice Thrown when attempting to withdraw zero tokens or ETH
     */
    error CannotWithdrawZeroAmount();
    
    /**
     * @notice Thrown when a withdrawal of funds fails
     */
    error WithdrawFundsFailed();
    
    /**
     * @notice Thrown when a function is called by an account other than the Cash Module
     */
    error OnlyCashModule();
    
    /**
     * @notice Thrown when invalid input parameters are provided
     */
    error InvalidInput();

    /**
     * @notice Constructor that sets the data provider and disables initializers
     * @dev Cannot be called again after deployment (UUPS pattern)
     * @param dataProvider Address of the ether.fi data provider contract
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address dataProvider) {
        etherFiDataProvider = IEtherFiDataProvider(dataProvider);
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with required addresses and configurations
     * @dev Can only be called once due to initializer modifier
     * @param _roleRegistry Address of the role registry contract
     * @param _cashModule Address of the Cash Module contract
     * @param _priceProvider Address of the Price Provider contract
     * @param _cashbackToken Address of the token to be used for cashback
     * @custom:throws InvalidValue When any address parameter is zero
     * @custom:throws CashbackTokenPriceNotConfigured When the cashback token has no price configured
     */
    function initialize(address _roleRegistry, address _cashModule, address _priceProvider, address _cashbackToken) external initializer {
        if (_cashModule == address(0) || _priceProvider == address(0) || _cashbackToken == address(0)) revert InvalidValue();

        __UpgradeableProxy_init(_roleRegistry);

        CashbackDispatcherStorage storage $ = _getCashbackDispatcherStorage();

        $.cashModule = ICashModule(_cashModule);
        $.priceProvider = IPriceProvider(_priceProvider);

        if ($.priceProvider.price(_cashbackToken) == 0) revert CashbackTokenPriceNotConfigured();
        $.cashbackToken = _cashbackToken;

        emit CashModuleSet(address(0), _cashModule);
        emit PriceProviderSet(address(0), _priceProvider);
        emit CashbackTokenSet(address(0), _cashbackToken);
    }

    /**
     * @dev Returns the storage struct for CashbackDispatcherStorage
     * @return $ Reference to the CashbackDispatcherStorage struct
     */
    function _getCashbackDispatcherStorage() internal pure returns (CashbackDispatcherStorage storage $) {
        assembly {
            $.slot := CashbackDispatcherLocation
        }
    }

    /**
     * @notice Returns the address of the Price Provider contract
     * @return Address of the Price Provider contract
     */
    function priceProvider() external view returns (address) {
        return address(_getCashbackDispatcherStorage().priceProvider);
    }

    /**
     * @notice Returns the address of the Cash Module contract
     * @return Address of the Cash Module contract
     */
    function cashModule() external view returns (address) {
        return address(_getCashbackDispatcherStorage().cashModule);
    }

    /**
     * @notice Returns the address of the token used for cashback
     * @return Address of the cashback token
     */
    function cashbackToken() external view returns (address) {
        return address(_getCashbackDispatcherStorage().cashbackToken);
    }
    
    /**
     * @notice Converts a USD amount to the equivalent value in cashback tokens
     * @dev Uses the price provider to get the current exchange rate
     * @param cashbackInUsd The amount of cashback in USD (with decimals)
     * @return The equivalent amount in cashback tokens
     */
    function convertUsdToCashbackToken(uint256 cashbackInUsd) public view returns (uint256) {
        if (cashbackInUsd == 0) return 0;

        CashbackDispatcherStorage storage $ = _getCashbackDispatcherStorage();

        uint256 cashbackTokenPrice = $.priceProvider.price($.cashbackToken);
        return cashbackInUsd.mulDiv(10 ** IERC20Metadata($.cashbackToken).decimals(), cashbackTokenPrice);
    }

    /**
     * @notice Calculates the cashback amount based on the spent amount and cashback percentage
     * @param cashbackPercentageInBps The cashback percentage in basis points (100% = 10,000)
     * @param spentAmountInUsd The amount spent in USD (with decimals)
     * @return The cashback amount in token units and the cashback amount in USD
     */
    function getCashbackAmount(uint256 cashbackPercentageInBps, uint256 spentAmountInUsd) public view returns (uint256, uint256) {
        uint256 cashbackInUsd = spentAmountInUsd.mulDiv(cashbackPercentageInBps, HUNDRED_PERCENT_IN_BPS);
        return (convertUsdToCashbackToken(cashbackInUsd), cashbackInUsd);
    }

    /**
     * @notice Processes cashback for a transaction, splitting between safe and spender if applicable
     * @dev Can only be called by the Cash Module contract
     * @param safe The address of the ether.fi safe receiving the cashback
     * @param spender The address of the spender who initiated the transaction
     * @param spentAmountInUsd The amount spent in USD (with decimals)
     * @param cashbackPercentageInBps The cashback percentage in basis points (100% = 10,000)
     * @param cashbackSplitToSafePercentage The percentage of cashback going to the safe (100% = 10,000)
     * @return token The address of the cashback token
     * @return cashbackAmountToSafe The amount of tokens sent to the safe
     * @return cashbackInUsdToSafe The USD value of tokens sent to the safe
     * @return cashbackAmountToSpender The amount of tokens sent to the spender
     * @return cashbackInUsdToSpender The USD value of tokens sent to the spender
     * @return paid Whether the cashback was successfully paid
     * @custom:throws OnlyCashModule When called by an account other than the Cash Module
     * @custom:throws OnlyEtherFiSafe When the safe address is not a valid ether.fi safe
     */
    function cashback(address safe, address spender, uint256 spentAmountInUsd, uint256 cashbackPercentageInBps, uint256 cashbackSplitToSafePercentage) external whenNotPaused returns (address token, uint256 cashbackAmountToSafe, uint256 cashbackInUsdToSafe, uint256 cashbackAmountToSpender, uint256 cashbackInUsdToSpender, bool paid) {
        CashbackDispatcherStorage storage $ = _getCashbackDispatcherStorage();
        
        if (msg.sender != address($.cashModule)) revert OnlyCashModule();
        if (!etherFiDataProvider.isEtherFiSafe(safe)) revert OnlyEtherFiSafe();
        if (spender == address(0)) cashbackSplitToSafePercentage = 10_000; // 100%

        token = $.cashbackToken;

        (uint256 cashbackAmountTotal, uint256 cashbackInUsdTotal) = getCashbackAmount(cashbackPercentageInBps, spentAmountInUsd);
        if (cashbackAmountTotal == 0) return ($.cashbackToken, 0, 0, 0, 0, true);

        cashbackAmountToSafe = cashbackAmountTotal.mulDiv(cashbackSplitToSafePercentage, HUNDRED_PERCENT_IN_BPS);
        cashbackInUsdToSafe = cashbackInUsdTotal.mulDiv(cashbackSplitToSafePercentage, HUNDRED_PERCENT_IN_BPS);
        cashbackAmountToSpender = cashbackAmountTotal - cashbackAmountToSafe;
        cashbackInUsdToSpender = cashbackInUsdTotal - cashbackInUsdToSafe;

        if (IERC20(token).balanceOf(address(this)) < cashbackAmountTotal) {
            paid = false;
        } else {
            paid = true;
            if (cashbackAmountToSafe > 0) IERC20(token).safeTransfer(safe, cashbackAmountToSafe);
            if (cashbackAmountToSpender > 0) IERC20(token).safeTransfer(spender, cashbackAmountToSpender);
        }
    }

    function clearPendingCashback(address account) external returns (address, uint256, bool) {
        CashbackDispatcherStorage storage $ = _getCashbackDispatcherStorage();
        
        if (msg.sender != address($.cashModule)) revert OnlyCashModule();
        if (account == address(0)) revert InvalidInput();

        uint256 pendingCashbackInUsd = $.cashModule.getPendingCashback(account);

        uint256 cashbackAmount = convertUsdToCashbackToken(pendingCashbackInUsd);
        if (cashbackAmount == 0) return ($.cashbackToken, 0, true);

        if (IERC20($.cashbackToken).balanceOf(address(this)) < cashbackAmount) {
            return ($.cashbackToken, cashbackAmount, false);
        } else {
            IERC20($.cashbackToken).safeTransfer(account, cashbackAmount);
            return ($.cashbackToken, cashbackAmount, true);
        }
    }

    /**
     * @notice Updates the Cash Module address
     * @dev Only callable by addresses with CASHBACK_DISPATCHER_ADMIN_ROLE
     * @param _cashModule New Cash Module address
     * @custom:throws InvalidValue When the provided address is zero
     */
    function setCashModule(address _cashModule) external onlyRole(CASHBACK_DISPATCHER_ADMIN_ROLE) {
        if (_cashModule == address(0)) revert InvalidValue();

        CashbackDispatcherStorage storage $ = _getCashbackDispatcherStorage();

        emit CashModuleSet(address($.cashModule), _cashModule);
        $.cashModule = ICashModule(_cashModule);
    }

    /**
     * @notice Updates the Price Provider address
     * @dev Only callable by addresses with CASHBACK_DISPATCHER_ADMIN_ROLE
     * @param _priceProvider New Price Provider address
     * @custom:throws InvalidValue When the provided address is zero
     * @custom:throws CashbackTokenPriceNotConfigured When the new provider has no price for the cashback token
     */
    function setPriceProvider(address _priceProvider) external onlyRole(CASHBACK_DISPATCHER_ADMIN_ROLE) {
        if (_priceProvider == address(0)) revert InvalidValue();

        CashbackDispatcherStorage storage $ = _getCashbackDispatcherStorage();

        emit PriceProviderSet(address($.priceProvider), _priceProvider);
        $.priceProvider = IPriceProvider(_priceProvider);

        if ($.priceProvider.price($.cashbackToken) == 0) revert CashbackTokenPriceNotConfigured();
    }

    /**
     * @notice Updates the cashback token address
     * @dev Only callable by addresses with CASHBACK_DISPATCHER_ADMIN_ROLE
     * @param _token New cashback token address
     * @custom:throws InvalidValue When the provided address is zero
     * @custom:throws CashbackTokenPriceNotConfigured When the price provider has no price for the new token
     */
    function setCashbackToken(address _token) external onlyRole(CASHBACK_DISPATCHER_ADMIN_ROLE) {
        if (_token == address(0)) revert InvalidValue();

        CashbackDispatcherStorage storage $ = _getCashbackDispatcherStorage();

        if ($.priceProvider.price(_token) == 0) revert CashbackTokenPriceNotConfigured();
        emit CashbackTokenSet($.cashbackToken, _token);
        $.cashbackToken = _token;
    }

    /**
     * @notice Withdraws tokens or ETH from the contract
     * @dev Only callable by the owner of the role registry
     * @param token Address of the token to withdraw (address(0) for ETH)
     * @param recipient Address to receive the withdrawn funds
     * @param amount Amount to withdraw (0 to withdraw all)
     * @custom:throws InvalidValue When the recipient address is zero
     * @custom:throws CannotWithdrawZeroAmount When attempting to withdraw zero tokens or ETH
     * @custom:throws WithdrawFundsFailed When ETH transfer fails
     */
    function withdrawFunds(address token, address recipient, uint256 amount) external onlyRoleRegistryOwner() {
        if (recipient == address(0)) revert InvalidValue();

        if (token == address(0)) {
            if (amount == 0) amount = address(this).balance;
            if (amount == 0) revert CannotWithdrawZeroAmount();
            (bool success,) = payable(recipient).call{ value: amount }("");
            if (!success) revert WithdrawFundsFailed();
        } else {
            if (amount == 0) amount = IERC20(token).balanceOf(address(this));
            if (amount == 0) revert CannotWithdrawZeroAmount();
            IERC20(token).safeTransfer(recipient, amount);
        }
    }
}