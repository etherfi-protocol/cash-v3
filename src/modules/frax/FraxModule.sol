// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

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

    address public immutable usdc;
    address public immutable fraxusd;
    address public immutable custodian;
    address public immutable remoteHop;

    /// @notice Layerzero ethereum EID
    uint32 public constant ETHEREUM_EID = 30_101;

    /// @notice TypeHash for deposit function signature
    bytes32 public constant DEPOSIT_SIG = keccak256("deposit");

    /// @notice TypeHash for withdraw function signature
    bytes32 public constant WITHDRAW_SIG = keccak256("withdraw");

    /// @notice TypeHash for async withdraw function signature
    bytes32 public constant ASYNC_WITHDRAW_SIG = keccak256("asyncWithdraw");

    /// @notice Emitted when safe deposits into FraxUSD
    event Deposit(address indexed safe, address indexed inputToken, uint256 inputAmount, uint256 outputAmount);

    /// @notice Emitted when safe withdraws from FraxUSD
    event Withdrawal(address indexed safe, uint256 amountToWithdraw, uint256 amountOut);

    /// @notice Emitted when safe creates a async withdrawal from FraxUSD
    event AsyncWithdrawal(address indexed safe, uint256 amountToWithdraw);

    /// @notice Error when the return amount is less than min return
    error InsufficientReturnAmount();

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
     * @notice Function to quote bridging fee for async redemption
     * @param _to Deposit address from Frax api
     * @param _withdrawAmount Amount to redeem asynchronously
     * @return fee MessagingFee struct quoting fee for bridging
     */
    function quoteAsyncWithdraw(bytes32 _to, uint256 _withdrawAmount) external view returns (MessagingFee memory fee) {
        return IFraxRemoteHop(remoteHop).quote(fraxusd, ETHEREUM_EID, _to, _withdrawAmount);
    }

    /**
     * @notice Function to quote bridging fee for async redemption
     * @param safe Address for user safe
     * @param _to Deposit address from Frax api
     * @param _withdrawAmount Amount to redeem asynchronously
     * @param _nativeFee Value of native fee paid
     * @param signature The signature authorizing this transaction
     * @param signer The address that signed the transaction
     */
    function asyncWithdraw(address safe, bytes32 _to, uint256 _withdrawAmount, uint256 _nativeFee, address signer, bytes calldata signature) external payable onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = _getQuoteAsyncWithdrawDigestHash(safe, _to, _withdrawAmount);
        _verifyAdminSig(digestHash, signer, signature);
        _asyncWithdraw(safe, _to, _withdrawAmount, _nativeFee);
    }

    /**
     * @dev Creates a digest hash for the async withdraw operation
     * @param _to Deposit address from Frax api
     * @param _withdrawAmount Amount to redeem asynchronously
     * @return The digest hash for signature verification
     */
    function _getQuoteAsyncWithdrawDigestHash(address safe, bytes32 _to, uint256 _withdrawAmount) internal returns (bytes32) {
        return keccak256(abi.encodePacked(ASYNC_WITHDRAW_SIG, block.chainid, address(this), _useNonce(safe), safe, abi.encode(fraxusd, _to, _withdrawAmount))).toEthSignedMessageHash();
    }

    /**
     * @notice Function to quote bridging fee for async redemption
     * @param safe Address for user safe
     * @param _to Deposit address from Frax api
     * @param _withdrawAmount Amount to redeem asynchronously
     * @param _nativeFee Value of native fee paid
     */
    function _asyncWithdraw(address safe, bytes32 _to, uint256 _withdrawAmount, uint256 _nativeFee) internal {
        if (_withdrawAmount == 0) revert InvalidInput();

        _checkAmountAvailable(safe, fraxusd, _withdrawAmount);

        address[] memory to = new address[](2);
        bytes[] memory data = new bytes[](2);
        uint256[] memory values = new uint256[](2);

        to[0] = fraxusd;
        data[0] = abi.encodeWithSelector(ERC20.approve.selector, remoteHop, _withdrawAmount);

        to[1] = remoteHop;
        data[1] = abi.encodeWithSelector(IFraxRemoteHop.sendOFT.selector, fraxusd, ETHEREUM_EID, _to, _withdrawAmount);
        values[1] = _nativeFee;

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        emit AsyncWithdrawal(safe, _withdrawAmount);
    }
}
