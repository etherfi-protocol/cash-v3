// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IPriceProvider } from "../interfaces/IPriceProvider.sol";
import { DebtManagerStorageContract } from "./DebtManagerStorageContract.sol";

/**
 * @title DebtManagerAdmin
 * @author ether.fi
 * @notice Administrative contract for managing the Debt Manager system
 * @dev Handles admin functions like token support/removal and configuration updates
 */
contract DebtManagerAdmin is DebtManagerStorageContract {
    /**
     * @dev Constructor that initializes the base DebtManagerStorageContract
     * @param dataProvider Address of the EtherFi data provider
     */
    constructor(address dataProvider) DebtManagerStorageContract(dataProvider) {}

    /**
     * @notice Adds a new collateral token with its configuration
     * @dev Can only be called by accounts with DEBT_MANAGER_ADMIN_ROLE
     * @param token Address of the token to add as collateral
     * @param config Configuration parameters for the collateral token
     */
    function supportCollateralToken(address token, CollateralTokenConfig calldata config) external onlyRole(DEBT_MANAGER_ADMIN_ROLE) {
        _supportCollateralToken(token);
        _setCollateralTokenConfig(token, config);
    }

    /**
     * @notice Removes a collateral token from the supported list
     * @dev Can only be called by accounts with DEBT_MANAGER_ADMIN_ROLE
     * @param token Address of the collateral token to remove
     */
    function unsupportCollateralToken(address token) external onlyRole(DEBT_MANAGER_ADMIN_ROLE) {
        DebtManagerStorage storage $ = _getDebtManagerStorage();

        if (token == address(0)) revert InvalidValue();
        if (isBorrowToken(token)) revert BorrowTokenCannotBeRemovedFromCollateral();
        uint256 indexPlusOneForTokenToBeRemoved = $.collateralTokenIndexPlusOne[token];
        if (indexPlusOneForTokenToBeRemoved == 0) revert NotACollateralToken();

        uint256 len = $.supportedCollateralTokens.length;
        if (len == 1) revert NoCollateralTokenLeft();

        $.collateralTokenIndexPlusOne[$.supportedCollateralTokens[len - 1]] = indexPlusOneForTokenToBeRemoved;
        $.supportedCollateralTokens[indexPlusOneForTokenToBeRemoved - 1] = $.supportedCollateralTokens[len - 1];
        $.supportedCollateralTokens.pop();
        delete $.collateralTokenIndexPlusOne[token];

        CollateralTokenConfig memory config;
        _setCollateralTokenConfig(token, config);

        emit CollateralTokenRemoved(token);
    }

    /**
     * @notice Adds a token to the supported borrow tokens list
     * @dev Token must already be a supported collateral token
     * @param token Address of the token to add as a borrow token
     * @param borrowApy Annual percentage yield for borrowing this token (per second)
     * @param minShares Minimum shares required for this token
     */
    function supportBorrowToken(address token, uint64 borrowApy, uint128 minShares) external onlyRole(DEBT_MANAGER_ADMIN_ROLE) {
        if (!isCollateralToken(token)) revert NotACollateralToken();
        _supportBorrowToken(token);
        _setBorrowTokenConfig(token, borrowApy, minShares);
    }

    /**
     * @notice Removes a token from the supported borrow tokens list
     * @dev All borrowed tokens must be repaid before removal
     * @param token Address of the borrow token to remove
     */
    function unsupportBorrowToken(address token) external onlyRole(DEBT_MANAGER_ADMIN_ROLE) {
        DebtManagerStorage storage $ = _getDebtManagerStorage();
        uint256 indexPlusOneForTokenToBeRemoved = $.borrowTokenIndexPlusOne[token];
        if (indexPlusOneForTokenToBeRemoved == 0) revert NotABorrowToken();

        if (_getTotalBorrowTokenAmount(token) != 0) {
            revert BorrowTokenStillInTheSystem();
        }

        uint256 len = $.supportedBorrowTokens.length;
        if (len == 1) revert NoBorrowTokenLeft();

        $.borrowTokenIndexPlusOne[$.supportedBorrowTokens[len - 1]] = indexPlusOneForTokenToBeRemoved;
        $.supportedBorrowTokens[indexPlusOneForTokenToBeRemoved - 1] = $.supportedBorrowTokens[len - 1];
        $.supportedBorrowTokens.pop();
        delete $.borrowTokenIndexPlusOne[token];
        delete $.borrowTokenConfig[token];

        emit BorrowTokenRemoved(token);
    }

    /**
     * @notice Updates the configuration for a collateral token
     * @dev Can only be called by accounts with DEBT_MANAGER_ADMIN_ROLE
     * @param __collateralToken Address of the collateral token to update
     * @param __config New configuration parameters for the collateral token
     */
    function setCollateralTokenConfig(address __collateralToken, CollateralTokenConfig memory __config) external onlyRole(DEBT_MANAGER_ADMIN_ROLE) {
        _setCollateralTokenConfig(__collateralToken, __config);
    }

    /**
     * @notice Updates the borrow APY for a token
     * @dev Can only be called by accounts with DEBT_MANAGER_ADMIN_ROLE
     * @param token Address of the token to update
     * @param apy New annual percentage yield (per second)
     */
    function setBorrowApy(address token, uint64 apy) external onlyRole(DEBT_MANAGER_ADMIN_ROLE) {
        _setBorrowApy(token, apy);
    }

    /**
     * @notice Updates the minimum required shares for a borrow token
     * @dev Can only be called by accounts with DEBT_MANAGER_ADMIN_ROLE
     * @param token Address of the token to update
     * @param shares New minimum shares value
     */
    function setMinBorrowTokenShares(address token, uint128 shares) external onlyRole(DEBT_MANAGER_ADMIN_ROLE) {
        _setMinBorrowTokenShares(token, shares);
    }

    /**
     * @dev Internal function to add a token to the supported collateral tokens list
     * @param token Address of the token to add
     */
    function _supportCollateralToken(address token) internal {
        if (token == address(0)) revert InvalidValue();

        DebtManagerStorage storage $ = _getDebtManagerStorage();

        if ($.collateralTokenIndexPlusOne[token] != 0) revert AlreadyCollateralToken();

        uint256 price = IPriceProvider(etherFiDataProvider.getPriceProvider()).price(token);
        if (price == 0) revert OraclePriceZero();

        $.supportedCollateralTokens.push(token);
        $.collateralTokenIndexPlusOne[token] = $.supportedCollateralTokens.length;

        emit CollateralTokenAdded(token);
    }

    /**
     * @dev Internal function to add a token to the supported borrow tokens list
     * @param token Address of the token to add
     */
    function _supportBorrowToken(address token) internal {
        if (token == address(0)) revert InvalidValue();

        DebtManagerStorage storage $ = _getDebtManagerStorage();

        if ($.borrowTokenIndexPlusOne[token] != 0) revert AlreadyBorrowToken();

        $.supportedBorrowTokens.push(token);
        $.borrowTokenIndexPlusOne[token] = $.supportedBorrowTokens.length;

        emit BorrowTokenAdded(token);
    }

    /**
     * @dev Internal function to set or update the configuration for a collateral token
     * @param collateralToken Address of the collateral token
     * @param config Configuration parameters to set
     */
    function _setCollateralTokenConfig(address collateralToken, CollateralTokenConfig memory config) internal {
        if (config.ltv > config.liquidationThreshold) revert LtvCannotBeGreaterThanLiquidationThreshold();
        if (config.liquidationThreshold + config.liquidationBonus > HUNDRED_PERCENT) revert InvalidValue();

        DebtManagerStorage storage $ = _getDebtManagerStorage();

        emit CollateralTokenConfigSet(collateralToken, $.collateralTokenConfig[collateralToken], config);
        $.collateralTokenConfig[collateralToken] = config;
    }

    /**
     * @dev Internal function to set the initial configuration for a borrow token
     * @param borrowToken Address of the borrow token
     * @param borrowApy Annual percentage yield for borrowing (per second)
     * @param minShares Minimum shares required for this token
     */
    function _setBorrowTokenConfig(address borrowToken, uint64 borrowApy, uint128 minShares) internal {
        if (borrowApy == 0 || borrowApy > MAX_BORROW_APY || minShares == 0) revert InvalidValue();

        DebtManagerStorage storage $ = _getDebtManagerStorage();

        BorrowTokenConfig memory cfg = BorrowTokenConfig({ interestIndexSnapshot: 0, totalBorrowingAmount: 0, totalSharesOfBorrowTokens: 0, lastUpdateTimestamp: uint64(block.timestamp), borrowApy: borrowApy, minShares: minShares });

        $.borrowTokenConfig[borrowToken] = cfg;
        emit BorrowTokenConfigSet(borrowToken, cfg);
    }

    /**
     * @dev Internal function to update the borrow APY for a token
     * @param token Address of the token to update
     * @param apy New annual percentage yield (per second)
     */
    function _setBorrowApy(address token, uint64 apy) internal {
        if (apy == 0 || apy > MAX_BORROW_APY) revert InvalidValue();
        if (!isBorrowToken(token)) revert UnsupportedBorrowToken();

        DebtManagerStorage storage $ = _getDebtManagerStorage();

        _updateBorrowings(address(0));
        emit BorrowApySet(token, $.borrowTokenConfig[token].borrowApy, apy);
        $.borrowTokenConfig[token].borrowApy = apy;
    }

    /**
     * @dev Internal function to update the minimum shares required for a borrow token
     * @param token Address of the token to update
     * @param shares New minimum shares value
     */
    function _setMinBorrowTokenShares(address token, uint128 shares) internal {
        if (shares == 0) revert InvalidValue();
        if (!isBorrowToken(token)) revert UnsupportedBorrowToken();

        DebtManagerStorage storage $ = _getDebtManagerStorage();

        _updateBorrowings(address(0));
        emit MinSharesOfBorrowTokenSet(token, $.borrowTokenConfig[token].minShares, shares);
        $.borrowTokenConfig[token].minShares = shares;
    }
}