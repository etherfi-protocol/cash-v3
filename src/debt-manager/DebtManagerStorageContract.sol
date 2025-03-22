// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IDebtManager } from "../interfaces/IDebtManager.sol";
import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { IPriceProvider } from "../interfaces/IPriceProvider.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title Debt Manager
 * @author ether.fi
 * @notice Contract to manage lending and borrowing for Cash protocol
 * @dev Handles the storage layout and core functionality for the lending and borrowing system
 */
contract DebtManagerStorageContract is UpgradeableProxy {
    using Math for uint256;

    /**
     * @notice Configuration data for borrow tokens
     * @param borrowApy Annual percentage yield for borrowing this token
     * @param minShares Minimum shares required for borrowing this token
     */
    struct BorrowTokenConfigData {
        uint64 borrowApy;
        uint128 minShares;
    }

    /**
     * @notice Extended configuration for borrow tokens with accounting data
     * @param interestIndexSnapshot Current interest index for accurate interest calculation
     * @param totalNormalizedBorrowingAmount Total amount of this token borrowed across all users normalized with interest index
     * @param totalSharesOfBorrowTokens Total shares representing ownership of the borrow token pool
     * @param lastUpdateTimestamp Timestamp of the last update to this configuration
     * @param borrowApy Annual percentage yield for borrowing this token
     * @param minShares Minimum shares required for borrowing this token
     */
    struct BorrowTokenConfig {
        uint256 interestIndexSnapshot;
        uint256 totalNormalizedBorrowingAmount;
        uint256 totalSharesOfBorrowTokens;
        uint64 lastUpdateTimestamp;
        uint64 borrowApy;
        uint128 minShares;
    }

    /**
     * @notice Configuration for collateral tokens
     * @param ltv Loan-to-value ratio (percentage with 18 decimals)
     * @param liquidationThreshold Threshold after which a position can be liquidated
     * @param liquidationBonus Bonus percentage given to liquidators
     */
    struct CollateralTokenConfig {
        uint80 ltv;
        uint80 liquidationThreshold;
        uint96 liquidationBonus;
    }

    /**
     * @notice Basic token data structure
     * @param token Address of the token
     * @param amount Amount of the token
     */
    struct TokenData {
        address token;
        uint256 amount;
    }

    /**
     * @notice Token data structure for liquidation operations
     * @param token Address of the token being liquidated
     * @param amount Amount of the token being liquidated
     * @param liquidationBonus Bonus amount for the liquidator
     */
    struct LiquidationTokenData {
        address token;
        uint256 amount;
        uint256 liquidationBonus;
    }

    /// @notice Role identifier for debt manager administrators
    bytes32 public constant DEBT_MANAGER_ADMIN_ROLE = keccak256("DEBT_MANAGER_ADMIN_ROLE");
    
    /// @notice Constant representing 100% with 18 decimals precision (100e18)
    uint256 public constant HUNDRED_PERCENT = 100e18;
    
    /// @notice Precision constant for calculations (1e18)
    uint256 public constant PRECISION = 1e18;
    
    /// @notice Constant for 6 decimal precision (1e6)
    uint256 public constant SIX_DECIMALS = 1e6;

    /// @notice Storage position for admin implementation (keccak256("DebtManager.admin.impl"))
    bytes32 constant ADMIN_IMPL_POSITION = 0x49d4a010ddc5f453173525f0adf6cfb97318b551312f237c11fd9f432a1f5d21;
    
    /// @notice Maximum borrowing APY (50% / (365 days in seconds))
    uint64 public constant MAX_BORROW_APY = 1_585_489_599_188;
    
    /// @notice Interface for accessing EtherFi data
    IEtherFiDataProvider public immutable etherFiDataProvider;

    /// @custom:storage-location erc7201:etherfi.storage.DebtManager
    struct DebtManagerStorage {
        /// @notice List of supported collateral tokens
        address[] supportedCollateralTokens;
        
        /// @notice List of supported borrow tokens
        address[] supportedBorrowTokens;
        
        /// @notice Mapping from token address to its index (plus one) in supportedCollateralTokens
        mapping(address token => uint256 index) collateralTokenIndexPlusOne;
        
        /// @notice Mapping from token address to its index (plus one) in supportedBorrowTokens
        mapping(address token => uint256 index) borrowTokenIndexPlusOne;
        
        /// @notice Mapping from borrow token address to its configuration
        mapping(address borrowToken => BorrowTokenConfig config) borrowTokenConfig;
        
        /// @notice Mapping from collateral token address to its configuration
        mapping(address token => CollateralTokenConfig config) collateralTokenConfig;
        
        /// @notice User borrowings in USD normalized
        mapping(address user => mapping(address borrowToken => uint256 normalizedBorrowing)) userNormalizedBorrowings;
                
        /// @notice Shares of borrow tokens with 18 decimals precision
        mapping(address supplier => mapping(address borrowToken => uint256 shares)) sharesOfBorrowTokens;
    }

    /// @notice Storage location for DebtManagerStorage (ERC-7201 compliant)
    /// @dev keccak256(abi.encode(uint256(keccak256("etherfi.storage.DebtManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DebtManagerStorageLocation = 0x607698a05bce028f7bdc9529d6ab4a3ba381baf9d53007699c53d9e5dd543c00;

    /**
     * @dev Returns the storage struct for DebtManager
     * @return $ Reference to the DebtManagerStorage struct
     */
    function _getDebtManagerStorage() internal pure returns (DebtManagerStorage storage $) {
        assembly {
            $.slot := DebtManagerStorageLocation
        }
    }

    /**
     * @notice Emitted when tokens are supplied to the protocol
     * @param sender Address that initiated the supply
     * @param user Address that receives the supplied tokens
     * @param token Address of the supplied token
     * @param amount Amount of tokens supplied
     */
    event Supplied(address indexed sender, address indexed user, address indexed token, uint256 amount);
    
    /**
     * @notice Emitted when tokens are borrowed
     * @param user Address that borrowed the tokens
     * @param token Address of the borrowed token
     * @param amount Amount of tokens borrowed
     */
    event Borrowed(address indexed user, address indexed token, uint256 amount);
    
    /**
     * @notice Emitted when a debt is repaid
     * @param user Address whose debt is being repaid
     * @param payer Address that repaid the debt
     * @param token Address of the repaid token
     * @param amount Amount of tokens repaid
     */
    event Repaid(address indexed user, address indexed payer, address indexed token, uint256 amount);
    
    /**
     * @notice Emitted when a position is liquidated
     * @param liquidator Address that performed the liquidation
     * @param user Address that was liquidated
     * @param debtTokenToLiquidate Address of the debt token being liquidated
     * @param userCollateralLiquidated Collateral tokens liquidated
     * @param beforeDebtAmount Debt amount before liquidation
     * @param debtAmountLiquidated Amount of debt liquidated
     */
    event Liquidated(address indexed liquidator, address indexed user, address indexed debtTokenToLiquidate, IDebtManager.LiquidationTokenData[] userCollateralLiquidated, uint256 beforeDebtAmount, uint256 debtAmountLiquidated);
    
    /**
     * @notice Emitted when the liquidation threshold is updated
     * @param oldThreshold Previous liquidation threshold
     * @param newThreshold New liquidation threshold
     */
    event LiquidationThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    
    /**
     * @notice Emitted when a new collateral token is added
     * @param token Address of the added collateral token
     */
    event CollateralTokenAdded(address token);
    
    /**
     * @notice Emitted when a collateral token is removed
     * @param token Address of the removed collateral token
     */
    event CollateralTokenRemoved(address token);
    
    /**
     * @notice Emitted when a new borrow token is added
     * @param token Address of the added borrow token
     */
    event BorrowTokenAdded(address token);
    
    /**
     * @notice Emitted when a borrow token is removed
     * @param token Address of the removed borrow token
     */
    event BorrowTokenRemoved(address token);
    
    /**
     * @notice Emitted when the borrow APY is updated
     * @param token Address of the token
     * @param oldApy Previous APY
     * @param newApy New APY
     */
    event BorrowApySet(address indexed token, uint256 oldApy, uint256 newApy);
    
    /**
     * @notice Emitted when minimum shares required is updated
     * @param token Address of the token
     * @param oldMinShares Previous minimum shares
     * @param newMinShares New minimum shares
     */
    event MinSharesOfBorrowTokenSet(address indexed token, uint128 oldMinShares, uint128 newMinShares);
    
    /**
     * @notice Emitted when interest is added to a user's debt
     * @param user Address of the user
     * @param borrowingAmtBeforeInterest Borrowing amount before interest
     * @param borrowingAmtAfterInterest Borrowing amount after interest
     */
    event UserInterestAdded(address indexed user, uint256 borrowingAmtBeforeInterest, uint256 borrowingAmtAfterInterest);
    
    /**
     * @notice Emitted when total borrowing is updated
     * @param borrowToken Address of the borrow token
     * @param totalBorrowingAmtBeforeInterest Total borrowing before interest
     * @param totalBorrowingAmtAfterInterest Total borrowing after interest
     */
    event TotalBorrowingUpdated(address indexed borrowToken, uint256 totalBorrowingAmtBeforeInterest, uint256 totalBorrowingAmtAfterInterest);
    
    /**
     * @notice Emitted when borrow token configuration is updated
     * @param token Address of the token
     * @param config New configuration
     */
    event BorrowTokenConfigSet(address indexed token, BorrowTokenConfig config);
    
    /**
     * @notice Emitted when collateral token configuration is updated
     * @param collateralToken Address of the collateral token
     * @param oldConfig Previous configuration
     * @param newConfig New configuration
     */
    event CollateralTokenConfigSet(address indexed collateralToken, CollateralTokenConfig oldConfig, CollateralTokenConfig newConfig);
    
    /**
     * @notice Emitted when borrow tokens are withdrawn
     * @param withdrawer Address of the withdrawer
     * @param borrowToken Address of the withdrawn token
     * @param amount Amount withdrawn
     */
    event WithdrawBorrowToken(address indexed withdrawer, address indexed borrowToken, uint256 amount);

    /**
     * @notice Emitted when debt token interest index is updated
     * @param borrowToken Address of the borrow token
     * @param oldIndex Old index
     * @param newIndex New index
     */
    event InterestIndexUpdated(address indexed borrowToken, uint256 oldIndex, uint256 newIndex);

    /**
     * @notice Error thrown when collateral token preference array is empty while liquidating
     */
    error CollateralPreferenceIsEmpty();

    /**
     * @notice Error thrown when an unsupported collateral token is used
     */
    error UnsupportedCollateralToken();
    
    /**
     * @notice Error thrown when an unsupported repay token is used
     */
    error UnsupportedRepayToken();
    
    /**
     * @notice Error thrown when an unsupported borrow token is used
     */
    error UnsupportedBorrowToken();
    
    /**
     * @notice Error thrown when collateral is insufficient
     */
    error InsufficientCollateral();
    
    /**
     * @notice Error thrown when there's insufficient collateral to repay a debt
     */
    error InsufficientCollateralToRepay();
    
    /**
     * @notice Error thrown when liquidity is insufficient
     */
    error InsufficientLiquidity();
    
    /**
     * @notice Error thrown when a position cannot be liquidated yet
     */
    error CannotLiquidateYet();
    
    /**
     * @notice Error thrown when collateral value is zero
     */
    error ZeroCollateralValue();
    
    /**
     * @notice Error thrown when someone other than the user tries to repay with collateral
     */
    error OnlyUserCanRepayWithCollateral();
    
    /**
     * @notice Error thrown when an invalid value is provided
     */
    error InvalidValue();
    
    /**
     * @notice Error thrown when trying to add a token that's already a collateral token
     */
    error AlreadyCollateralToken();
    
    /**
     * @notice Error thrown when trying to add a token that's already a borrow token
     */
    error AlreadyBorrowToken();
    
    /**
     * @notice Error thrown when a token is not a collateral token
     */
    error NotACollateralToken();
    
    /**
     * @notice Error thrown when there are no collateral tokens left
     */
    error NoCollateralTokenLeft();
    
    /**
     * @notice Error thrown when a token is not a borrow token
     */
    error NotABorrowToken();
    
    /**
     * @notice Error thrown when there are no borrow tokens left
     */
    error NoBorrowTokenLeft();
    
    /**
     * @notice Error thrown when array lengths don't match
     */
    error ArrayLengthMismatch();
    
    /**
     * @notice Error thrown when total collateral amount is not zero
     */
    error TotalCollateralAmountNotZero();
    
    /**
     * @notice Error thrown when insufficient liquidity is available
     */
    error InsufficientLiquidityPleaseTryAgainLater();
    
    /**
     * @notice Error thrown when liquid amount is less than required
     */
    error LiquidAmountLesserThanRequired();
    
    /**
     * @notice Error thrown when total borrow tokens is zero
     */
    error ZeroTotalBorrowTokens();
    
    /**
     * @notice Error thrown when borrow shares are insufficient
     */
    error InsufficientBorrowShares();
    
    /**
     * @notice Error thrown when user is still liquidatable
     */
    error UserStillLiquidatable();
    
    /**
     * @notice Error thrown when total borrowings for a user is not zero
     */
    error TotalBorrowingsForUserNotZero();
    
    /**
     * @notice Error thrown when borrow token config is already set
     */
    error BorrowTokenConfigAlreadySet();
    
    /**
     * @notice Error thrown when an account is unhealthy
     */
    error AccountUnhealthy();
    
    /**
     * @notice Error thrown when a borrow token is still in the system
     */
    error BorrowTokenStillInTheSystem();
    
    /**
     * @notice Error thrown when repayment amount is zero
     */
    error RepaymentAmountIsZero();
    
    /**
     * @notice Error thrown when liquidatable amount is zero
     */
    error LiquidatableAmountIsZero();
    
    /**
     * @notice Error thrown when LTV is greater than liquidation threshold
     */
    error LtvCannotBeGreaterThanLiquidationThreshold();
    
    /**
     * @notice Error thrown when oracle price is zero
     */
    error OraclePriceZero();
    
    /**
     * @notice Error thrown when borrow amount is zero
     */
    error BorrowAmountZero();
    
    /**
     * @notice Error thrown when shares cannot be zero
     */
    error SharesCannotBeZero();
    
    /**
     * @notice Error thrown when shares are less than minimum shares
     */
    error SharesCannotBeLessThanMinShares();
    
    /**
     * @notice Error thrown when supply cap is breached
     */
    error SupplyCapBreached();
    
    /**
     * @notice Error thrown when caller is not EtherFi Safe
     */
    error OnlyEtherFiSafe();
    
    /**
     * @notice Error thrown when EtherFi Safe tries to supply debt tokens
     */
    error EtherFiSafeCannotSupplyDebtTokens();
    
    /**
     * @notice Error thrown when an address is not an EtherFi Safe
     */
    error NotAEtherFiSafe();
    
    /**
     * @notice Error thrown when trying to remove a borrow token from collateral
     */
    error BorrowTokenCannotBeRemovedFromCollateral();
        
    /**
     * @dev Constructor that initializes the contract with the EtherFi data provider
     * @param dataProvider Address of the EtherFi data provider
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(address dataProvider) {
        etherFiDataProvider = IEtherFiDataProvider(dataProvider);
        _disableInitializers();
    }

    /**
     * @dev Returns the total amount of borrow tokens
     * @param borrowToken Address of the borrow token
     * @return Total amount of the borrow token
     */
    function _getTotalBorrowTokenAmount(address borrowToken) internal view returns (uint256) {
        return convertUsdToCollateralToken(borrowToken, totalBorrowingAmount(borrowToken)) + IERC20(borrowToken).balanceOf(address(this));
    }

    /**
     * @notice Converts a USD amount to the equivalent collateral token amount
     * @param collateralToken Address of the collateral token
     * @param debtUsdAmount Debt amount in USD
     * @return Equivalent amount in collateral token
     */
    function convertUsdToCollateralToken(address collateralToken, uint256 debtUsdAmount) public view returns (uint256) {
        if (!isCollateralToken(collateralToken))  revert UnsupportedCollateralToken();
    
        return (debtUsdAmount * 10 ** _getDecimals(collateralToken)) / IPriceProvider(etherFiDataProvider.getPriceProvider()).price(collateralToken);
    }

    /**
     * @notice Returns the total borrowing amount for a token
     * @param borrowToken Address of the borrow token
     * @return Total borrowing amount with accrued interest
     */
    function totalBorrowingAmount(address borrowToken) public view returns (uint256) {
        BorrowTokenConfig memory borrowTokenConfig = _getDebtManagerStorage().borrowTokenConfig[borrowToken];
        return _getActualBorrowAmount(borrowTokenConfig.totalNormalizedBorrowingAmount, getCurrentIndex(borrowToken));
    }

    /**
     * @dev Calculates amount with accrued interest
     * @param normalizedAmount Amount before interest
     * @param interestIndex Accumulated interest already added
     * @return Amount with accrued interest
     */
    function _getActualBorrowAmount(uint256 normalizedAmount, uint256 interestIndex) internal pure returns (uint256) {
        return normalizedAmount.mulDiv(interestIndex, PRECISION, Math.Rounding.Floor);
    }

    /**
     * @dev Calculates the normalized amount of debt by removing accrued interest
     * @param actualAmount The actual amount of debt with interest
     * @param interestIndex The current interest index to normalize against
     * @return The normalized amount without accrued interest
     */
    function _getNormalizedAmount(uint256 actualAmount, uint256 interestIndex) internal pure returns (uint256) {
        return actualAmount.mulDiv(PRECISION, interestIndex, Math.Rounding.Floor);
    }

    /**
     * @notice Updates the interest index for a specific borrow token
     * @dev Calculates the current index, updates storage, and emits an event
     * @param borrowToken Address of the borrow token to update
     * @return The updated interest index value
     */
    function _updateInterestIndex(address borrowToken) internal returns (uint256) {
        BorrowTokenConfig storage config = _getDebtManagerStorage().borrowTokenConfig[borrowToken];
        if (config.lastUpdateTimestamp == block.timestamp) return config.interestIndexSnapshot;
        
        uint256 currentIndex = config.interestIndexSnapshot;
        config.interestIndexSnapshot = getCurrentIndex(borrowToken);
        config.lastUpdateTimestamp = uint64(block.timestamp);

        emit InterestIndexUpdated(borrowToken, currentIndex, config.interestIndexSnapshot);

        return config.interestIndexSnapshot;
    }

    /**
     * @notice Calculates the current interest index for a borrow token
     * @dev Computes accrued interest based on time elapsed since last update
     * @param borrowToken Address of the borrow token
     * @return The current interest index including all accrued interest
     */
    function getCurrentIndex(address borrowToken) public view returns (uint256) {
        BorrowTokenConfig memory config = _getDebtManagerStorage().borrowTokenConfig[borrowToken];
        
        uint256 timeElapsed = block.timestamp - config.lastUpdateTimestamp;
        if (timeElapsed == 0) return config.interestIndexSnapshot;
        
        uint256 interestAccumulated = config.interestIndexSnapshot.mulDiv(config.borrowApy * timeElapsed, HUNDRED_PERCENT);
        return config.interestIndexSnapshot + interestAccumulated;
    }

    /**
     * @notice Returns all borrowings for a user
     * @param user Address of the user
     * @return borrowTokenData Array of token data with borrowing details
     * @return totalBorrowingInUsd Total borrowing amount in USD
     */
    function borrowingOf(address user) public view returns (TokenData[] memory, uint256) {
        DebtManagerStorage storage $ = _getDebtManagerStorage();
        uint256 len = $.supportedBorrowTokens.length;
        TokenData[] memory borrowTokenData = new TokenData[](len);
        uint256 totalBorrowingInUsd = 0;
        uint256 m = 0;

        for (uint256 i = 0; i < len;) {
            address borrowToken = $.supportedBorrowTokens[i];
            uint256 amount = borrowingOf(user, borrowToken);
            if (amount != 0) {
                totalBorrowingInUsd += amount;
                borrowTokenData[m] = TokenData({ token: borrowToken, amount: amount });

                unchecked {
                    ++m;
                }
            }

            unchecked {
                ++i;
            }
        }

        assembly ("memory-safe") {
            mstore(borrowTokenData, m)
        }

        return (borrowTokenData, totalBorrowingInUsd);
    }

    /**
     * @notice Returns borrowing amount for a specific token for a user
     * @param user Address of the user
     * @param borrowToken Address of the borrow token
     * @return Borrowing amount with accrued interest
     */
    function borrowingOf(address user, address borrowToken) public view returns (uint256) {
        DebtManagerStorage storage $ = _getDebtManagerStorage();
        return _getActualBorrowAmount($.userNormalizedBorrowings[user][borrowToken], getCurrentIndex(borrowToken));
    }

    /**
     * @notice Checks if a token is a supported collateral token
     * @param token Address of the token to check
     * @return True if the token is a collateral token, false otherwise
     */
    function isCollateralToken(address token) public view returns (bool) {
        return _getDebtManagerStorage().collateralTokenIndexPlusOne[token] != 0;
    }

    /**
     * @notice Checks if a token is a supported borrow token
     * @param token Address of the token to check
     * @return True if the token is a borrow token, false otherwise
     */
    function isBorrowToken(address token) public view returns (bool) {
        return _getDebtManagerStorage().borrowTokenIndexPlusOne[token] != 0;
    }

    /**
     * @dev Gets the decimals of a token
     * @param token Address of the token
     * @return Decimals of the token
     */
    function _getDecimals(address token) internal view returns (uint8) {
        return IERC20Metadata(token).decimals();
    }
}