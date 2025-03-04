// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControlDefaultAdminRulesUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import { Initializable, UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ICashDataProvider } from "../interfaces/ICashDataProvider.sol";
import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { IDebtManager } from "../interfaces/IDebtManager.sol";
import { IPriceProvider } from "../interfaces/IPriceProvider.sol";
import { ReentrancyGuardTransientUpgradeable } from "../utils/ReentrancyGuardTransientUpgradeable.sol";

/**
 * @title Debt Manager
 * @author @seongyun-ko @shivam-ef
 * @notice Contract to manage lending and borrowing for Cash protocol
 */
contract DebtManagerStorage is Initializable, UUPSUpgradeable, AccessControlDefaultAdminRulesUpgradeable, ReentrancyGuardTransientUpgradeable {
    using Math for uint256;

    struct BorrowTokenConfigData {
        uint64 borrowApy;
        uint128 minShares;
    }

    struct BorrowTokenConfig {
        uint256 interestIndexSnapshot;
        uint256 totalBorrowingAmount;
        uint256 totalSharesOfBorrowTokens;
        uint64 lastUpdateTimestamp;
        uint64 borrowApy;
        uint128 minShares;
    }

    struct CollateralTokenConfig {
        uint80 ltv;
        uint80 liquidationThreshold;
        uint96 liquidationBonus;
    }

    struct TokenData {
        address token;
        uint256 amount;
    }

    struct LiquidationTokenData {
        address token;
        uint256 amount;
        uint256 liquidationBonus;
    }

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    uint256 public constant HUNDRED_PERCENT = 100e18;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant SIX_DECIMALS = 1e6;

    //keccak256("DebtManager.admin.impl");
    bytes32 constant adminImplPosition = 0x49d4a010ddc5f453173525f0adf6cfb97318b551312f237c11fd9f432a1f5d21;

    IEtherFiDataProvider public etherFiDataProvider;

    address[] internal _supportedCollateralTokens;
    address[] internal _supportedBorrowTokens;
    mapping(address token => uint256 index) internal _collateralTokenIndexPlusOne;
    mapping(address token => uint256 index) internal _borrowTokenIndexPlusOne;
    mapping(address borrowToken => BorrowTokenConfig config) internal _borrowTokenConfig;

    // Collateral held by the user
    // mapping(address user => mapping(address token => uint256 amount)) internal _userCollateral;
    // Total collateral held by the users with the contract
    // mapping(address token => uint256 amount) internal _totalCollateralAmounts;
    mapping(address token => CollateralTokenConfig config) internal _collateralTokenConfig;

    // Borrowings is in USD with 6 decimals
    mapping(address user => mapping(address borrowToken => uint256 borrowing)) internal _userBorrowings;
    // Snapshot of user's interests already paid
    mapping(address user => mapping(address borrowToken => uint256 interestSnapshot)) internal _usersDebtInterestIndexSnapshots;
    // Shares have 18 decimals
    mapping(address supplier => mapping(address borrowToken => uint256 shares)) internal _sharesOfBorrowTokens;

    uint256 public constant MAX_BORROW_APY = 1_585_489_599_188; // 50% / (365 days in seconds)

    event Supplied(address indexed sender, address indexed user, address indexed token, uint256 amount);
    event Borrowed(address indexed user, address indexed token, uint256 amount);
    event Repaid(address indexed user, address indexed payer, address indexed token, uint256 amount);
    event Liquidated(address indexed liquidator, address indexed user, address indexed debtTokenToLiquidate, IDebtManager.LiquidationTokenData[] userCollateralLiquidated, uint256 beforeDebtAmount, uint256 debtAmountLiquidated);
    event LiquidationThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event CollateralTokenAdded(address token);
    event CollateralTokenRemoved(address token);
    event BorrowTokenAdded(address token);
    event BorrowTokenRemoved(address token);
    event BorrowApySet(address indexed token, uint256 oldApy, uint256 newApy);
    event MinSharesOfBorrowTokenSet(address indexed token, uint128 oldMinShares, uint128 newMinShares);
    event UserInterestAdded(address indexed user, uint256 borrowingAmtBeforeInterest, uint256 borrowingAmtAfterInterest);
    event TotalBorrowingUpdated(address indexed borrowToken, uint256 totalBorrowingAmtBeforeInterest, uint256 totalBorrowingAmtAfterInterest);
    event BorrowTokenConfigSet(address indexed token, BorrowTokenConfig config);
    event CollateralTokenConfigSet(address indexed collateralToken, CollateralTokenConfig oldConfig, CollateralTokenConfig newConfig);
    event WithdrawBorrowToken(address indexed withdrawer, address indexed borrowToken, uint256 amount);

    error UnsupportedCollateralToken();
    error UnsupportedRepayToken();
    error UnsupportedBorrowToken();
    error InsufficientCollateral();
    error InsufficientCollateralToRepay();
    error InsufficientLiquidity();
    error CannotLiquidateYet();
    error ZeroCollateralValue();
    error OnlyUserCanRepayWithCollateral();
    error InvalidValue();
    error AlreadyCollateralToken();
    error AlreadyBorrowToken();
    error NotACollateralToken();
    error NoCollateralTokenLeft();
    error NotABorrowToken();
    error NoBorrowTokenLeft();
    error ArrayLengthMismatch();
    error TotalCollateralAmountNotZero();
    error InsufficientLiquidityPleaseTryAgainLater();
    error LiquidAmountLesserThanRequired();
    error ZeroTotalBorrowTokens();
    error InsufficientBorrowShares();
    error UserStillLiquidatable();
    error TotalBorrowingsForUserNotZero();
    error BorrowTokenConfigAlreadySet();
    error AccountUnhealthy();
    error BorrowTokenStillInTheSystem();
    error RepaymentAmountIsZero();
    error LiquidatableAmountIsZero();
    error LtvCannotBeGreaterThanLiquidationThreshold();
    error OraclePriceZero();
    error BorrowAmountZero();
    error SharesCannotBeZero();
    error SharesCannotBeLessThanMinShares();
    error SupplyCapBreached();
    error OnlyEtherFiSafe();
    error EtherFiSafeCannotSupplyDebtTokens();
    error NotAEtherFiSafe();
    error BorrowTokenCannotBeRemovedFromCollateral();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initializeOnUpgrade(address _etherFiDataProvider) public reinitializer(2) {
        etherFiDataProvider = IEtherFiDataProvider(_etherFiDataProvider);
    }

    /**
     * @notice set the implementation for the admin, this needs to be in a base class else we cannot set it
     * @param newImpl address of the implementation
     */
    function setAdminImpl(address newImpl) external onlyRole(ADMIN_ROLE) {
        bytes32 position = adminImplPosition;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            sstore(position, newImpl)
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }

    function _getTotalBorrowTokenAmount(address borrowToken) internal view returns (uint256) {
        return convertUsdToCollateralToken(borrowToken, totalBorrowingAmount(borrowToken)) + IERC20(borrowToken).balanceOf(address(this));
    }

    function convertUsdToCollateralToken(address collateralToken, uint256 debtUsdAmount) public view returns (uint256) {
        if (!isCollateralToken(collateralToken)) {
            revert UnsupportedCollateralToken();
        }
        return (debtUsdAmount * 10 ** _getDecimals(collateralToken)) / IPriceProvider(etherFiDataProvider.getPriceProvider()).price(collateralToken);
    }

    function totalBorrowingAmount(address borrowToken) public view returns (uint256) {
        return _getAmountWithInterest(borrowToken, _borrowTokenConfig[borrowToken].totalBorrowingAmount, _borrowTokenConfig[borrowToken].interestIndexSnapshot);
    }

    function _getAmountWithInterest(address borrowToken, uint256 amountBefore, uint256 accInterestAlreadyAdded) internal view returns (uint256) {
        return ((PRECISION * (amountBefore * (debtInterestIndexSnapshot(borrowToken) - accInterestAlreadyAdded))) / HUNDRED_PERCENT + PRECISION * amountBefore) / PRECISION;
    }

    function debtInterestIndexSnapshot(address borrowToken) public view returns (uint256) {
        return _borrowTokenConfig[borrowToken].interestIndexSnapshot + (block.timestamp - _borrowTokenConfig[borrowToken].lastUpdateTimestamp) * _borrowTokenConfig[borrowToken].borrowApy;
    }

    function _updateBorrowings(address user) internal {
        uint256 len = _supportedBorrowTokens.length;
        for (uint256 i = 0; i < len;) {
            _updateBorrowings(user, _supportedBorrowTokens[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _updateBorrowings(address user, address borrowToken) internal {
        uint256 totalBorrowingAmtBeforeInterest = _borrowTokenConfig[borrowToken].totalBorrowingAmount;

        _borrowTokenConfig[borrowToken].interestIndexSnapshot = debtInterestIndexSnapshot(borrowToken);
        _borrowTokenConfig[borrowToken].totalBorrowingAmount = totalBorrowingAmount(borrowToken);
        _borrowTokenConfig[borrowToken].lastUpdateTimestamp = uint64(block.timestamp);

        if (totalBorrowingAmtBeforeInterest != _borrowTokenConfig[borrowToken].totalBorrowingAmount) {
            emit TotalBorrowingUpdated(borrowToken, totalBorrowingAmtBeforeInterest, _borrowTokenConfig[borrowToken].totalBorrowingAmount);
        }

        if (user != address(0)) {
            uint256 userBorrowingsBefore = _userBorrowings[user][borrowToken];
            _userBorrowings[user][borrowToken] = borrowingOf(user, borrowToken);
            _usersDebtInterestIndexSnapshots[user][borrowToken] = _borrowTokenConfig[borrowToken].interestIndexSnapshot;

            if (userBorrowingsBefore != _userBorrowings[user][borrowToken]) {
                emit UserInterestAdded(user, userBorrowingsBefore, _userBorrowings[user][borrowToken]);
            }
        }
    }

    function borrowingOf(address user) public view returns (TokenData[] memory, uint256) {
        uint256 len = _supportedBorrowTokens.length;
        TokenData[] memory borrowTokenData = new TokenData[](len);
        uint256 totalBorrowingInUsd = 0;
        uint256 m = 0;

        for (uint256 i = 0; i < len;) {
            address borrowToken = _supportedBorrowTokens[i];
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

    function borrowingOf(address user, address borrowToken) public view returns (uint256) {
        return _getAmountWithInterest(borrowToken, _userBorrowings[user][borrowToken], _usersDebtInterestIndexSnapshots[user][borrowToken]);
    }

    function isCollateralToken(address token) public view returns (bool) {
        return _collateralTokenIndexPlusOne[token] != 0;
    }

    function isBorrowToken(address token) public view returns (bool) {
        return _borrowTokenIndexPlusOne[token] != 0;
    }

    function _getDecimals(address token) internal view returns (uint8) {
        return IERC20Metadata(token).decimals();
    }
}
