// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControlDefaultAdminRulesUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import { Initializable, UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ICashModule } from "../interfaces/ICashModule.sol";

import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { IPriceProvider } from "../interfaces/IPriceProvider.sol";

/// @title CashbackDispatcher
/// @author shivam@ether.fi
/// @notice This contract dispatches cashback to ether.fi cash users
contract CashbackDispatcher is Initializable, UUPSUpgradeable, AccessControlDefaultAdminRulesUpgradeable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    ICashModule public cashModule;
    IPriceProvider public priceProvider;
    address public cashbackToken;
    IEtherFiDataProvider public etherFiDataProvider;

    uint256 public constant HUNDRED_PERCENT_IN_BPS = 10_000;
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner, address _cashModule, address _priceProvider, address _cashbackToken) external initializer {
        if (_cashModule == address(0) || _priceProvider == address(0) || _cashbackToken == address(0)) revert InvalidValue();

        __AccessControlDefaultAdminRules_init_unchained(5 * 60, _owner);
        _grantRole(ADMIN_ROLE, _owner);

        cashModule = ICashModule(_cashModule);
        priceProvider = IPriceProvider(_priceProvider);

        if (priceProvider.price(_cashbackToken) == 0) revert CashbackTokenPriceNotConfigured();
        cashbackToken = _cashbackToken;

        emit CashModuleSet(address(0), _cashModule);
        emit PriceProviderSet(address(0), _priceProvider);
        emit CashbackTokenSet(address(0), _cashbackToken);
    }

    function initializeOnUpgrade(address _cashModule) external reinitializer(2) {
        cashModule = ICashModule(_cashModule);
        etherFiDataProvider = cashModule.etherFiDataProvider();

        emit CashModuleSet(address(0), _cashModule);
    }

    function convertUsdToCashbackToken(uint256 cashbackInUsd) public view returns (uint256) {
        if (cashbackInUsd == 0) return 0;

        uint256 cashbackTokenPrice = priceProvider.price(cashbackToken);
        return cashbackInUsd.mulDiv(10 ** IERC20Metadata(cashbackToken).decimals(), cashbackTokenPrice);
    }

    function getCashbackAmount(uint256 cashbackPercentageInBps, uint256 spentAmountInUsd) public view returns (uint256, uint256) {
        uint256 cashbackInUsd = spentAmountInUsd.mulDiv(cashbackPercentageInBps, HUNDRED_PERCENT_IN_BPS);
        return (convertUsdToCashbackToken(cashbackInUsd), cashbackInUsd);
    }

    function cashback(address safe, address spender, uint256 spentAmountInUsd, uint256 cashbackPercentageInBps, uint256 cashbackSplitToSafePercentage) external returns (address token, uint256 cashbackAmountToSafe, uint256 cashbackInUsdToSafe, uint256 cashbackAmountToSpender, uint256 cashbackInUsdToSpender, bool paid) {
        if (msg.sender != address(cashModule)) revert OnlyCashModule();
        if (!etherFiDataProvider.isEtherFiSafe(safe)) revert OnlyEtherFiSafe();
        if (spender == address(0)) cashbackSplitToSafePercentage = 10_000; // 100%

        token = cashbackToken;

        (uint256 cashbackAmountTotal, uint256 cashbackInUsdTotal) = getCashbackAmount(cashbackPercentageInBps, spentAmountInUsd);
        if (cashbackAmountTotal == 0) return (cashbackToken, 0, 0, 0, 0, true);

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
        if (account == address(0)) revert InvalidInput();
        uint256 pendingCashbackInUsd = cashModule.getPendingCashback(account);

        uint256 cashbackAmount = convertUsdToCashbackToken(pendingCashbackInUsd);
        if (cashbackAmount == 0) return (cashbackToken, 0, true);

        if (IERC20(cashbackToken).balanceOf(address(this)) < cashbackAmount) {
            return (cashbackToken, cashbackAmount, false);
        } else {
            IERC20(cashbackToken).safeTransfer(msg.sender, cashbackAmount);
            return (cashbackToken, cashbackAmount, true);
        }
    }

    function setCashModule(address _cashModule) external onlyRole(ADMIN_ROLE) {
        if (_cashModule == address(0)) revert InvalidValue();
        emit CashModuleSet(address(cashModule), _cashModule);
        cashModule = ICashModule(_cashModule);
    }

    function setPriceProvider(address _priceProvider) external onlyRole(ADMIN_ROLE) {
        if (_priceProvider == address(0)) revert InvalidValue();

        emit PriceProviderSet(address(priceProvider), _priceProvider);
        priceProvider = IPriceProvider(_priceProvider);

        if (priceProvider.price(cashbackToken) == 0) revert CashbackTokenPriceNotConfigured();
    }

    function setCashbackToken(address _token) external onlyRole(ADMIN_ROLE) {
        if (_token == address(0)) revert InvalidValue();
        if (priceProvider.price(_token) == 0) revert CashbackTokenPriceNotConfigured();
        emit CashbackTokenSet(cashbackToken, _token);
        cashbackToken = _token;
    }

    function withdrawFunds(address token, address recipient, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
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

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }
}
