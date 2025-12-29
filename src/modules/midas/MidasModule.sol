// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { WithdrawalRequest } from "../../interfaces/ICashModule.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { IMidasVault } from "../../interfaces/IMidasVault.sol";
import { ModuleBase } from "../ModuleBase.sol";
import { ModuleCheckBalance } from "../ModuleCheckBalance.sol";

/**
 * @title MidasModule
 * @author ether.fi
 * @notice Module for interacting with Midas Vaults
 * @dev Extends ModuleBase to provide Midas Vault integration for Safes
 */
contract MidasModule is ModuleBase, ModuleCheckBalance, ReentrancyGuardTransient {
    using MessageHashUtils for bytes32;
    using SafeCast for uint256;

    /**
     * @notice Stores asynchronous withdrawal request details
     * @param amount Amount of tokens to withdraw
     * @param asset The asset to withdraw to (USDC/USDT)
     */
    struct AsyncWithdrawal {
        uint256 amount;
        address asset;
    }

    /// @notice Address of USDC token
    address public immutable usdc;

    /// @notice Address of USDT token
    address public immutable usdt;

    /// @notice Address of the EtherFi Liquid Reserve Midas Vault Token
    address public immutable midasToken;

    /// @notice Address of Midas Liquid Reserve Deposit Vault
    address public immutable depositVault;

    /// @notice Address of Midas Liquid Reserve Redemption Vault
    address public immutable redemptionVault;

    /// @notice TypeHash for deposit function signature
    bytes32 public constant DEPOSIT_SIG = keccak256("deposit");

    /// @notice TypeHash for withdraw function signature
    bytes32 public constant WITHDRAW_SIG = keccak256("withdraw");

    /// @notice TypeHash for async withdraw function signature
    bytes32 public constant REQUEST_ASYNC_WITHDRAW_SIG = keccak256("requestWithdraw");

    /// @notice Cross-chain withdrawal requests for each Safe
    mapping(address safe => AsyncWithdrawal withdrawal) private withdrawals;

    /// @notice Error when native fee is insufficient
    error InsufficientNativeFee();

    /// @notice Error thrown when no async withdrawal is queued for FraxUSD
    error NoAsyncWithdrawalQueued();

    /// @notice Error when the return amount is less than min return
    error InsufficientReturnAmount();

    /// @notice Error thrown when no matching withdrawal is found for the safe
    error CannotFindMatchingWithdrawalForSafe();

    /// @notice Emitted when safe deposits USDC/USDT into Midas Vault
    event Deposit(address indexed safe, address indexed inputToken, uint256 inputAmount, address indexed outputToken, uint256 outputAmount);

    /// @notice Emitted when safe withdraws USDC/USDT from Midas Vault (Synchronously)
    event Withdrawal(address indexed safe, address indexed inputToken, uint256 inputAmount, address indexed outputToken, uint256 outputAmount);

    /// @notice Emitted when safe creates a withdrawal request from Midas Vault
    event WithdrawalRequested(address indexed safe, uint256 amount, address asset, address midasToken);

    /// @notice Emitted when safe executes an async withdrawal from Midas Vault
    event WithdrawalExecuted(address indexed safe, uint256 amount, address asset, address midasToken);

    /**
     * @notice Contract constructor
     * @param _etherFiDataProvider Address of the EtherFiDataProvider contract
     * @param _usdc Address of USDC contract
     * @param _usdt Address of USDT contract
     * @param _midasToken Address of Midas Vault token contract
     * @param _depositVault Address of Deposit Vault
     * @param _redemptionVault Address of Redemption Vault
     * @dev Initializes the contract with supported tokens
     * @custom:throws InvalidInput If any provided address is zero
     */
    constructor(address _etherFiDataProvider, address _usdc, address _usdt, address _midasToken, address _depositVault, address _redemptionVault) ModuleBase(_etherFiDataProvider) ModuleCheckBalance(_etherFiDataProvider) {
        if (_etherFiDataProvider == address(0) || _usdc == address(0) || _usdt == address(0) || _midasToken == address(0) || _depositVault == address(0) || _redemptionVault == address(0)) revert InvalidInput();

        usdc = _usdc;
        usdt = _usdt;
        midasToken = _midasToken;
        depositVault = _depositVault;
        redemptionVault = _redemptionVault;
    }

    /**
     * @notice Deposits USDC/USDT and mints MidasToken using signature verification
     * @param safe The Safe address which holds the deposit tokens
     * @param asset The address of the asset to deposit
     * @param amount The amount of tokens to deposit (6 Decimals)
     * @param minReturnAmount The minimum amount of tokens to return (18 Decimals)
     * @param signer The address that signed the transaction
     * @param signature The signature authorizing the transaction
     * @dev Verifies signature then executes token approval and deposit through the Safe's module execution
     * @custom:throws InvalidInput If amount is zero
     * @custom:throws InvalidSignature If the signature is invalid
     */
    function deposit(address safe, address asset, uint256 amount, uint256 minReturnAmount, address signer, bytes calldata signature) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = _getDepositDigestHash(safe, asset, amount, minReturnAmount);
        _verifyAdminSig(digestHash, signer, signature);
        _deposit(safe, asset, amount, minReturnAmount);
    }

    /**
     * @dev Creates a digest hash for the deposit operation
     * @param safe The Safe address which holds the deposit tokens
     * @param amount The amount to deposit
     * @param minReturnAmount The minimum amount of tokens to return
     * @return The digest hash for signature verification
     */
    function _getDepositDigestHash(address safe, address asset, uint256 amount, uint256 minReturnAmount) internal returns (bytes32) {
        return keccak256(abi.encodePacked(DEPOSIT_SIG, block.chainid, address(this), _useNonce(safe), safe, abi.encode(asset, amount, minReturnAmount))).toEthSignedMessageHash();
    }

    /**
     * @dev Internal function to deposit assets and mint MidasToken
     * @param safe The Safe address which holds the deposit tokens
     * @param asset The address of the asset to deposit
     * @param amount The amount of deposit tokens to deposit (6 decimals) (USDC/USDT)
     * @param minReturnAmount The minimum amount of tokens to return (18 Decimals)
     * @custom:throws InvalidInput If amount or min return is zero
     * @custom:throws InsufficientReturnAmount If the MidasToken received is less than expected
     */
    function _deposit(address safe, address asset, uint256 amount, uint256 minReturnAmount) internal {
        if (amount == 0) revert InvalidInput();

        uint8 decimals = ERC20(asset).decimals();
        uint256 scaledAmount = (amount * 10 ** 18) / 10 ** decimals;

        _checkAmountAvailable(safe, asset, amount);

        address[] memory to;
        bytes[] memory data;
        uint256[] memory values;

        to = new address[](2);
        data = new bytes[](2);
        values = new uint256[](2);

        to[0] = asset;
        data[0] = abi.encodeWithSelector(ERC20.approve.selector, address(depositVault), amount);

        to[1] = address(depositVault);
        data[1] = abi.encodeWithSelector(IMidasVault.depositInstant.selector, asset, scaledAmount, minReturnAmount, 0x00); //Todo: Replace the 0x00 with referrerId

        uint256 midasTokenBefore = ERC20(midasToken).balanceOf(safe);

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        uint256 midasTokenReceived = ERC20(midasToken).balanceOf(safe) - midasTokenBefore;

        if (midasTokenReceived < minReturnAmount) revert InsufficientReturnAmount();

        emit Deposit(safe, asset, amount, midasToken, midasTokenReceived);
    }

    /**
     * @notice Withdraws from Midas Vault from the safe
     * @param safe The Safe address which holds the Midas tokens
     * @param amount The amount of Midas Token to withdraw (18 decimals)
     * @param asset The asset to withdraw to (USDC/USDT)
     * @param minReceiveAmount The minimum tokens to receive of the asset (18 decimals)
     * @param signer The address that signed the transaction
     * @param signature The signature authorizing the transaction
     * @dev Verifies signature then executes token approval and deposit through the Safe's module execution
     * @custom:throws InvalidInput If amount or min return is zero
     * @custom:throws InvalidSignature If the signature is invalid
     */
    function withdraw(address safe, uint128 amount, address asset, uint256 minReceiveAmount, address signer, bytes calldata signature) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = _getWithdrawDigestHash(safe, amount, asset, minReceiveAmount);
        _verifyAdminSig(digestHash, signer, signature);
        _withdraw(safe, amount, asset, minReceiveAmount);
    }

    /**
     * @dev Creates a digest hash for the withdraw operation
     * @param safe The Safe address which holds the Midas tokens
     * @param amount The amount of Midas Token to withdraw (18 decimals)
     * @param asset The asset to withdraw to (USDC/USDT)
     * @param minReceiveAmount The minimum tokens to receive of the asset (18 decimals)
     * @return The digest hash for signature verification
     */
    function _getWithdrawDigestHash(address safe, uint128 amount, address asset, uint256 minReceiveAmount) internal returns (bytes32) {
        return keccak256(abi.encodePacked(WITHDRAW_SIG, block.chainid, address(this), _useNonce(safe), safe, abi.encode(amount, asset, minReceiveAmount))).toEthSignedMessageHash();
    }

    /**
     * @notice Internal function which facilitates withdrawals from the safe
     * @param safe The Safe address which holds the Midas tokens
     * @param amount The amount of Midas Token to withdraw (18 decimals)
     * @param asset The asset to withdraw to (USDC/USDT)
     * @param minReceiveAmount The minimum tokens to receive of the asset (18 decimals)
     * @custom:throws InvalidInput If the Safe doesn't have enough liquid asset balance
     * @custom:throws InvalidSignature If the signature is invalid
     * @custom:throws InsufficientReturnAmount If the USDC/USDT received is less than expected
     */
    function _withdraw(address safe, uint128 amount, address asset, uint256 minReceiveAmount) internal {
        if (amount == 0) revert InvalidInput();

        _checkAmountAvailable(safe, midasToken, amount);

        address[] memory to = new address[](2);
        bytes[] memory data = new bytes[](2);
        uint256[] memory values = new uint256[](2);

        to[0] = midasToken;
        data[0] = abi.encodeWithSelector(ERC20.approve.selector, redemptionVault, amount);

        to[1] = address(redemptionVault);
        data[1] = abi.encodeWithSelector(IMidasVault.redeemInstant.selector, asset, amount, minReceiveAmount);

        uint256 tokensBefore = ERC20(asset).balanceOf(safe);

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        uint256 tokensReceived = ERC20(asset).balanceOf(safe) - tokensBefore;

        //scale for decimals difference between USDC/USDT (6) and MidasToken (18)
        uint256 scaledTokensReceived = tokensReceived * 10 ** 12;
        if (scaledTokensReceived < minReceiveAmount) revert InsufficientReturnAmount();

        emit Withdrawal(safe, midasToken, amount, asset, tokensReceived);
    }

    /**
     * @notice Gets the pending withdrawal request for a safe
     * @param safe Address of the EtherFi Safe
     * @return AsyncWithdrawal containing the pending withdrawal request details
     */
    function getPendingWithdrawal(address safe) external view returns (AsyncWithdrawal memory) {
        return withdrawals[safe];
    }

    /**
     * @notice Function to create a async withdrawal request
     * @param safe Address for user safe
     * @param asset Address of Asset to withdraw to
     * @param amount Amount to withdraw asynchronously (18 decimals)
     * @param signer The address that signed the transaction
     * @param signature The signature authorizing this transaction
     */
    function requestWithdrawal(address safe, address asset, uint256 amount, address signer, bytes calldata signature) external payable onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = _getRequestWithdrawDigestHash(safe, asset, amount);
        _verifyAdminSig(digestHash, signer, signature);
        _requestAsyncWithdraw(safe, asset, amount);
    }

    /**
     * @notice Executes a previously requested async withdrawal transaction
     * @param safe The Safe address that requested the withdrawal
     * @dev Verifies the withdrawal request matches the stored withdrawal details before execution
     * @custom:throws NoAsyncWithdrawalQueued If no async withdrawal request exists for the safe
     * @custom:throws CannotFindMatchingWithdrawalForSafe If the withdrawal details don't match
     */
    function executeWithdraw(address safe) public payable nonReentrant onlyEtherFiSafe(safe) {
        AsyncWithdrawal memory withdrawal = withdrawals[safe];
        if (withdrawal.asset == address(0)) revert NoAsyncWithdrawalQueued();

        WithdrawalRequest memory withdrawalRequest = cashModule.getData(safe).pendingWithdrawalRequest;

        if (withdrawalRequest.recipient != address(this) || withdrawalRequest.tokens.length != 1 || withdrawalRequest.tokens[0] != midasToken || withdrawalRequest.amounts[0] != withdrawal.amount) revert CannotFindMatchingWithdrawalForSafe();
        cashModule.processWithdrawal(safe);

        _executeWithdraw(safe, withdrawal.asset, withdrawal.amount);
        delete withdrawals[safe];
    }

    /**
     * @dev Creates a digest hash for the async withdraw operation
     * @param asset Address of asset to withdraw to
     * @param amount Amount to withdraw asynchronously
     * @return The digest hash for signature verification
     */
    function _getRequestWithdrawDigestHash(address safe, address asset, uint256 amount) internal returns (bytes32) {
        return keccak256(abi.encodePacked(REQUEST_ASYNC_WITHDRAW_SIG, block.chainid, address(this), _useNonce(safe), safe, abi.encode(midasToken, asset, amount))).toEthSignedMessageHash();
    }

    /**
     * @notice Function to request an async withdrawal
     * @param safe Address for user safe
     * @param asset Address of asset to withdraw to
     * @param amount Amount to withdraw asynchronously
     * @custom:throws InvalidInput If the amount is zero
     */
    function _requestAsyncWithdraw(address safe, address asset, uint256 amount) internal {
        if (amount == 0 || asset == address(0)) revert InvalidInput();

        cashModule.requestWithdrawalByModule(safe, midasToken, amount);

        emit WithdrawalRequested(safe, amount, asset, midasToken);

        (uint64 withdrawalDelay,,) = cashModule.getDelays();
        if (withdrawalDelay == 0) {
            _executeWithdraw(safe, asset, amount);
        } else {
            withdrawals[safe] = AsyncWithdrawal({ amount: amount, asset: asset });
        }
    }

    /**
     * @notice Internal function to execute an async withdrawal
     * @param safe The Safe address that requested the withdrawal
     * @param _asset The asset to withdraw to
     * @param _amount Amount to withdraw asynchronously
     */
    function _executeWithdraw(address safe, address _asset, uint256 _amount) internal {
        if (_amount == 0) revert InvalidInput();

        ERC20(midasToken).approve(redemptionVault, _amount);
        IMidasVault(redemptionVault).redeemRequest(_asset, _amount);

        emit WithdrawalExecuted(safe, _amount, _asset, midasToken);
    }
}
