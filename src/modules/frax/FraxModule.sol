// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IBridgeModule } from "../../interfaces/IBridgeModule.sol";
import { SafeData, WithdrawalRequest } from "../../interfaces/ICashModule.sol";
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
contract FraxModule is ModuleBase, ModuleCheckBalance, ReentrancyGuardTransient, IBridgeModule {
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

    /// @notice Address of the Frax USD token
    address public immutable fraxusd;

    /// @notice Address of Frax USD Custodian
    address public immutable custodian;

    /// @notice Address of the Frax USD Remote Hop contract
    address public immutable remoteHop;

    /// @notice Layerzero ethereum EID
    uint32 public constant ETHEREUM_EID = 30_101;

    /// @notice Dust threshold for LayerZero OFT decimal conversion (1e12)
    /// @dev Amounts must be multiples of this value to avoid dust being locked
    uint256 public constant DUST_THRESHOLD = 1e12;

    /// @notice TypeHash for deposit function signature
    bytes32 public constant DEPOSIT_SIG = keccak256("deposit");

    /// @notice TypeHash for withdraw function signature
    bytes32 public constant WITHDRAW_SIG = keccak256("withdraw");

    /// @notice TypeHash for async withdraw function signature
    bytes32 public constant REQUEST_ASYNC_WITHDRAW_SIG = keccak256("requestAsyncWithdraw");

    /// @notice TypeHash for cancel async withdraw function signature
    bytes32 public constant CANCEL_ASYNC_WITHDRAW_SIG = keccak256("cancelAsyncWithdraw");

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

    /// @notice Thrown when a caller lacks the proper authorization for an operation
    error Unauthorized();

    /// @notice Error for Invalid Owner quorum signatures
    error InvalidSignatures();

    /// @notice Error thrown when withdrawal amount contains dust (not a multiple of DUST_THRESHOLD)
    error AmountContainsDust();

    /// @notice Error thrown when custodian has insufficient balance for synchronous deposit
    error InsufficientCustodianBalance();

    /// @notice Emitted when safe deposits USDC into Frax USD
    event Deposit(address indexed safe, address indexed inputToken, uint256 inputAmount, uint256 outputAmount);

    /// @notice Emitted when safe withdraws USDC from Frax USD (Synchronously)
    event Withdrawal(address indexed safe, address indexed outputToken, uint256 amountToWithdraw, uint256 amountOut);

    /// @notice Emitted when safe creates an async withdrawal Request from FraxUSD
    event AsyncWithdrawalRequested(address indexed safe, uint256 amountToWithdraw, uint32 dstEid, address to);

    /// @notice Emitted when safe executes an async withdrawal from FraxUSD
    event AsyncWithdrawalExecuted(address indexed safe, uint256 amountToWithdraw, uint32 dstEid, address to);

    /// @notice Emitted when an async withdrawal request is cancelled
    event AsyncWithdrawalCancelled(address indexed safe, uint256 amountToWithdraw, uint32 dstEid, address to);

    /**
     * @notice Contract constructor
     * @param _etherFiDataProvider Address of the EtherFiDataProvider contract
     * @param _fraxusd Address of the FRAXUSD token
     * @param _custodian Address of the FraxUSD custodian
     * @param _remoteHop Remote Hop address of FraxUSD
     * @dev Initializes the contract with supported tokens
     * @custom:throws InvalidInput If any provided address is zero
     */
    constructor(address _etherFiDataProvider, address _fraxusd, address _custodian, address _remoteHop) ModuleBase(_etherFiDataProvider) ModuleCheckBalance(_etherFiDataProvider) {
        if (_etherFiDataProvider == address(0) || _fraxusd == address(0) || _custodian == address(0) || _remoteHop == address(0)) revert InvalidInput();

        fraxusd = _fraxusd;
        custodian = _custodian;
        remoteHop = _remoteHop;
    }

    /**
     * @notice Deposits Asset and mints FraxUSD using signature verification
     * @param safe The Safe address which holds the asset tokens
     * @param assetToDeposit The address of the asset to deposit
     * @param amountToDeposit The amount of asset tokens to deposit
     * @param minReturnAmount The minimum amount of asset to return (18 decimals - FraxUSD)
     * @param signer The address that signed the transaction
     * @param signature The signature authorizing the transaction
     * @dev Verifies signature then executes token approval and deposit through the Safe's module execution
     * @custom:throws InvalidInput If amount is zero
     * @custom:throws InvalidSignature If the signature is invalid
     */
    function deposit(address safe, address assetToDeposit, uint256 amountToDeposit, uint256 minReturnAmount, address signer, bytes calldata signature) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = _getDepositDigestHash(safe, assetToDeposit, amountToDeposit, minReturnAmount);
        _verifyAdminSig(digestHash, signer, signature);
        _deposit(safe, assetToDeposit, amountToDeposit, minReturnAmount);
    }

    /**
     * @dev Creates a digest hash for the deposit operation
     * @param safe The Safe address which holds the deposit tokens
     * @param amountToDeposit The amount to deposit
     * @param minReturnAmount The minimum amount of asset to return (18 decimals - FraxUSD)
     * @return The digest hash for signature verification
     */
    function _getDepositDigestHash(address safe, address assetToDeposit, uint256 amountToDeposit, uint256 minReturnAmount) internal returns (bytes32) {
        return keccak256(abi.encodePacked(DEPOSIT_SIG, block.chainid, address(this), _useNonce(safe), safe, abi.encode(assetToDeposit, amountToDeposit, minReturnAmount))).toEthSignedMessageHash();
    }

    /**
     * @dev Internal function to deposit Asset tokens to FraxUSD custodian
     * @param safe The Safe address which holds the asset tokens
     * @param assetToDeposit The address of the asset to deposit
     * @param amountToDeposit The amount of asset tokens to deposit
     * @param minReturnAmount The minimum amount of asset to return (18 decimals - FraxUSD)
     * @custom:throws InvalidInput If amount or min return is zero
     * @custom:throws InsufficientCustodianBalance If custodian doesn't have enough balance for synchronous deposit
     * @custom:throws InsufficientReturnAmount If the FraxUSD received is less than expected
     */
    function _deposit(address safe, address assetToDeposit, uint256 amountToDeposit, uint256 minReturnAmount) internal {
        if (amountToDeposit == 0 || assetToDeposit == address(0)) revert InvalidInput();

        _checkAmountAvailable(safe, assetToDeposit, amountToDeposit);

        // Validate that custodian has sufficient balance for synchronous deposit
        // The custodian needs at least minReturnAmount of fraxusd tokens to fulfill the deposit synchronously
        // If it doesn't have enough, it will attempt a cross-chain mint which requires native fees and is async
        uint256 custodianBalance = ERC20(fraxusd).balanceOf(custodian);
        if (custodianBalance < minReturnAmount) revert InsufficientCustodianBalance();

        address[] memory to = new address[](2);
        bytes[] memory data = new bytes[](2);
        uint256[] memory values = new uint256[](2);

        to[0] = assetToDeposit;
        data[0] = abi.encodeWithSelector(ERC20.approve.selector, address(custodian), amountToDeposit);

        to[1] = address(custodian);
        data[1] = abi.encodeWithSelector(IFraxCustodian.deposit.selector, amountToDeposit, safe);

        uint256 fraxUSDTokenBefore = ERC20(fraxusd).balanceOf(safe);

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        uint256 fraxUSDTokenReceived = ERC20(fraxusd).balanceOf(safe) - fraxUSDTokenBefore;

        if (fraxUSDTokenReceived < minReturnAmount) revert InsufficientReturnAmount();

        emit Deposit(safe, assetToDeposit, amountToDeposit, fraxUSDTokenReceived);
    }

    /**
     * @notice Withdraws from FraxUSD from the safe
     * @param safe The Safe address which holds the FraxUSD tokens
     * @param amountToWithdraw The amount of FraxUSD to withdraw (18 decimals)
     * @param outputAsset The asset withdrawing to
     * @param minReceiveAmount The minimum amount of asset to receive
     * @param signer The address that signed the transaction
     * @param signature The signature authorizing the transaction
     * @dev Verifies signature then executes token approval and deposit through the Safe's module execution
     * @custom:throws InvalidInput If amount or min return is zero
     * @custom:throws InvalidSignature If the signature is invalid
     */
    function withdraw(address safe, uint128 amountToWithdraw, address outputAsset, uint256 minReceiveAmount, address signer, bytes calldata signature) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = _getWithdrawDigestHash(safe, amountToWithdraw, outputAsset, minReceiveAmount);
        _verifyAdminSig(digestHash, signer, signature);
        _withdraw(safe, amountToWithdraw, outputAsset, minReceiveAmount);
    }

    /**
     * @dev Creates a digest hash for the withdraw operation
     * @param safe The Safe address which holds the FraxUSD tokens
     * @param amountToWithdraw The amount to withdraw
     * @param outputAsset The asset withdrawing to
     * @param minReceiveAmount The minimum amount of asset to receive
     * @return The digest hash for signature verification
     */
    function _getWithdrawDigestHash(address safe, uint128 amountToWithdraw, address outputAsset, uint256 minReceiveAmount) internal returns (bytes32) {
        return keccak256(abi.encodePacked(WITHDRAW_SIG, block.chainid, address(this), _useNonce(safe), safe, abi.encode(amountToWithdraw, outputAsset, minReceiveAmount))).toEthSignedMessageHash();
    }

    /**
     * @notice Internal function which facilitates withdrawals from the safe
     * @param safe The Safe address which holds the FraxUSD tokens
     * @param amountToWithdraw The amount of FraxuSD tokens to withdraw
     * @param outputAsset The asset withdrawing to
     * @param minReceiveAmount The minimum amount of asset to receive (Decimal of Asset)
     * @custom:throws InvalidInput If the Safe doesn't have enough liquid asset balance
     * @custom:throws InvalidSignature If the signature is invalid
     * @custom:throws InsufficientReturnAmount If the USDC received is less than expected
     */
    function _withdraw(address safe, uint128 amountToWithdraw, address outputAsset, uint256 minReceiveAmount) internal {
        if (amountToWithdraw == 0 || outputAsset == address(0)) revert InvalidInput();

        _checkAmountAvailable(safe, fraxusd, amountToWithdraw);

        address[] memory to = new address[](2);
        bytes[] memory data = new bytes[](2);
        uint256[] memory values = new uint256[](2);

        to[0] = fraxusd;
        data[0] = abi.encodeWithSelector(ERC20.approve.selector, custodian, amountToWithdraw);

        to[1] = address(custodian);
        data[1] = abi.encodeWithSelector(IFraxCustodian.redeem.selector, amountToWithdraw, safe, safe);

        uint256 assetBefore = ERC20(outputAsset).balanceOf(safe);

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        uint256 assetReceived = ERC20(outputAsset).balanceOf(safe) - assetBefore;

        if (assetReceived < minReceiveAmount) revert InsufficientReturnAmount();

        emit Withdrawal(safe, outputAsset, amountToWithdraw, assetReceived);
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
        bytes32 _to = bytes32(uint256(uint160(_recipient)));
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
     * @notice Cancels an async withdrawal request for a safe
     * @param safe Address of the EtherFiSafe
     * @param signers Array of addresses of safe owners that signed the transaction
     * @param signatures Array of signatures from the signers
     */
    function cancelAsyncWithdraw(address safe, address[] calldata signers, bytes[] calldata signatures) external nonReentrant onlyEtherFiSafe(safe) {
        _checkCancelAsyncWithdrawSignature(safe, signers, signatures);

        AsyncWithdrawal memory withdrawal = withdrawals[safe];
        if (withdrawal.recipient == address(0)) revert NoAsyncWithdrawalQueued();

        SafeData memory data = cashModule.getData(safe);
        // If there is a withdrawal pending from this module on Cash Module, cancel it
        if (data.pendingWithdrawalRequest.recipient == address(this)) cashModule.cancelWithdrawalByModule(safe);

        if (withdrawal.recipient != address(0)) {
            emit AsyncWithdrawalCancelled(safe, withdrawal.amount, ETHEREUM_EID, withdrawal.recipient);
            delete withdrawals[safe];
        }
    }

    /**
     * @notice Cancels an async withdrawal request by the cash module
     * @dev This function is intended to be called by the cash module to cancel an async withdrawal
     * @param safe Address of the EtherFiSafe
     */
    function cancelBridgeByCashModule(address safe) external {
        if (msg.sender != etherFiDataProvider.getCashModule()) revert Unauthorized();

        AsyncWithdrawal memory withdrawal = withdrawals[safe];
        // Return if no withdrawal found for Frax
        if (withdrawal.recipient == address(0)) return;

        emit AsyncWithdrawalCancelled(safe, withdrawal.amount, ETHEREUM_EID, withdrawal.recipient);
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
     * @dev Verifies that the transaction has been properly signed by the required signers
     * @param safe Address of the EtherFiSafe
     * @param signers Array of addresses that signed the transaction
     * @param signatures Array of signatures from the signers
     * @custom:throws InvalidSignatures if the signatures are invalid
     */
    function _checkCancelAsyncWithdrawSignature(address safe, address[] calldata signers, bytes[] calldata signatures) internal {
        bytes32 digestHash = keccak256(abi.encodePacked(CANCEL_ASYNC_WITHDRAW_SIG, block.chainid, address(this), IEtherFiSafe(safe).useNonce(), safe)).toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
    }

    /**
     * @notice Function to request an async withdrawal
     * @param safe Address for user safe
     * @param _recipient Recipient address from Frax api
     * @param _withdrawAmount Amount to withdraw asynchronously
     * @custom:throws InvalidInput If the amount is zero or recipient is zero
     * @custom:throws AmountContainsDust If the amount is not a multiple of DUST_THRESHOLD
     */
    function _requestAsyncWithdraw(address safe, address _recipient, uint256 _withdrawAmount) internal {
        if (_withdrawAmount == 0 || _recipient == address(0)) revert InvalidInput();
        if (_withdrawAmount % DUST_THRESHOLD != 0) revert AmountContainsDust();

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

        bytes32 _to = bytes32(uint256(uint160(_recipient)));

        MessagingFee memory fee = IFraxRemoteHop(remoteHop).quote(fraxusd, ETHEREUM_EID, _to, _amount);
        uint256 nativeFee = fee.nativeFee;

        if (address(this).balance < nativeFee) revert InsufficientNativeFee();

        ERC20(fraxusd).approve(remoteHop, _amount);
        IFraxRemoteHop(remoteHop).sendOFT{ value: nativeFee }(fraxusd, ETHEREUM_EID, _to, _amount);

        emit AsyncWithdrawalExecuted(safe, _amount, ETHEREUM_EID, _recipient);
    }
}
