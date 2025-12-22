// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { WithdrawalRequest } from "../../interfaces/ICashModule.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { IFraxCustodian } from "../../interfaces/IFraxCustodian.sol";
import { IFraxRemoteHop, MessagingFee } from "../../interfaces/IFraxRemoteHop.sol";
import { ModuleBase } from "../ModuleBase.sol";
import { ModuleCheckBalance } from "../ModuleCheckBalance.sol";

/**
 * @title FraxModule
 * @author ether.fi
 * @notice Module for interacting with FraxUSD
 * @dev Extends ModuleBase to provide FraxUSD integration for Safes
 */
contract FraxModule is ModuleBase, ModuleCheckBalance, ReentrancyGuardTransient {
    using MessageHashUtils for bytes32;
    using SafeCast for uint256;

    /**
     * @notice Stores asynchronous withdrawal request details
     * @param amount Amount of tokens to withdraw
     * @param recipient Recipient address provided by Frax API
     */
    struct AsyncWithdrawal {
        uint256 amount;
        address recipient;
    }

    /// @notice Address of the USDC token
    address public immutable usdc;

    /// @notice Address of the Frax USD token
    address public immutable fraxusd;

    /// @notice Address of Frax USD Custodian
    address public immutable custodian;

    /// @notice Address of the Frax USD Remote Hop contract
    address public immutable remoteHop;

    /// @notice Layerzero ethereum EID
    uint32 public constant ETHEREUM_EID = 30_101;

    /// @notice TypeHash for deposit function signature
    bytes32 public constant DEPOSIT_SIG = keccak256("deposit");

    /// @notice TypeHash for withdraw function signature
    bytes32 public constant WITHDRAW_SIG = keccak256("withdraw");

    /// @notice TypeHash for async withdraw function signature
    bytes32 public constant REQUEST_ASYNC_WITHDRAW_SIG = keccak256("requestAsyncWithdraw");

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

    /// @notice Emitted when safe deposits USDC into Frax USD
    event Deposit(address indexed safe, address indexed inputToken, uint256 inputAmount, uint256 outputAmount);

    /// @notice Emitted when safe withdraws USDC from Frax USD (Synchronously)
    event Withdrawal(address indexed safe, uint256 amountToWithdraw, uint256 amountOut);

    /// @notice Emitted when safe creates an async withdrawal Request from FraxUSD
    event AsyncWithdrawalRequested(address indexed safe, uint256 amountToWithdraw, uint32 dstEid, address to);

    /// @notice Emitted when safe executes an async withdrawal from FraxUSD
    event AsyncWithdrawalExecuted(address indexed safe, uint256 amountToWithdraw, uint32 dstEid, address to);

    /**
     * @notice Contract constructor
     * @param _etherFiDataProvider Address of the EtherFiDataProvider contract
     * @param _fraxusd Address of the FRAXUSD token
     * @param _usdc Address of the USDC token
     * @param _custodian Address of the FraxUSD custodian
     * @param _remoteHop Remote Hop address of FraxUSD
     * @dev Initializes the contract with supported tokens
     * @custom:throws InvalidInput If any provided address is zero
     */
    constructor(address _etherFiDataProvider, address _fraxusd, address _usdc, address _custodian, address _remoteHop) ModuleBase(_etherFiDataProvider) ModuleCheckBalance(_etherFiDataProvider) {
        if (_etherFiDataProvider == address(0) || _fraxusd == address(0) || _remoteHop == address(0)) revert InvalidInput();

        fraxusd = _fraxusd;
        usdc = _usdc;
        custodian = _custodian;
        remoteHop = _remoteHop;
    }

    /**
     * @notice Deposits USDC and mints FraxUSD using signature verification
     * @param safe The Safe address which holds the USDC tokens
     * @param assetToDeposit The address of the asset to deposit
     * @param amountToDeposit The amount of USDC tokens to deposit
     * @param signer The address that signed the transaction
     * @param signature The signature authorizing the transaction
     * @dev Verifies signature then executes token approval and deposit through the Safe's module execution
     * @custom:throws InvalidInput If amount is zero
     * @custom:throws InvalidSignature If the signature is invalid
     */
    function deposit(address safe, address assetToDeposit, uint256 amountToDeposit, address signer, bytes calldata signature) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = _getDepositDigestHash(safe, assetToDeposit, amountToDeposit);
        _verifyAdminSig(digestHash, signer, signature);
        _deposit(safe, assetToDeposit, amountToDeposit);
    }

    /**
     * @dev Creates a digest hash for the deposit operation
     * @param safe The Safe address which holds the USDC tokens
     * @param amountToDeposit The amount to deposit
     * @return The digest hash for signature verification
     */
    function _getDepositDigestHash(address safe, address assetToDeposit, uint256 amountToDeposit) internal returns (bytes32) {
        return keccak256(abi.encodePacked(DEPOSIT_SIG, block.chainid, address(this), _useNonce(safe), safe, abi.encode(assetToDeposit, amountToDeposit))).toEthSignedMessageHash();
    }

    /**
     * @dev Internal function to deposit USDC to FraxUSD custodian
     * @param safe The Safe address which holds the USDC tokens
     * @param assetToDeposit The address of the asset to deposit
     * @param amountToDeposit The amount of USDC tokens to deposit (6 decimals)
     * @custom:throws InvalidInput If amount or min return is zero
     * @custom:throws InsufficientReturnAmount If the FraxUSD received is less than expected
     */
    function _deposit(address safe, address assetToDeposit, uint256 amountToDeposit) internal {
        if (amountToDeposit == 0) revert InvalidInput();

        _checkAmountAvailable(safe, assetToDeposit, amountToDeposit);

        address[] memory to;
        bytes[] memory data;
        uint256[] memory values;

        to = new address[](2);
        data = new bytes[](2);
        values = new uint256[](2);

        to[0] = assetToDeposit;
        data[0] = abi.encodeWithSelector(ERC20.approve.selector, address(custodian), amountToDeposit);

        to[1] = address(custodian);
        data[1] = abi.encodeWithSelector(IFraxCustodian.deposit.selector, amountToDeposit, safe);

        uint256 fraxUSDTokenBefore = ERC20(fraxusd).balanceOf(safe);

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        uint256 fraxUSDTokenReceived = ERC20(fraxusd).balanceOf(safe) - fraxUSDTokenBefore;

        uint8 decimals = ERC20(assetToDeposit).decimals();
        uint256 scaledAmountToDeposit = (amountToDeposit * 10 ** 18) / 10 ** decimals;

        if (fraxUSDTokenReceived < scaledAmountToDeposit) revert InsufficientReturnAmount();

        emit Deposit(safe, assetToDeposit, amountToDeposit, fraxUSDTokenReceived);
    }

    /**
     * @notice Withdraws from FraxUSD from the safe
     * @param safe The Safe address which holds the FraxUSD tokens
     * @param amountToWithdraw The amount of FraxUSD to withdraw (18 decimals)
     * @param signer The address that signed the transaction
     * @param signature The signature authorizing the transaction
     * @dev Verifies signature then executes token approval and deposit through the Safe's module execution
     * @custom:throws InvalidInput If amount or min return is zero
     * @custom:throws InvalidSignature If the signature is invalid
     */
    function withdraw(address safe, uint128 amountToWithdraw, address signer, bytes calldata signature) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = _getWithdrawDigestHash(safe, amountToWithdraw);
        _verifyAdminSig(digestHash, signer, signature);
        _withdraw(safe, amountToWithdraw);
    }

    /**
     * @dev Creates a digest hash for the withdraw operation
     * @param safe The Safe address which holds the FraxUSD tokens
     * @param amountToWithdraw The amount to withdraw
     * @return The digest hash for signature verification
     */
    function _getWithdrawDigestHash(address safe, uint128 amountToWithdraw) internal returns (bytes32) {
        return keccak256(abi.encodePacked(WITHDRAW_SIG, block.chainid, address(this), _useNonce(safe), safe, abi.encode(amountToWithdraw))).toEthSignedMessageHash();
    }

    /**
     * @notice Internal function which facilitates withdrawals from the safe
     * @param safe The Safe address which holds the FraxUSD tokens
     * @param amountToWithdraw The amount of FraxuSD tokens to withdraw
     * @custom:throws InvalidInput If the Safe doesn't have enough liquid asset balance
     * @custom:throws InvalidSignature If the signature is invalid
     * @custom:throws InsufficientReturnAmount If the USDC received is less than expected
     */
    function _withdraw(address safe, uint128 amountToWithdraw) internal {
        if (amountToWithdraw == 0) revert InvalidInput();

        _checkAmountAvailable(safe, fraxusd, amountToWithdraw);

        address[] memory to = new address[](2);
        bytes[] memory data = new bytes[](2);
        uint256[] memory values = new uint256[](2);

        to[0] = fraxusd;
        data[0] = abi.encodeWithSelector(ERC20.approve.selector, custodian, amountToWithdraw);

        to[1] = address(custodian);
        data[1] = abi.encodeWithSelector(IFraxCustodian.redeem.selector, amountToWithdraw, safe, safe);

        uint256 usdcTokenBefore = ERC20(usdc).balanceOf(safe);

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        uint256 usdcTokenReceived = ERC20(usdc).balanceOf(safe) - usdcTokenBefore;

        //scale for decimals difference between USDC (6) and FraxUSD (18)
        uint256 scaledUsdcTokenReceived = usdcTokenReceived * 10 ** 12;
        if (scaledUsdcTokenReceived < amountToWithdraw) revert InsufficientReturnAmount();

        emit Withdrawal(safe, amountToWithdraw, scaledUsdcTokenReceived);
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
     * @notice Function to quote bridging fee for async redemption
     * @param _recipient Deposit address from Frax api
     * @param _withdrawAmount Amount to redeem asynchronously
     * @return fee MessagingFee struct quoting fee for bridging
     */
    function quoteAsyncWithdraw(address _recipient, uint256 _withdrawAmount) external view returns (MessagingFee memory fee) {
        bytes32 _to = bytes32(bytes20(_recipient));
        return IFraxRemoteHop(remoteHop).quote(fraxusd, ETHEREUM_EID, _to, _withdrawAmount);
    }

    /**
     * @notice Function to create a async withdrawal request
     * @param safe Address for user safe
     * @param _recipient Recipient address from Frax api
     * @param _withdrawAmount Amount to withdraw asynchronously
     * @param signer The address that signed the transaction
     * @param signature The signature authorizing this transaction
     */
    function requestAsyncWithdraw(address safe, address _recipient, uint256 _withdrawAmount, address signer, bytes calldata signature) external payable onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = _getRequestAsyncWithdrawDigestHash(safe, _recipient, _withdrawAmount);
        _verifyAdminSig(digestHash, signer, signature);
        _requestAsyncWithdraw(safe, _recipient, _withdrawAmount);
    }

    /**
     * @notice Executes a previously requested async withdrawal transaction
     * @param safe The Safe address that requested the withdrawal
     * @dev Verifies the withdrawal request matches the stored withdrawal details before execution
     * @custom:throws NoAsyncWithdrawalQueued If no async withdrawal request exists for the safe
     * @custom:throws CannotFindMatchingWithdrawalForSafe If the withdrawal details don't match
     */
    function executeAsyncWithdraw(address safe) public payable nonReentrant onlyEtherFiSafe(safe) {
        AsyncWithdrawal memory withdrawal = withdrawals[safe];
        if (withdrawal.recipient == address(0)) revert NoAsyncWithdrawalQueued();

        WithdrawalRequest memory withdrawalRequest = cashModule.getData(safe).pendingWithdrawalRequest;

        if (withdrawalRequest.recipient != address(this) || withdrawalRequest.tokens.length != 1 || withdrawalRequest.tokens[0] != fraxusd || withdrawalRequest.amounts[0] != withdrawal.amount) revert CannotFindMatchingWithdrawalForSafe();
        cashModule.processWithdrawal(safe);

        _asyncWithdraw(safe, withdrawal.recipient, withdrawal.amount);
        delete withdrawals[safe];
    }

    /**
     * @dev Creates a digest hash for the async withdraw operation
     * @param _recipient Recipient address from Frax api
     * @param _withdrawAmount Amount to withdraw asynchronously
     * @return The digest hash for signature verification
     */
    function _getRequestAsyncWithdrawDigestHash(address safe, address _recipient, uint256 _withdrawAmount) internal returns (bytes32) {
        return keccak256(abi.encodePacked(REQUEST_ASYNC_WITHDRAW_SIG, block.chainid, address(this), _useNonce(safe), safe, abi.encode(fraxusd, _recipient, _withdrawAmount))).toEthSignedMessageHash();
    }

    /**
     * @notice Function to request an async withdrawal
     * @param safe Address for user safe
     * @param _recipient Recipient address from Frax api
     * @param _withdrawAmount Amount to withdraw asynchronously
     * @custom:throws InvalidInput If the amount is zero
     */
    function _requestAsyncWithdraw(address safe, address _recipient, uint256 _withdrawAmount) internal {
        if (_withdrawAmount == 0 || _recipient == address(0)) revert InvalidInput();

        cashModule.requestWithdrawalByModule(safe, fraxusd, _withdrawAmount);

        emit AsyncWithdrawalRequested(safe, _withdrawAmount, ETHEREUM_EID, _recipient);

        (uint64 withdrawalDelay,,) = cashModule.getDelays();
        if (withdrawalDelay == 0) {
            _asyncWithdraw(safe, _recipient, _withdrawAmount);
        } else {
            withdrawals[safe] = AsyncWithdrawal({ amount: _withdrawAmount, recipient: _recipient });
        }
    }

    /**
     * @notice Internal function to execute an async withdrawal
     * @param safe The Safe address that requested the withdrawal
     * @param _recipient Recipient address from Frax api
     * @param _amount Amount to withdraw asynchronously
     */
    function _asyncWithdraw(address safe, address _recipient, uint256 _amount) internal {
        if (_amount == 0) revert InvalidInput();

        bytes32 _to = bytes32(bytes20(_recipient));

        MessagingFee memory fee = IFraxRemoteHop(remoteHop).quote(fraxusd, ETHEREUM_EID, _to, _amount);
        uint256 nativeFee = fee.nativeFee;

        if (address(this).balance < nativeFee) revert InsufficientNativeFee();

        ERC20(fraxusd).approve(remoteHop, _amount);
        IFraxRemoteHop(remoteHop).sendOFT{ value: nativeFee }(fraxusd, ETHEREUM_EID, _to, _amount);

        emit AsyncWithdrawalExecuted(safe, _amount, ETHEREUM_EID, _recipient);
    }
}
