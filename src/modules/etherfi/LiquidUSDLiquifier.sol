// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { UpgradeableProxy } from "../../utils/UpgradeableProxy.sol";
import { IDebtManager } from "../../interfaces/IDebtManager.sol";
import { ModuleCheckBalance } from "../ModuleCheckBalance.sol";
import { IEtherFiDataProvider } from "../../interfaces/IEtherFiDataProvider.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { IBoringOnChainQueue } from "../../interfaces/IBoringOnChainQueue.sol";
import { Constants } from "../../utils/Constants.sol";

/**
 * @title LiquidUSDLiquifierModule
 * @notice Module for liquifying Liquid USD into USDC and repay on debt manager
 */
contract LiquidUSDLiquifierModule is Constants, UpgradeableProxy, ModuleCheckBalance {
    using SafeERC20 for IERC20;

    /// @notice Address of the Liquid USD token
    IERC20 public constant LIQUID_USD = IERC20(0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C);

    /// @notice Address of the USDC token
    IERC20 public constant USDC = IERC20(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
    
    /// @notice Address of the Liquid USD boring queue
    IBoringOnChainQueue public constant LIQUID_USD_BORING_QUEUE = IBoringOnChainQueue(0x38FC1BA73b7ED289955a07d9F11A85b6E388064A);

    /// @notice Role identifier for Etherfi wallet
    bytes32 public constant ETHER_FI_WALLET_ROLE = keccak256("ETHER_FI_WALLET_ROLE");
    
    /// @notice Role identifier for Settlement Dispatcher Bridger
    bytes32 public constant SETTLEMENT_DISPATCHER_BRIDGER_ROLE = keccak256("SETTLEMENT_DISPATCHER_BRIDGER_ROLE");
    
    /// @notice Address of the Debt Manager
    IDebtManager public immutable debtManager;
    
    /// @notice Address of the EtherFi Data Provider
    IEtherFiDataProvider public immutable etherFiDataProvider;

    /**
     * @notice Emitted when user repays using Liquid USD
     * @param user Address of the user
     * @param usdcRepaid Amount of USDC repaid
     * @param liquidUsdAmountRepaid Amount of Liquid USD repaid
     */
    event RepaidUsingLiquidUSD(address indexed user, uint256 usdcRepaid, uint256 liquidUsdAmountRepaid);

    /**
     * @notice Emitted when Liquid USD withdrawal is requested
     * @param amount Amount of Liquid USD to withdraw
     * @param amountOutFromQueue Amount of USDC to receive
     */
    event LiquidUSDWithdrawalRequested(uint128 amount, uint128 amountOutFromQueue);

    /**
     * @notice Emitted when funds are withdrawn
     * @param token Address of the token withdrawn
     * @param amount Amount of tokens withdrawn
     * @param recipient Address of the recipient
     */
    event FundsWithdrawn(address indexed token, uint256 amount, address indexed recipient);
    
    /// @notice Thrown when the account is not an instance of the deployed EtherfiSafe
    error OnlyEtherFiSafe();
    /// @notice Thrown when the contract has insufficient USDC balance
    error InsufficientUsdcBalance();
    /// @notice Thrown when the caller is not an Etherfi wallet
    error OnlyEtherFiWallet();
    /// @notice Thrown when the conversion is invalid
    error InvalidConversion();
    /// @notice Thrown when the return amount is less than the minimum return
    error InsufficientReturnAmount();
    /// @notice Thrown when the caller is not a Settlement Dispatcher Bridger
    error OnlySettlementDispatcherBridger();
    /// @notice Thrown when the value is invalid
    error InvalidValue();
    /// @notice Thrown when the amount is 0
    error CannotWithdrawZeroAmount();
    /// @notice Thrown when the withdrawal of funds fails
    error WithdrawFundsFailed();

    /**
     * @notice Contract constructor
     * @param _debtManager Address of the Debt Manager
     * @param _etherFiDataProvider Address of the EtherFi Data Provider
     * @dev Initializes the contract with the Debt Manager and EtherFi Data Provider
     */
    constructor(address _debtManager, address _etherFiDataProvider) ModuleCheckBalance(_etherFiDataProvider) {
        debtManager = IDebtManager(_debtManager);
        etherFiDataProvider = IEtherFiDataProvider(_etherFiDataProvider);
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract
     * @param _roleRegistry Address of the Role Registry
     * @dev Initializes the contract with the Role Registry
     */
    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
    }

    /**
     * @notice Repays using Liquid USD
     * @param user Address of the user
     * @param liquidUsdAmount Amount of Liquid USD to repay
     * @dev Repays using Liquid USD
     */
    function repayUsingLiquidUSD(address user, uint256 liquidUsdAmount) external onlyEtherFiSafe(user) onlyEtherFiWallet() {
        _checkAmountAvailable(user, address(LIQUID_USD), liquidUsdAmount);
        uint256 usdAmount = convertLiquidUSDToUsd(liquidUsdAmount);

        if (USDC.balanceOf(address(this)) < usdAmount) revert InsufficientUsdcBalance();

        address[] memory to = new address[](1);
        bytes[] memory data = new bytes[](1);
        uint256[] memory values = new uint256[](1);

        to[0] = address(LIQUID_USD);
        data[0] = abi.encodeWithSelector(IERC20.approve.selector, address(this), liquidUsdAmount);
        values[0] = 0;

        IEtherFiSafe(user).execTransactionFromModule(to, values, data);

        LIQUID_USD.safeTransferFrom(user, address(this), liquidUsdAmount);

        uint256 usdcAmountBefore = USDC.balanceOf(address(this));

        USDC.forceApprove(address(debtManager), usdAmount);
        debtManager.repay(user, address(USDC), usdAmount);

        uint256 usdcRepaid = usdcAmountBefore - USDC.balanceOf(address(this));
        uint256 liquidUsdAmountRepaid = liquidUsdAmount;

        if (usdcRepaid > usdAmount) revert InvalidConversion();
        else if (usdcRepaid < usdAmount) {
            uint256 liquidUsdAmountToRepay = convertUsdToLiquidUSD(usdAmount - usdcRepaid);
            liquidUsdAmountRepaid -= liquidUsdAmountToRepay;
            LIQUID_USD.safeTransfer(user, liquidUsdAmountToRepay);
        }

        emit RepaidUsingLiquidUSD(user, usdcRepaid, liquidUsdAmountRepaid);
    }

    /**
     * @notice Withdraws Liquid USD
     * @param amount Amount of Liquid USD to withdraw
     * @param minReturn Minimum return amount
     * @param discount Discount in bps
     * @param secondsToDeadline Expiry deadline in seconds
     */
    function withdrawLiquidUSD(uint128 amount, uint128 minReturn, uint16 discount, uint24 secondsToDeadline) external {
        if (!roleRegistry().hasRole(SETTLEMENT_DISPATCHER_BRIDGER_ROLE, msg.sender)) revert OnlySettlementDispatcherBridger();

        uint128 amountOutFromQueue = LIQUID_USD_BORING_QUEUE.previewAssetsOut(address(USDC), amount, discount);
        if (amountOutFromQueue < minReturn) revert InsufficientReturnAmount();

        LIQUID_USD.forceApprove(address(LIQUID_USD_BORING_QUEUE), amount);
        LIQUID_USD_BORING_QUEUE.requestOnChainWithdraw(address(USDC), amount, discount, secondsToDeadline);

        emit LiquidUSDWithdrawalRequested(amount, amountOutFromQueue);
    }

    /**
     * @notice Withdraws funds from the contract
     * @param token Address of the token to withdraw
     * @param recipient Address to receive the withdrawn funds
     * @param amount Amount of tokens to withdraw
     */
    function withdrawFunds(address token, address recipient, uint256 amount) external onlyRoleRegistryOwner() {
        if (recipient == address(0)) revert InvalidValue();
        amount = _withdrawFunds(token, recipient, amount);
        emit FundsWithdrawn(token, amount, recipient);
    }

    /**
     * @notice Internal function to handle withdrawal of tokens or ETH
     * @dev Used by both withdrawFunds and transferFundsToRefundWallet
     * @param token Address of the token to withdraw 
     * @param recipient Address to receive the withdrawn funds
     * @param amount Amount to withdraw (0 to withdraw all available balance)
     * @custom:throws CannotWithdrawZeroAmount If attempting to withdraw zero tokens or ETH
     * @custom:throws WithdrawFundsFailed If ETH transfer fails
     */    
    function _withdrawFunds(address token, address recipient, uint256 amount) internal returns (uint256) {
        if (token == ETH) {
            if (amount == 0) amount = address(this).balance;
            if (amount == 0) revert CannotWithdrawZeroAmount();
            (bool success, ) = payable(recipient).call{value: amount}("");
            if (!success) revert  WithdrawFundsFailed();
        } else {
            if (amount == 0) amount = IERC20(token).balanceOf(address(this));
            if (amount == 0) revert CannotWithdrawZeroAmount();
            IERC20(token).safeTransfer(recipient, amount);
        }

        return amount;
    }
    
    /**
     * @notice Converts USD to Liquid USD
     * @param usdAmount Amount of USD to convert
     * @return Amount of Liquid USD
     */
    function convertUsdToLiquidUSD(uint256 usdAmount) public view returns (uint256) {
        return debtManager.convertUsdToCollateralToken(address(LIQUID_USD), usdAmount);
    }

    /**
     * @notice Converts Liquid USD to USD
     * @param liquidUsdAmount Amount of Liquid USD to convert
     * @return Amount of USD
     */
    function convertLiquidUSDToUsd(uint256 liquidUsdAmount) public view returns (uint256) {
        return debtManager.convertCollateralTokenToUsd(address(LIQUID_USD), liquidUsdAmount);
    }

    /**
     * @notice Ensures that the account is an instance of the deployed EtherfiSafe
     * @param account The account address to check
     */
    modifier onlyEtherFiSafe(address account) {
        if (!etherFiDataProvider.isEtherFiSafe(account)) revert OnlyEtherFiSafe();
        _;
    }

    /**
     * @notice Ensures that the caller is an Etherfi wallet
     */
    modifier onlyEtherFiWallet() {
        if (!roleRegistry().hasRole(ETHER_FI_WALLET_ROLE, msg.sender)) revert OnlyEtherFiWallet();
        _;
    }
}