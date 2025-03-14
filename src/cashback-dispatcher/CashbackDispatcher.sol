// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ICashModule } from "../interfaces/ICashModule.sol";
import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { IPriceProvider } from "../interfaces/IPriceProvider.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/// @title CashbackDispatcher
/// @author shivam@ether.fi
/// @notice This contract dispatches cashback to ether.fi cash users
contract CashbackDispatcher is UpgradeableProxy {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant HUNDRED_PERCENT_IN_BPS = 10_000;
    bytes32 public constant CASHBACK_DISPATCHER_ADMIN_ROLE = keccak256("CASHBACK_DISPATCHER_ADMIN_ROLE");

    IEtherFiDataProvider public immutable etherFiDataProvider;

    /// @custom:storage-location erc7201:etherfi.storage.CashbackDispatcher
    struct CashbackDispatcherStorage {
        ICashModule cashModule;
        IPriceProvider priceProvider;
        address cashbackToken;
    }

    /// @notice Storage location for CashbackDispatcher (ERC-7201 compliant)
    /// @dev keccak256(abi.encode(uint256(keccak256("etherfi.storage.CashbackDispatcher")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CashbackDispatcherLocation = 0xa811d98743cf5c2254d5b85d74a3edcffad2f9de84faa2d8191ebc4345a03b00;

    /**
     * @dev Returns the storage struct for CashbackDispatcherStorage
     * @return $ Reference to the CashbackDispatcherStorage struct
     */
    function _getCashbackDispatcherStorage() internal pure returns (CashbackDispatcherStorage storage $) {
        assembly {
            $.slot := CashbackDispatcherLocation
        }
    }

    event CashModuleSet(address oldModule, address newModule);
    event PriceProviderSet(address oldPriceProvider, address newPriceProvider);
    event CashbackTokenSet(address oldToken, address newToken);

    error CashbackTokenPriceNotConfigured();
    error InvalidValue();
    error OnlyEtherFiSafe();
    error CannotWithdrawZeroAmount();
    error WithdrawFundsFailed();
    error OnlyCashModule();
    error InvalidInput();
    error Unauthorized();
    error OnlyRoleRegistryOwner();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address dataProvider) {
        etherFiDataProvider = IEtherFiDataProvider(dataProvider);
        _disableInitializers();
    }

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
    
    function convertUsdToCashbackToken(uint256 cashbackInUsd) public view returns (uint256) {
        if (cashbackInUsd == 0) return 0;

        CashbackDispatcherStorage storage $ = _getCashbackDispatcherStorage();

        uint256 cashbackTokenPrice = $.priceProvider.price($.cashbackToken);
        return cashbackInUsd.mulDiv(10 ** IERC20Metadata($.cashbackToken).decimals(), cashbackTokenPrice);
    }

    function getCashbackAmount(uint256 cashbackPercentageInBps, uint256 spentAmountInUsd) public view returns (uint256, uint256) {
        uint256 cashbackInUsd = spentAmountInUsd.mulDiv(cashbackPercentageInBps, HUNDRED_PERCENT_IN_BPS);
        return (convertUsdToCashbackToken(cashbackInUsd), cashbackInUsd);
    }

    function cashback(address safe, address spender, uint256 spentAmountInUsd, uint256 cashbackPercentageInBps, uint256 cashbackSplitToSafePercentage) external returns (address token, uint256 cashbackAmountToSafe, uint256 cashbackInUsdToSafe, uint256 cashbackAmountToSpender, uint256 cashbackInUsdToSpender, bool paid) {
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

    function setCashModule(address _cashModule) external onlyRole(CASHBACK_DISPATCHER_ADMIN_ROLE) {
        if (_cashModule == address(0)) revert InvalidValue();

        CashbackDispatcherStorage storage $ = _getCashbackDispatcherStorage();

        emit CashModuleSet(address($.cashModule), _cashModule);
        $.cashModule = ICashModule(_cashModule);
    }

    function setPriceProvider(address _priceProvider) external onlyRole(CASHBACK_DISPATCHER_ADMIN_ROLE) {
        if (_priceProvider == address(0)) revert InvalidValue();

        CashbackDispatcherStorage storage $ = _getCashbackDispatcherStorage();

        emit PriceProviderSet(address($.priceProvider), _priceProvider);
        $.priceProvider = IPriceProvider(_priceProvider);

        if ($.priceProvider.price($.cashbackToken) == 0) revert CashbackTokenPriceNotConfigured();
    }

    function setCashbackToken(address _token) external onlyRole(CASHBACK_DISPATCHER_ADMIN_ROLE) {
        if (_token == address(0)) revert InvalidValue();

        CashbackDispatcherStorage storage $ = _getCashbackDispatcherStorage();

        if ($.priceProvider.price(_token) == 0) revert CashbackTokenPriceNotConfigured();
        emit CashbackTokenSet($.cashbackToken, _token);
        $.cashbackToken = _token;
    }

    function withdrawFunds(address token, address recipient, uint256 amount) external {
        if (roleRegistry().owner() != msg.sender) revert OnlyRoleRegistryOwner();
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

    /**
     * @dev Modifier to restrict access to specific roles
     * @param role Role identifier
     */
    modifier onlyRole(bytes32 role) {
        if (!roleRegistry().hasRole(role, msg.sender)) revert Unauthorized();
        _;
    }
}
