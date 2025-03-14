// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ICashLens } from "../interfaces/ICashLens.sol";
import { ICashModule } from "../interfaces/ICashModule.sol";
import { IDebtManager } from "../interfaces/IDebtManager.sol";
import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { IPriceProvider } from "../interfaces/IPriceProvider.sol";
import { DebtManagerStorageContract } from "./DebtManagerStorageContract.sol";

/**
 * @title DebtManagerCore
 * @author ether.fi
 * @notice Core implementation of the Debt Manager system handling lending, borrowing, repayment, and liquidation operations
 * @dev Implements the main business logic for the lending and borrowing protocol
 */
contract DebtManagerCore is DebtManagerStorageContract {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /**
     * @dev Constructor that initializes the base DebtManagerStorageContract
     * @param dataProvider Address of the EtherFi data provider
     */
    constructor(address dataProvider) DebtManagerStorageContract(dataProvider) {}

    /**
     * @notice Returns the configuration for a specified borrow token
     * @dev Includes updated interest calculation for total borrowing amount
     * @param borrowToken Address of the borrow token
     * @return BorrowTokenConfig configuration for the specified token
     */
    function borrowTokenConfig(address borrowToken) public view returns (BorrowTokenConfig memory) {
        DebtManagerStorage storage $ = _getDebtManagerStorage();
        BorrowTokenConfig memory config = $.borrowTokenConfig[borrowToken];
        config.totalBorrowingAmount = _getAmountWithInterest(borrowToken, config.totalBorrowingAmount, config.interestIndexSnapshot);

        return config;
    }

    /**
     * @notice Returns the configuration for a specified collateral token
     * @param collateralToken Address of the collateral token
     * @return CollateralTokenConfig configuration for the specified token
     */
    function collateralTokenConfig(address collateralToken) external view returns (CollateralTokenConfig memory) {
        return _getDebtManagerStorage().collateralTokenConfig[collateralToken];
    }

    /**
     * @notice Returns the list of supported collateral tokens
     * @return Array of addresses representing supported collateral tokens
     */
    function getCollateralTokens() public view returns (address[] memory) {
        return _getDebtManagerStorage().supportedCollateralTokens;
    }

    /**
     * @notice Returns the list of supported borrow tokens
     * @return Array of addresses representing supported borrow tokens
     */
    function getBorrowTokens() public view returns (address[] memory) {
        return _getDebtManagerStorage().supportedBorrowTokens;
    }

    /**
     * @notice Gets a user's collateral amount for a specific token
     * @param safe Address of the user/safe
     * @param token Address of the collateral token
     * @return collateralTokenAmt Amount of collateral in token units
     * @return collateralAmtInUsd USD value of the collateral with 6 decimals
     */
    function getUserCollateralForToken(address safe, address token) external view returns (uint256, uint256) {
        if (!isCollateralToken(token)) revert UnsupportedCollateralToken();
        uint256 collateralTokenAmt = ICashLens(etherFiDataProvider.getCashLens()).getUserCollateralForToken(safe, token);
        uint256 collateralAmtInUsd = convertCollateralTokenToUsd(token, collateralTokenAmt);

        return (collateralTokenAmt, collateralAmtInUsd);
    }

    /**
     * @notice Returns the total borrowing amounts across all tokens
     * @return tokenData Array of token addresses and their borrowed amounts
     * @return totalBorrowingAmt Total borrowing amount in USD with 6 decimals
     */
    function totalBorrowingAmounts() public view returns (TokenData[] memory, uint256) {
        address[] memory supportedBorrowTokens = _getDebtManagerStorage().supportedBorrowTokens;
        uint256 len = supportedBorrowTokens.length;
        TokenData[] memory tokenData = new TokenData[](len);
        uint256 totalBorrowingAmt = 0;
        uint256 m = 0;

        for (uint256 i = 0; i < len;) {
            BorrowTokenConfig memory config = borrowTokenConfig(supportedBorrowTokens[i]);

            if (config.totalBorrowingAmount > 0) {
                tokenData[m] = TokenData({ token: supportedBorrowTokens[i], amount: config.totalBorrowingAmount });
                totalBorrowingAmt += config.totalBorrowingAmount;

                unchecked {
                    ++m;
                }
            }

            unchecked {
                ++i;
            }
        }

        assembly ("memory-safe") {
            mstore(tokenData, m)
        }

        return (tokenData, totalBorrowingAmt);
    }

    /**
     * @notice Checks if a user's position is liquidatable
     * @dev A position is liquidatable if total borrowing exceeds maximum allowed borrowing
     * @param user Address of the user to check
     * @return True if the position is liquidatable, false otherwise
     */
    function liquidatable(address user) public view returns (bool) {
        (, uint256 userBorrowing) = borrowingOf(user);
        // Total borrowing in USD > total max borrowing of the user
        return userBorrowing > getMaxBorrowAmount(user, false);
    }

    /**
     * @notice Calculates the maximum amount a user can borrow
     * @dev Computes based on either loan-to-value (LTV) or liquidation threshold
     * @param user Address of the user
     * @param forLtv If true, uses LTV for calculation; if false, uses liquidation threshold
     * @return Maximum borrowing amount in USD with 6 decimals
     */
    function getMaxBorrowAmount(address user, bool forLtv) public view returns (uint256) {
        DebtManagerStorage storage $ = _getDebtManagerStorage();

        uint256 totalMaxBorrow = 0;
        IDebtManager.TokenData[] memory collateralTokens = ICashLens(etherFiDataProvider.getCashLens()).getUserTotalCollateral(user);
        uint256 len = collateralTokens.length;

        for (uint256 i = 0; i < len;) {
            uint256 collateral = convertCollateralTokenToUsd(collateralTokens[i].token, collateralTokens[i].amount);
            if (forLtv) {
                // user collateral for token in USD * 100 / liquidation threshold
                totalMaxBorrow += collateral.mulDiv($.collateralTokenConfig[collateralTokens[i].token].ltv, HUNDRED_PERCENT, Math.Rounding.Floor);
            } else {
                totalMaxBorrow += collateral.mulDiv($.collateralTokenConfig[collateralTokens[i].token].liquidationThreshold, HUNDRED_PERCENT, Math.Rounding.Floor);
            }

            unchecked {
                ++i;
            }
        }

        return totalMaxBorrow;
    }

    /**
     * @notice Returns the collateral tokens and their total value for a user
     * @param user Address of the user
     * @return collateralTokens Array of token addresses and their amounts
     * @return totalCollateralInUsd Total collateral value in USD with 6 decimals
     */
    function collateralOf(address user) public view returns (IDebtManager.TokenData[] memory, uint256) {
        IDebtManager.TokenData[] memory collateralTokens = ICashLens(etherFiDataProvider.getCashLens()).getUserTotalCollateral(user);
        uint256 len = collateralTokens.length;
        uint256 totalCollateralInUsd = 0;

        for (uint256 i = 0; i < len;) {
            totalCollateralInUsd += convertCollateralTokenToUsd(collateralTokens[i].token, collateralTokens[i].amount);
            unchecked {
                ++i;
            }
        }

        return (collateralTokens, totalCollateralInUsd);
    }

    /**
     * @notice Calculates borrowing power and total borrowing for a user with specified collateral
     * @param user Address of the user
     * @param tokenAmounts Array of token addresses and their amounts
     * @return totalMaxBorrow Maximum borrowing capacity in USD with 6 decimals
     * @return totalBorrowings Current total borrowings in USD with 6 decimals
     */
    function getBorrowingPowerAndTotalBorrowing(address user, TokenData[] memory tokenAmounts) external view returns (uint256, uint256) {
        DebtManagerStorage storage $ = _getDebtManagerStorage();
        uint256 len = tokenAmounts.length;
        uint256 totalMaxBorrow = 0;

        for (uint256 i = 0; i < len;) {
            uint256 collateral = convertCollateralTokenToUsd(tokenAmounts[i].token, tokenAmounts[i].amount);

            // user collateral for token in USD * 100 / ltv
            totalMaxBorrow += collateral.mulDiv($.collateralTokenConfig[tokenAmounts[i].token].ltv, HUNDRED_PERCENT, Math.Rounding.Floor);

            unchecked {
                ++i;
            }
        }

        (, uint256 totalBorrowings) = borrowingOf(user);
        return (totalMaxBorrow, totalBorrowings);
    }

    /**
     * @notice Verifies that a user's position is healthy (not liquidatable)
     * @dev Reverts if total borrowing exceeds maximum borrowing based on LTV
     * @param user Address of the user to check
     */
    function ensureHealth(address user) public view {
        (, uint256 totalBorrowings) = borrowingOf(user);
        if (totalBorrowings > getMaxBorrowAmount(user, true)) revert AccountUnhealthy();
    }

    /**
     * @notice Calculates the remaining borrowing capacity for a user
     * @param user Address of the user
     * @return Remaining borrowing capacity in USD with 6 decimals
     */
    function remainingBorrowingCapacityInUSD(address user) public view returns (uint256) {
        uint256 maxBorrowingAmount = getMaxBorrowAmount(user, true);
        (, uint256 currentBorrowingWithInterest) = borrowingOf(user);

        return maxBorrowingAmount > currentBorrowingWithInterest ? maxBorrowingAmount - currentBorrowingWithInterest : 0;
    }

    /**
     * @notice Returns the borrow APY per second for a token
     * @param borrowToken Address of the borrow token
     * @return Borrow APY per second as a uint64
     */
    function borrowApyPerSecond(address borrowToken) external view returns (uint64) {
        return _getDebtManagerStorage().borrowTokenConfig[borrowToken].borrowApy;
    }

    /**
     * @notice Returns the minimum shares required for a borrow token
     * @param borrowToken Address of the borrow token
     * @return Minimum shares as a uint128
     */
    function borrowTokenMinShares(address borrowToken) external view returns (uint128) {
        return _getDebtManagerStorage().borrowTokenConfig[borrowToken].minShares;
    }

    /**
     * @notice Gets the current state of the debt manager
     * @return borrowings Array of borrowed tokens and their amounts
     * @return totalBorrowingsInUsd Total borrowings in USD with 6 decimals
     * @return totalLiquidStableAmounts Array of liquid stable tokens and their amounts
     */
    function getCurrentState() public view returns (TokenData[] memory borrowings, uint256 totalBorrowingsInUsd, TokenData[] memory totalLiquidStableAmounts) {
        (borrowings, totalBorrowingsInUsd) = totalBorrowingAmounts();
        totalLiquidStableAmounts = _liquidStableAmounts();
    }

    /**
     * @notice Gets the current state for a specific user
     * @param user Address of the user
     * @return totalCollaterals Array of collateral tokens and their amounts
     * @return totalCollateralInUsd Total collateral value in USD with 6 decimals
     * @return borrowings Array of borrowed tokens and their amounts
     * @return totalBorrowings Total borrowings in USD with 6 decimals
     */
    function getUserCurrentState(address user) external view returns (IDebtManager.TokenData[] memory totalCollaterals, uint256 totalCollateralInUsd, TokenData[] memory borrowings, uint256 totalBorrowings) {
        (totalCollaterals, totalCollateralInUsd) = collateralOf(user);
        (borrowings, totalBorrowings) = borrowingOf(user);
    }

    /**
     * @notice Returns the balance of a supplier for a specific borrow token
     * @param supplier Address of the supplier
     * @param borrowToken Address of the borrow token
     * @return Balance of the supplier for the token
     */
    function supplierBalance(address supplier, address borrowToken) public view returns (uint256) {
        DebtManagerStorage storage $ = _getDebtManagerStorage();
        if ($.borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens == 0) return 0;

        return $.sharesOfBorrowTokens[supplier][borrowToken].mulDiv(_getTotalBorrowTokenAmount(borrowToken), $.borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens, Math.Rounding.Floor);
    }

    /**
     * @notice Returns all balances and total value for a supplier
     * @param supplier Address of the supplier
     * @return suppliesData Array of token addresses and their supplied amounts
     * @return amountInUsd Total supplied value in USD with 6 decimals
     */
    function supplierBalance(address supplier) public view returns (TokenData[] memory, uint256) {
        address[] memory supportedBorrowTokens = _getDebtManagerStorage().supportedBorrowTokens;
        uint256 len = supportedBorrowTokens.length;
        TokenData[] memory suppliesData = new TokenData[](len);
        uint256 amountInUsd = 0;
        uint256 m = 0;

        for (uint256 i = 0; i < len;) {
            address borrowToken = supportedBorrowTokens[i];
            uint256 amount = supplierBalance(supplier, borrowToken);

            if (amount > 0) {
                amountInUsd += convertCollateralTokenToUsd(borrowToken, amount);
                suppliesData[m] = TokenData({ token: borrowToken, amount: amount });

                unchecked {
                    ++m;
                }
            }
            unchecked {
                ++i;
            }
        }

        assembly ("memory-safe") {
            mstore(suppliesData, m)
        }

        return (suppliesData, amountInUsd);
    }

    /**
     * @notice Returns the total supply for a specific borrow token
     * @param borrowToken Address of the borrow token
     * @return Total supply for the token
     */
    function totalSupplies(address borrowToken) public view returns (uint256) {
        return _getTotalBorrowTokenAmount(borrowToken);
    }

    /**
     * @notice Returns the total supplies across all tokens
     * @return suppliesData Array of token addresses and their total supplies
     * @return amountInUsd Total supply value in USD with 6 decimals
     */
    function totalSupplies() external view returns (TokenData[] memory, uint256) {
        address[] memory supportedBorrowTokens = _getDebtManagerStorage().supportedBorrowTokens;
        uint256 len = supportedBorrowTokens.length;
        TokenData[] memory suppliesData = new TokenData[](len);
        uint256 amountInUsd = 0;
        uint256 m = 0;

        for (uint256 i = 0; i < len;) {
            address borrowToken = supportedBorrowTokens[i];
            uint256 totalSupplied = totalSupplies(borrowToken);
            if (totalSupplied > 0) {
                amountInUsd += convertCollateralTokenToUsd(borrowToken, totalSupplied);
                suppliesData[m] = TokenData({ token: borrowToken, amount: totalSupplied });
                unchecked {
                    ++m;
                }
            }
            unchecked {
                ++i;
            }
        }

        assembly ("memory-safe") {
            mstore(suppliesData, m)
        }

        return (suppliesData, amountInUsd);
    }

    /**
     * @notice Converts collateral token amount to USD value
     * @param collateralToken Address of the collateral token
     * @param collateralAmount Amount in collateral token units
     * @return USD value with 6 decimals
     */
    function convertCollateralTokenToUsd(address collateralToken, uint256 collateralAmount) public view returns (uint256) {
        if (!isCollateralToken(collateralToken)) revert UnsupportedCollateralToken();

        return (collateralAmount * IPriceProvider(etherFiDataProvider.getPriceProvider()).price(collateralToken)) / 10 ** _getDecimals(collateralToken);
    }

    /**
     * @notice Calculates the total collateral value in USD for a user
     * @param user Address of the user
     * @return Total collateral value in USD with 6 decimals
     */
    function getCollateralValueInUsd(address user) public view returns (uint256) {
        uint256 userCollateralInUsd = 0;
        IDebtManager.TokenData[] memory userCollateral = ICashLens(etherFiDataProvider.getCashLens()).getUserTotalCollateral(user);
        uint256 len = userCollateral.length;

        for (uint256 i = 0; i < len;) {
            userCollateralInUsd += convertCollateralTokenToUsd(userCollateral[i].token, userCollateral[i].amount);
            unchecked {
                ++i;
            }
        }

        return userCollateralInUsd;
    }

    /**
     * @notice Supplies tokens to the protocol
     * @dev Transfers tokens from the sender to the contract
     * @param user Address that will receive credit for the supplied tokens
     * @param borrowToken Address of the token being supplied
     * @param amount Amount of tokens to supply
     */
    function supply(address user, address borrowToken, uint256 amount) external whenNotPaused nonReentrant {
        DebtManagerStorage storage $ = _getDebtManagerStorage();

        if (!isBorrowToken(borrowToken)) revert UnsupportedBorrowToken();
        if (etherFiDataProvider.isEtherFiSafe(user)) revert EtherFiSafeCannotSupplyDebtTokens();

        uint256 shares = $.borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens == 0 ? amount : amount.mulDiv($.borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens, _getTotalBorrowTokenAmount(borrowToken), Math.Rounding.Floor);

        if (shares < $.borrowTokenConfig[borrowToken].minShares) revert SharesCannotBeLessThanMinShares();

        $.sharesOfBorrowTokens[user][borrowToken] += shares;
        $.borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens += shares;

        IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), amount);

        emit Supplied(msg.sender, user, borrowToken, amount);
    }

    /**
     * @notice Withdraws borrow tokens from the protocol
     * @dev Transfers tokens from the contract to the sender
     * @param borrowToken Address of the token to withdraw
     * @param amount Amount of tokens to withdraw
     */
    function withdrawBorrowToken(address borrowToken, uint256 amount) external whenNotPaused {
        DebtManagerStorage storage $ = _getDebtManagerStorage();

        uint256 totalBorrowTokenAmt = _getTotalBorrowTokenAmount(borrowToken);
        if (totalBorrowTokenAmt == 0) revert ZeroTotalBorrowTokens();

        uint256 shares = amount.mulDiv($.borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens, totalBorrowTokenAmt, Math.Rounding.Ceil);

        if (shares == 0) revert SharesCannotBeZero();

        if ($.sharesOfBorrowTokens[msg.sender][borrowToken] < shares) revert InsufficientBorrowShares();

        uint256 sharesLeft = $.borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens - shares;
        if (sharesLeft != 0 && sharesLeft < $.borrowTokenConfig[borrowToken].minShares) revert SharesCannotBeLessThanMinShares();

        $.sharesOfBorrowTokens[msg.sender][borrowToken] -= shares;
        $.borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens = sharesLeft;

        IERC20(borrowToken).safeTransfer(msg.sender, amount);
        emit WithdrawBorrowToken(msg.sender, borrowToken, amount);
    }

    /**
     * @notice Borrows tokens from the protocol
     * @dev Can only be called by an EtherFi Safe
     * @param token Address of the token to borrow
     * @param amount Amount of tokens to borrow
     */
    function borrow(address token, uint256 amount) external whenNotPaused onlyEtherFiSafe {
        DebtManagerStorage storage $ = _getDebtManagerStorage();

        if (!isBorrowToken(token)) revert UnsupportedBorrowToken();
        _updateBorrowings(msg.sender, token);

        // Convert amount to 6 decimals before adding to borrowings
        uint256 borrowAmt = convertCollateralTokenToUsd(token, amount);
        if (borrowAmt == 0) revert BorrowAmountZero();

        $.userBorrowings[msg.sender][token] += borrowAmt;
        $.borrowTokenConfig[token].totalBorrowingAmount += borrowAmt;

        ensureHealth(msg.sender);

        if (IERC20(token).balanceOf(address(this)) < amount) revert InsufficientLiquidity();
        address settlementDispatcher = ICashModule(etherFiDataProvider.getCashModule()).getSettlementDispatcher();
        IERC20(token).safeTransfer(settlementDispatcher, amount);

        emit Borrowed(msg.sender, token, amount);
    }

    /**
     * @notice Repays borrowed tokens
     * @dev Updates borrowing state and transfers tokens from sender to contract
     * @param user Address of the user whose debt is being repaid
     * @param token Address of the token being repaid
     * @param amount Amount of tokens to repay
     */
    function repay(address user, address token, uint256 amount) external whenNotPaused nonReentrant {
        DebtManagerStorage storage $ = _getDebtManagerStorage();

        _onlyEtherFiSafe(user);
        _updateBorrowings(user, token);

        uint256 repayDebtUsdAmt = convertCollateralTokenToUsd(token, amount);
        if ($.userBorrowings[user][token] < repayDebtUsdAmt) {
            repayDebtUsdAmt = $.userBorrowings[user][token];
            amount = convertUsdToCollateralToken(token, repayDebtUsdAmt);
        }
        if (repayDebtUsdAmt == 0) revert RepaymentAmountIsZero();

        // if (!isBorrowToken(token)) revert UnsupportedRepayToken();
        _repayWithBorrowToken(token, user, amount, repayDebtUsdAmt);
    }

    /**
     * @notice Liquidates an unhealthy position
     * @dev Can liquidate up to 50% of the debt in first attempt, and remainder if still unhealthy
     * @param user Address of the user to liquidate
     * @param borrowToken Address of the borrow token to repay
     * @param collateralTokensPreference Order of preference for collateral tokens to liquidate
     */
    function liquidate(address user, address borrowToken, address[] memory collateralTokensPreference) external whenNotPaused nonReentrant {
        _updateBorrowings(user);
        if (!isBorrowToken(borrowToken)) revert UnsupportedBorrowToken();
        if (!liquidatable(user)) revert CannotLiquidateYet();

        _liquidateUser(user, borrowToken, collateralTokensPreference);
    }

    /**
     * @dev Liquidates a user's position
     * @param user Address of the user to liquidate
     * @param borrowToken Address of the borrow token to repay
     * @param collateralTokensPreference Order of preference for collateral tokens to liquidate
     */
    function _liquidateUser(address user, address borrowToken, address[] memory collateralTokensPreference) internal {
        DebtManagerStorage storage $ = _getDebtManagerStorage();

        uint256 debtAmountToLiquidateInUsd = $.userBorrowings[user][borrowToken].ceilDiv(2);
        _liquidate(user, borrowToken, collateralTokensPreference, debtAmountToLiquidateInUsd);

        if (liquidatable(user)) _liquidate(user, borrowToken, collateralTokensPreference, $.userBorrowings[user][borrowToken]);
    }

    /**
     * @dev Executes the liquidation process
     * @param user Address of the user to liquidate
     * @param borrowToken Address of the borrow token to repay
     * @param collateralTokensPreference Order of preference for collateral tokens to liquidate
     * @param debtAmountToLiquidateInUsd Amount of debt to liquidate in USD with 6 decimals
     */
    function _liquidate(address user, address borrowToken, address[] memory collateralTokensPreference, uint256 debtAmountToLiquidateInUsd) internal {
        DebtManagerStorage storage $ = _getDebtManagerStorage();
        ICashModule cashModule = ICashModule(etherFiDataProvider.getCashModule());

        cashModule.preLiquidate(user);
        if (debtAmountToLiquidateInUsd == 0) revert LiquidatableAmountIsZero();

        uint256 beforeDebtAmount = $.userBorrowings[user][borrowToken];

        (IDebtManager.LiquidationTokenData[] memory collateralTokensToSend, uint256 remainingDebt) = _getCollateralTokensForDebtAmount(user, debtAmountToLiquidateInUsd, collateralTokensPreference);

        cashModule.postLiquidate(user, msg.sender, collateralTokensToSend);

        uint256 liquidatedAmt = debtAmountToLiquidateInUsd - remainingDebt;
        $.userBorrowings[user][borrowToken] -= liquidatedAmt;
        $.borrowTokenConfig[borrowToken].totalBorrowingAmount -= liquidatedAmt;

        IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), convertUsdToCollateralToken(borrowToken, liquidatedAmt));

        emit Liquidated(msg.sender, user, borrowToken, collateralTokensToSend, beforeDebtAmount, liquidatedAmt);
    }

    /**
     * @dev Processes repayment with borrow token
     * @param token Address of the token being repaid
     * @param user Address of the user whose debt is being repaid
     * @param amount Amount of tokens being repaid
     * @param repayDebtUsdAmt USD value of the repayment with 6 decimals
     */
    function _repayWithBorrowToken(address token, address user, uint256 amount, uint256 repayDebtUsdAmt) internal {
        DebtManagerStorage storage $ = _getDebtManagerStorage();
        
        $.userBorrowings[user][token] -= repayDebtUsdAmt;
        $.borrowTokenConfig[token].totalBorrowingAmount -= repayDebtUsdAmt;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit Repaid(user, msg.sender, token, repayDebtUsdAmt);
    }

    /**
     * @dev Calculates collateral tokens needed to cover a debt amount
     * @param user Address of the user being liquidated
     * @param repayDebtUsdAmt Debt amount to cover in USD with 6 decimals
     * @param collateralTokenPreference Order of preference for collateral tokens
     * @return Array of liquidation token data
     * @return remainingDebt Remaining debt that could not be covered
     */
    function _getCollateralTokensForDebtAmount(address user, uint256 repayDebtUsdAmt, address[] memory collateralTokenPreference) internal view returns (IDebtManager.LiquidationTokenData[] memory, uint256 remainingDebt) {
        DebtManagerStorage storage $ = _getDebtManagerStorage();
        uint256 len = collateralTokenPreference.length;
        IDebtManager.LiquidationTokenData[] memory collateral = new IDebtManager.LiquidationTokenData[](len);

        for (uint256 i = 0; i < len;) {
            address collateralToken = collateralTokenPreference[i];
            if (!isCollateralToken(collateralToken)) revert NotACollateralToken();

            uint256 collateralAmountForDebt = convertUsdToCollateralToken(collateralToken, repayDebtUsdAmt);
            uint256 totalCollateral = IERC20(collateralToken).balanceOf(user);
            uint256 maxBonus = (totalCollateral * $.collateralTokenConfig[collateralToken].liquidationBonus) / HUNDRED_PERCENT;

            if (totalCollateral - maxBonus < collateralAmountForDebt) {
                uint256 liquidationBonus = maxBonus;
                collateral[i] = IDebtManager.LiquidationTokenData({ token: collateralToken, amount: totalCollateral, liquidationBonus: liquidationBonus });

                uint256 usdValueOfCollateral = convertCollateralTokenToUsd(collateralToken, totalCollateral - liquidationBonus);

                repayDebtUsdAmt -= usdValueOfCollateral;
            } else {
                uint256 liquidationBonus = (collateralAmountForDebt * $.collateralTokenConfig[collateralToken].liquidationBonus) / HUNDRED_PERCENT;

                collateral[i] = IDebtManager.LiquidationTokenData({ token: collateralToken, amount: collateralAmountForDebt + liquidationBonus, liquidationBonus: liquidationBonus });

                repayDebtUsdAmt = 0;
            }

            if (repayDebtUsdAmt == 0) {
                uint256 arrLen = i + 1;
                assembly ("memory-safe") {
                    mstore(collateral, arrLen)
                }

                break;
            }

            unchecked {
                ++i;
            }
        }

        return (collateral, repayDebtUsdAmt);
    }

    /**
     * @notice Fetches the liquid stable amounts in the contract
     * @dev Calculated as the stable balances of the contract for each supported borrow token
     * @return Array of TokenData containing tokens and their available balances
     */
    function _liquidStableAmounts() internal view returns (TokenData[] memory) {
        address[] memory supportedBorrowTokens = _getDebtManagerStorage().supportedBorrowTokens;
        uint256 len = supportedBorrowTokens.length;
        TokenData[] memory tokenData = new TokenData[](len);
        uint256 m = 0;

        uint256 totalStableBalances = 0;
        for (uint256 i = 0; i < len;) {
            uint256 bal = IERC20(supportedBorrowTokens[i]).balanceOf(address(this));

            if (bal > 0) {
                tokenData[m] = TokenData({ token: supportedBorrowTokens[i], amount: bal });
                totalStableBalances += bal;
                unchecked {
                    ++m;
                }
            }

            unchecked {
                ++i;
            }
        }

        assembly ("memory-safe") {
            mstore(tokenData, m)
        }

        return tokenData;
    }

    /**
     * @notice Checks if an account is an EtherFi Safe
     * @dev Reverts with OnlyEtherFiSafe error if account is not an EtherFi Safe
     * @param account Address to check
     */
    function _onlyEtherFiSafe(address account) internal view {
        if (!etherFiDataProvider.isEtherFiSafe(account)) revert OnlyEtherFiSafe();
    }

    /**
     * @notice Modifier to restrict function access to EtherFi Safe accounts only
     * @dev Calls _onlyEtherFiSafe to verify the caller is an EtherFi Safe
     */
    modifier onlyEtherFiSafe() {
        _onlyEtherFiSafe(msg.sender);
        _;
    }

    /**
     * @dev Fallback function that delegates calls to the admin implementation
     * @notice This is a catch-all for all functions not declared in core
     * @dev Uses assembly to perform the delegation to preserve calldata and return data
     */
    // solhint-disable-next-line no-complex-fallback
    fallback() external {
        bytes32 slot = ADMIN_IMPL_POSITION;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            // Copy msg.data. We take full control of memory in this inline assembly
            // block because it will not return to Solidity code. We overwrite the
            // Solidity scratch pad at memory position 0.
            calldatacopy(0, 0, calldatasize())

            // Call the implementation.
            // out and outsize are 0 because we don't know the size yet.
            let result := delegatecall(gas(), sload(slot), 0, calldatasize(), 0, 0)

            // Copy the returned data.
            returndatacopy(0, 0, returndatasize())

            switch result
            // delegatecall returns 0 on error.
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
