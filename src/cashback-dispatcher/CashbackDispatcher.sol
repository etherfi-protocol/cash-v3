// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { ICashModule, TokenDataInUsd } from "../interfaces/ICashModule.sol";
import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { IPriceProvider } from "../interfaces/IPriceProvider.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";
import { EnumerableAddressWhitelistLib } from "../libraries/EnumerableAddressWhitelistLib.sol";
/**
 * @title CashbackDispatcher
 * @author ether.fi
 * @notice This contract dispatches cashback to ether.fi cash users
 * @dev Implements upgradeable proxy pattern and role-based access control for cashback distribution
 */
contract CashbackDispatcher is UpgradeableProxy {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using EnumerableAddressWhitelistLib for EnumerableSetLib.AddressSet;

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
        address DEPRECATED_cashbackToken;
        /// @notice Addresses of the whitelisted cashback tokens
        EnumerableSetLib.AddressSet whitelistedCashbackTokens;
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
     * @notice Emitted when the cashback tokens are configured
     * @param tokens Addresses of the tokens
     * @param isWhitelisted Whether tokens are whitelisted or removed from whitelist
     */
    event CashbackTokensConfigured(address[] tokens, bool[] isWhitelisted);

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
     * @notice Thrown when the cashback token is not supported
     */
    error InvalidCashbackToken();

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
     * @param _cashbackTokens Addresses of the cashback tokens
     * @custom:throws InvalidValue When any address parameter is zero
     * @custom:throws CashbackTokenPriceNotConfigured When the cashback token has no price configured
     */
    function initialize(address _roleRegistry, address _cashModule, address _priceProvider, address[] calldata _cashbackTokens) external initializer {
        if (_cashModule == address(0) || _priceProvider == address(0)) revert InvalidValue();

        __UpgradeableProxy_init(_roleRegistry);

        CashbackDispatcherStorage storage $ = _getCashbackDispatcherStorage();

        $.cashModule = ICashModule(_cashModule);
        $.priceProvider = IPriceProvider(_priceProvider);
        
        uint256 len = _cashbackTokens.length;

        for (uint256 i = 0; i < len; ) {
            if ($.priceProvider.price(_cashbackTokens[i]) == 0) revert CashbackTokenPriceNotConfigured();
            unchecked {
                ++i;
            }
        }
        
        $.whitelistedCashbackTokens.addToWhitelist(_cashbackTokens);

        emit CashModuleSet(address(0), _cashModule);
        emit PriceProviderSet(address(0), _priceProvider);
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
     * @notice Returns the addresses of the whitelisted cashback tokens
     * @return Addresses of the cashback tokens
     */
    function getCashbackTokens() public view returns (address[] memory) {
        return _getCashbackDispatcherStorage().whitelistedCashbackTokens.values();
    }

    /**
     * @notice Returns true if the token is a whitelisted cashback token, false otherwise
     * @param token Address of the token
     * @return Returns true if the token is a whitelisted cashback token, false otherwise
     */
    function isCashbackToken(address token) public view returns (bool) {
        return _getCashbackDispatcherStorage().whitelistedCashbackTokens.contains(token);
    }
    
    /**
     * @notice Converts a USD amount to the equivalent value in cashback tokens
     * @dev Uses the price provider to get the current exchange rate
     * @param cashbackToken The address of the cashback token
     * @param cashbackInUsd The amount of cashback in USD (with decimals)
     * @return The equivalent amount in cashback tokens
     */
    function convertUsdToCashbackToken(address cashbackToken, uint256 cashbackInUsd) public view returns (uint256) {
        if (!isCashbackToken(cashbackToken)) revert InvalidCashbackToken();

        if (cashbackInUsd == 0) return 0;
        CashbackDispatcherStorage storage $ = _getCashbackDispatcherStorage();

        uint256 cashbackTokenPrice = $.priceProvider.price(cashbackToken);
        return cashbackInUsd.mulDiv(10 ** IERC20Metadata(cashbackToken).decimals(), cashbackTokenPrice);
    }

    /**
     * @notice Process cashback to a recipient
     * @param recipient The address of the recipient
     * @param token The address of the cashback token
     * @param amountInUsd The amount of cashback tokens in USD to be paid out
     * @return cashbackAmountInToken The amount of cashback token sent to the recipient
     * @return paid Whether the cashback was paid successfully
     */
    function cashback(address recipient, address token, uint256 amountInUsd) external whenNotPaused returns (uint256 cashbackAmountInToken, bool paid) {
        CashbackDispatcherStorage storage $ = _getCashbackDispatcherStorage();
        
        if (msg.sender != address($.cashModule)) revert OnlyCashModule();
        cashbackAmountInToken = convertUsdToCashbackToken(token, amountInUsd);
        if (cashbackAmountInToken == 0) return (0, true);

        if (IERC20(token).balanceOf(address(this)) < cashbackAmountInToken) {
            paid = false;
        } else {
            paid = true;
            IERC20(token).safeTransfer(recipient, cashbackAmountInToken);
        }
    } 

    /**
     * @notice Clear pending cashback for an account
     * @param account The address of the account
     * @param token The address of the cashback token
     * @param amountInUsd The amount of cashback in USD for the token
     * @return the amount of cashback in token
     * @return whether it was paid
     */
    function clearPendingCashback(address account, address token, uint256 amountInUsd) external returns (uint256, bool) {
        CashbackDispatcherStorage storage $ = _getCashbackDispatcherStorage();
        
        if (account == address(0)) revert InvalidInput();
        if (msg.sender != address($.cashModule)) revert OnlyCashModule();

        uint256 cashbackAmount = convertUsdToCashbackToken(token, amountInUsd);
        if (cashbackAmount == 0) return (0, true);

        if (IERC20(token).balanceOf(address(this)) < cashbackAmount) {
            return (cashbackAmount, false);
        } else {
            IERC20(token).safeTransfer(account, cashbackAmount);
            return (cashbackAmount, true);
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

        address[] memory cashbackTokens = getCashbackTokens();
        uint256 len = cashbackTokens.length;
        
        for (uint256 i = 0; i < len; ) {
            if (IPriceProvider(_priceProvider).price(cashbackTokens[i]) == 0) revert CashbackTokenPriceNotConfigured();
            unchecked {
                ++i;
            }
        }

        CashbackDispatcherStorage storage $ = _getCashbackDispatcherStorage();

        emit PriceProviderSet(address($.priceProvider), _priceProvider);
        $.priceProvider = IPriceProvider(_priceProvider);
    }

    /**
     * @notice Updates the cashback token address
     * @dev Only callable by addresses with CASHBACK_DISPATCHER_ADMIN_ROLE
     * @param tokens Addresses of the cashback tokens
     * @param shouldWhitelist Whether to whitelist the respective token
     * @custom:throws CashbackTokenPriceNotConfigured When the price provider has no price for the new token
     */
    function configureCashbackToken(address[] calldata tokens, bool[] calldata shouldWhitelist) external onlyRole(CASHBACK_DISPATCHER_ADMIN_ROLE) {
        CashbackDispatcherStorage storage $ = _getCashbackDispatcherStorage();
        
        uint256 len = tokens.length;
        for (uint256 i = 0; i < len; ) {
            if ($.priceProvider.price(tokens[i]) == 0) revert CashbackTokenPriceNotConfigured();
            unchecked {
                ++i;
            }
        }
        $.whitelistedCashbackTokens.configure(tokens, shouldWhitelist);
        emit CashbackTokensConfigured(tokens, shouldWhitelist);
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