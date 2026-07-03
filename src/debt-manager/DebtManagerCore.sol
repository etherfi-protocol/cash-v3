// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { ICashLens } from "../interfaces/ICashLens.sol";
import { BinSponsor, ICashModule } from "../interfaces/ICashModule.sol";
import { IDebtManager } from "../interfaces/IDebtManager.sol";
import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { IGateway } from "../interfaces/IGateway.sol";
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
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using SafeERC20 for IERC20;

    /**
     * @dev Constructor that initializes the base DebtManagerStorageContract
     * @param dataProvider Address of the EtherFi data provider
     */
    constructor(address dataProvider) DebtManagerStorageContract(dataProvider) { }

    /**
     * @notice Returns the configuration for a specified borrow token
     * @dev Includes updated interest calculation for total borrowing amount
     * @param borrowToken Address of the borrow token
     * @return BorrowTokenConfig configuration for the specified token
     */
    function borrowTokenConfig(address borrowToken) public view returns (BorrowTokenConfig memory) {
        return _getDebtManagerStorage().borrowTokenConfig[borrowToken];
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
        return _getDebtManagerStorage().supportedCollateralTokens.values();
    }

    /**
     * @notice Returns the list of supported borrow tokens
     * @return Array of addresses representing supported borrow tokens
     */
    function getBorrowTokens() public view returns (address[] memory) {
        return _getDebtManagerStorage().supportedBorrowTokens.values();
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
        address[] memory supportedBorrowTokens = _getDebtManagerStorage().supportedBorrowTokens.values();
        uint256 len = supportedBorrowTokens.length;
        TokenData[] memory tokenData = new TokenData[](len);
        uint256 totalBorrowingAmt = 0;
        uint256 m = 0;

        for (uint256 i = 0; i < len;) {
            BorrowTokenConfig memory config = borrowTokenConfig(supportedBorrowTokens[i]);
            uint256 indexSnapshot = getCurrentIndex(supportedBorrowTokens[i]);
            uint256 totalBorrowInToken = _getActualBorrowAmount(config.totalNormalizedBorrowingAmount, indexSnapshot);

            if (totalBorrowInToken > 0) {
                tokenData[m] = TokenData({ token: supportedBorrowTokens[i], amount: totalBorrowInToken });
                totalBorrowingAmt += totalBorrowInToken;

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
                // user collateral for token in USD * ltv  / 100
                totalMaxBorrow += collateral.mulDiv($.collateralTokenConfig[collateralTokens[i].token].ltv, HUNDRED_PERCENT, Math.Rounding.Floor);
            } else {
                // user collateral for token in USD * liquidation threshold / 100
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
        address[] memory supportedBorrowTokens = _getDebtManagerStorage().supportedBorrowTokens.values();
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
        address[] memory supportedBorrowTokens = _getDebtManagerStorage().supportedBorrowTokens.values();
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

        $.sharesOfBorrowTokens[user][borrowToken] += shares;
        $.borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens += shares;

        if ($.borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens < $.borrowTokenConfig[borrowToken].minShares) revert SharesCannotBeLessThanMinShares();

        IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), amount);

        emit Supplied(msg.sender, user, borrowToken, amount);
    }

    /**
     * @notice Withdraws borrow tokens from the protocol
     * @dev Transfers tokens from the contract to the sender
     * @param borrowToken Address of the token to withdraw
     * @param amount Amount of tokens to withdraw
     */
    function withdrawBorrowToken(address borrowToken, uint256 amount) external whenNotPaused nonReentrant {
        DebtManagerStorage storage $ = _getDebtManagerStorage();

        uint256 totalBorrowTokenAmt = _getTotalBorrowTokenAmount(borrowToken);
        if (totalBorrowTokenAmt == 0) revert ZeroTotalBorrowTokens();

        uint256 shares = amount.mulDiv($.borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens, totalBorrowTokenAmt, Math.Rounding.Ceil);

        if (shares == 0) revert SharesCannotBeZero();

        if ($.sharesOfBorrowTokens[msg.sender][borrowToken] < shares) revert InsufficientBorrowShares();

        uint256 userSharesLeft = $.sharesOfBorrowTokens[msg.sender][borrowToken] - shares;
        if (userSharesLeft != 0 && userSharesLeft < $.borrowTokenConfig[borrowToken].minShares) revert SharesCannotBeLessThanMinShares();

        $.sharesOfBorrowTokens[msg.sender][borrowToken] = userSharesLeft;
        $.borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens = $.borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens - shares;

        IERC20(borrowToken).safeTransfer(msg.sender, amount);
        emit WithdrawBorrowToken(msg.sender, borrowToken, amount);
    }

    /**
     * @notice Borrows tokens from the protocol
     * @dev Can only be called by an EtherFi Safe
     * @param  binSponsor Bin sponsor used to spend.
     * @param token Address of the token to borrow
     * @param amount Amount of tokens to borrow
     */
    function borrow(BinSponsor binSponsor, address token, uint256 amount) public whenNotPaused nonReentrant onlyEtherFiSafe whenNotMigrated(msg.sender) {
        DebtManagerStorage storage $ = _getDebtManagerStorage();

        if (!isBorrowToken(token)) revert UnsupportedBorrowToken();
        uint256 newInterestIndex = _updateInterestIndex(token);

        // Convert amount to 6 decimals before adding to borrowings
        uint256 borrowAmt = convertCollateralTokenToUsd(token, amount);
        uint256 normalizedAmount = _getNormalizedAmount(borrowAmt, newInterestIndex, Math.Rounding.Ceil);
        if (normalizedAmount == 0) revert BorrowAmountZero();

        $.userNormalizedBorrowings[msg.sender][token] += normalizedAmount;
        $.borrowTokenConfig[token].totalNormalizedBorrowingAmount += normalizedAmount;

        ensureHealth(msg.sender);

        if (IERC20(token).balanceOf(address(this)) < amount) revert InsufficientLiquidity();
        address settlementDispatcher = ICashModule(etherFiDataProvider.getCashModule()).getSettlementDispatcher(binSponsor);
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
    function repay(address user, address token, uint256 amount) external whenNotPaused nonReentrant whenNotMigrated(user) {
        DebtManagerStorage storage $ = _getDebtManagerStorage();

        _onlyEtherFiSafe(user);
        _updateInterestIndex(token);

        uint256 interestIndex = $.borrowTokenConfig[token].interestIndexSnapshot;

        uint256 repayDebtUsdAmt = convertCollateralTokenToUsd(token, amount);

        uint256 totalUserBorrowing = _getActualBorrowAmount($.userNormalizedBorrowings[user][token], interestIndex);
        if (totalUserBorrowing < repayDebtUsdAmt) {
            repayDebtUsdAmt = totalUserBorrowing;
            amount = convertUsdToCollateralToken(token, repayDebtUsdAmt);
        }

        uint256 normalizedAmount = _getNormalizedAmount(repayDebtUsdAmt, interestIndex, Math.Rounding.Floor);
        if (normalizedAmount == 0) revert RepaymentAmountIsZero();

        // if (!isBorrowToken(token)) revert UnsupportedRepayToken();
        _repayWithBorrowToken(token, user, amount, repayDebtUsdAmt, normalizedAmount);
    }

    /**
     * @dev Processes repayment with borrow token
     * @param token Address of the token being repaid
     * @param user Address of the user whose debt is being repaid
     * @param amount Amount of tokens being repaid
     * @param repayDebtusdAmount USD amount in 6 decimals
     * @param normalizedAmount Normalized amount
     */
    function _repayWithBorrowToken(address token, address user, uint256 amount, uint256 repayDebtusdAmount, uint256 normalizedAmount) internal {
        DebtManagerStorage storage $ = _getDebtManagerStorage();

        $.userNormalizedBorrowings[user][token] -= normalizedAmount;
        $.borrowTokenConfig[token].totalNormalizedBorrowingAmount -= normalizedAmount;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit Repaid(user, msg.sender, token, repayDebtusdAmount);
    }

    /**
     * @notice The Aave v4 gateway used by migrateToAave
     */
    function gateway() external view returns (IGateway) {
        return _getDebtManagerStorage().gateway;
    }

    /**
     * @notice Whether a Safe's position has been migrated to Aave
     * @param safe The Safe to query
     */
    function hasMigratedToAave(address safe) external view returns (bool) {
        return _getDebtManagerStorage().migratedToAave[safe];
    }

    /**
     * @notice Sets the Aave v4 gateway used by migrateToAave
     * @dev Only callable by accounts with DEBT_MANAGER_ADMIN_ROLE
     * @param _gateway Address of the gateway
     * @custom:throws InvalidValue if the gateway is the zero address
     */
    function setGateway(address _gateway) external onlyRole(DEBT_MANAGER_ADMIN_ROLE) {
        if (_gateway == address(0)) revert InvalidValue();
        _getDebtManagerStorage().gateway = IGateway(_gateway);
        emit GatewaySet(_gateway);
    }

    /**
     * @notice Migrates a Safe's position from DebtManager to the Aave instance, atomically and without a
     *         flash loan: the Safe's collateral is supplied to Aave, the outstanding debt is borrowed against
     *         it, and that borrow funds the DebtManager repayment. End state: same collateral and debt size,
     *         now on Aave, with the legacy DebtManager debt cleared.
     * @dev The order (supply -> borrow -> repay) is load-bearing — the repayment is funded by the Aave borrow,
     *      which is only possible once the collateral is on Aave. The whole thing reverts (leaving the Safe
     *      untouched) if the Safe has no debt, the Aave reserve lacks liquidity, or the position does not fit
     *      Aave's LTVs. Only callable by DEBT_MANAGER_ADMIN_ROLE (the migration runner).
     *      Requires the gateway to be a default module on the Safe and DebtManager to be an authorized gateway
     *      driver; the gateway self-approves as the Safe's Aave position manager on its first op.
     * @param safe The Safe to migrate
     */
    function migrateToAave(address safe) external whenNotPaused nonReentrant onlyRole(DEBT_MANAGER_ADMIN_ROLE) {
        _onlyEtherFiSafe(safe);
        DebtManagerStorage storage $ = _getDebtManagerStorage();

        // 1. Snapshot the outstanding debt. A Safe with no debt is trivially migrated: mark it and return,
        //    so a batch runner can call this over every Safe without special-casing (and idempotently).
        (TokenData[] memory borrowings, uint256 totalDebtUsd) = borrowingOf(safe);
        if (totalDebtUsd == 0) {
            $.migratedToAave[safe] = true;
            emit MigratedToAave(safe, 0);
            return;
        }

        IGateway _gateway = $.gateway;
        if (address(_gateway) == address(0)) revert GatewayNotSet();
        uint256 bLen = borrowings.length;

        // 2. Clear the legacy DebtManager debt FIRST, capturing the token amount to re-borrow, and check Aave
        //    has the cash to fund it. Clearing first is load-bearing: supplying collateral (step 3) moves it
        //    out of the Safe via execTransactionFromModule, which runs the EtherFiHook's DebtManager health
        //    check — that would revert while the debt is still open. The Aave borrow (step 4) re-funds the
        //    pool; the whole tx reverts on any failure, so the Safe is never left half-migrated nor the pool short.
        uint256[] memory debtTokenAmts = new uint256[](bLen);
        for (uint256 i = 0; i < bLen;) {
            if (borrowings[i].amount != 0) {
                uint256 debtTokenAmt = _clearLegacyDebt(safe, borrowings[i].token);
                if (_gateway.availableCash(borrowings[i].token) < debtTokenAmt) revert InsufficientAaveLiquidity(borrowings[i].token);
                debtTokenAmts[i] = debtTokenAmt;
            }
            unchecked {
                ++i;
            }
        }

        // 3. Supply all of the Safe's collateral into Aave, enabled as collateral (Safe is now debt-free on
        //    DebtManager, so the hook's health check passes as the collateral moves).
        address[] memory collateralTokens = getCollateralTokens();
        uint256 cLen = collateralTokens.length;
        for (uint256 i = 0; i < cLen;) {
            uint256 bal = IERC20(collateralTokens[i]).balanceOf(safe);
            if (bal != 0) {
                _gateway.supply(safe, collateralTokens[i], bal);
                _gateway.setUsingAsCollateral(safe, collateralTokens[i], true);
            }
            unchecked {
                ++i;
            }
        }

        // 4. LTV-fit check (specific error) so the runner can route positions that fit DebtManager's params
        //    but not Aave's. availableBorrowsUsd is the supplied collateral weighted by Aave's LTVs.
        if (_gateway.getAccountData(safe).availableBorrowsUsd < totalDebtUsd) revert PositionExceedsAaveLtv();

        // 5. Borrow each debt from Aave into this contract — these funds re-fund the debt cleared in step 2
        for (uint256 i = 0; i < bLen;) {
            if (debtTokenAmts[i] != 0) _gateway.borrow(safe, borrowings[i].token, debtTokenAmts[i], address(this));
            unchecked {
                ++i;
            }
        }

        $.migratedToAave[safe] = true;
        emit MigratedToAave(safe, totalDebtUsd);
    }

    /**
     * @dev Clears a Safe's full outstanding debt in `token` from DebtManager's books and returns the debt in
     *      token units (to be re-borrowed from Aave). Only the accounting is cleared here; the re-borrowed
     *      funds arriving later ARE the repayment that replenishes the lent-out balance.
     */
    function _clearLegacyDebt(address safe, address token) internal returns (uint256 debtTokenAmt) {
        DebtManagerStorage storage $ = _getDebtManagerStorage();

        uint256 interestIndex = _updateInterestIndex(token);
        uint256 normalizedAmount = $.userNormalizedBorrowings[safe][token];
        if (normalizedAmount == 0) return 0;

        uint256 debtUsd = _getActualBorrowAmount(normalizedAmount, interestIndex);
        debtTokenAmt = convertUsdToCollateralToken(token, debtUsd);

        $.userNormalizedBorrowings[safe][token] = 0;
        $.borrowTokenConfig[token].totalNormalizedBorrowingAmount -= normalizedAmount;

        emit Repaid(safe, address(this), token, debtUsd);
    }

    /**
     * @notice Fetches the liquid stable amounts in the contract
     * @dev Calculated as the stable balances of the contract for each supported borrow token
     * @return Array of TokenData containing tokens and their available balances
     */
    function _liquidStableAmounts() internal view returns (TokenData[] memory) {
        address[] memory supportedBorrowTokens = _getDebtManagerStorage().supportedBorrowTokens.values();
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
     * @notice Returns the address of DebtManagerAdmin implementation
     * @return address DebtManagerAdmin implmentaion
     */
    function getDebtManagerAdmin() external view returns (address) {
        address addr;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            addr := sload(ADMIN_IMPL_POSITION)
        }

        return addr;
    }

    /**
     * @notice Sets a new DebtManagerAdmin implementation
     * @dev Can only be called by the owner of the role registry contract.
     * @param newImpl Address of the new DebtManagerAdmin contract
     */
    function setAdminImpl(address newImpl) external onlyRoleRegistryOwner {
        bytes32 position = ADMIN_IMPL_POSITION;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            sstore(position, newImpl)
        }
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
     * @dev Blocks legacy DebtManager operations for a Safe once it has migrated to Aave
     * @param safe The Safe to check
     * @custom:throws AlreadyMigratedToAave if the Safe has been migrated
     */
    modifier whenNotMigrated(address safe) {
        if (_getDebtManagerStorage().migratedToAave[safe]) revert AlreadyMigratedToAave();
        _;
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
