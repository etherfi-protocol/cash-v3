// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { IFraxCustodian } from "../../interfaces/IFraxCustodian.sol";
import { IRoleRegistry } from "../../interfaces/IRoleRegistry.sol";
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

    address public immutable fraxusd;

    address public immutable usdc;

    address public immutable custodian;

    /// @notice TypeHash for deposit function signature 
    bytes32 public constant DEPOSIT_SIG = keccak256("deposit");
    
    /// @notice TypeHash for withdraw function signature
    bytes32 public constant WITHDRAW_SIG = keccak256("withdraw");

    //Todo: check which role will be the admin for Frax Module
    /// @notice Role identifier for admins of the Liquid Module
    bytes32 public constant ETHERFI_LIQUID_MODULE_ADMIN = keccak256("ETHERFI_LIQUID_MODULE_ADMIN");

    /// @notice Emitted when safe deposits into Liquid
    event UsdcDeposit(address indexed safe, address indexed inputToken, address indexed outputToken, uint256 inputAmount, uint256 outputAmount);

    /// @notice Emitted when safe withdraws from Liquid
    event UsdcWithdrawal(address indexed safe, address indexed liquidAsset, uint256 amountToWithdraw, uint256 amountOut);

    /// @notice Error when the return amount is less than min return
    error InsufficientReturnAmount();

    /**
     * @notice Contract constructor
     * @param _fraxusd Address of the FRAXUSD token
     * @param _usdc Addresses of the USDC token
     * @param _etherFiDataProvider Address of the EtherFiDataProvider contract
     * @param _custodian Address of the FraxUSD custodian
     * @dev Initializes the contract with supported tokens
     * @custom:throws InvalidInput If any provided address is zero
     */
    constructor(address _fraxusd, address _usdc, address _etherFiDataProvider, address _custodian) ModuleBase(_etherFiDataProvider) ModuleCheckBalance(_etherFiDataProvider) {
        if (_etherFiDataProvider == address(0) || _fraxusd == address(0) || _usdc == address(0)) revert InvalidInput();

        fraxusd = _fraxusd;
        usdc = _usdc;
        custodian = _custodian;
    }

    /**
     * @notice Deposits USDC and mints FraxUSD using signature verification
     * @param safe The Safe address which holds the USDC tokens
     * @param amountToDeposit The amount of USDC tokens to deposit
     * @param signer The address that signed the transaction
     * @param signature The signature authorizing the transaction
     * @dev Verifies signature then executes token approval and deposit through the Safe's module execution
     * @custom:throws InvalidInput If amount is zero
     * @custom:throws InvalidSignature If the signature is invalid
     */
    function deposit(address safe, uint256 amountToDeposit, address signer, bytes calldata signature) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = _getDepositDigestHash(safe, amountToDeposit);
        _verifyAdminSig(digestHash, signer, signature);
        _deposit(safe, amountToDeposit);
    }

    /**
     * @dev Creates a digest hash for the deposit operation
     * @param safe The Safe address which holds the USDC tokens
     * @param amountToDeposit The amount to deposit
     * @return The digest hash for signature verification
     */
    function _getDepositDigestHash(address safe, uint256 amountToDeposit) internal returns (bytes32) {
        return keccak256(abi.encodePacked(DEPOSIT_SIG, block.chainid, address(this), _useNonce(safe), safe, abi.encode(amountToDeposit))).toEthSignedMessageHash();
    }

    /**
     * @dev Internal function to deposit USDC to FraxUSD custodian
     * @param safe The Safe address which holds the USDC tokens
     * @param amountToDeposit The amount of USDC tokens to deposit (6 decimals)
     * @custom:throws InvalidInput If amount or min return is zero
     * @custom:throws InsufficientReturnAmount If the FraxUSD received is less than expected
     */
    function _deposit(address safe, uint256 amountToDeposit) internal {
        
        if (amountToDeposit == 0) revert InvalidInput();
        
        _checkAmountAvailable(safe, usdc, amountToDeposit);

        address[] memory to;
        bytes[] memory data;
        uint256[] memory values;

            to = new address[](2);
            data = new bytes[](2);
            values = new uint256[](2);

            to[0] = usdc;
            data[0] = abi.encodeWithSelector(ERC20.approve.selector, address(custodian), amountToDeposit);
            
            to[1] = address(custodian);
            data[1] = abi.encodeWithSelector(IFraxCustodian.deposit.selector, amountToDeposit, safe);
        

        uint256 fraxUSDTokenBefore = ERC20(fraxusd).balanceOf(safe);

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
        
        uint256 fraxUSDTokenReceived = ERC20(fraxusd).balanceOf(safe) - fraxUSDTokenBefore;

        //scale for decimals difference between USDC (6) and FraxUSD (18)
        uint256 scaledAmountToDeposit = amountToDeposit * 10**12;
        if (fraxUSDTokenReceived < scaledAmountToDeposit) revert InsufficientReturnAmount();

        emit UsdcDeposit(safe, usdc, fraxusd, amountToDeposit, fraxUSDTokenReceived);
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
     * @notice Internal function which facilitates ithdrawals from the safe
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

        uint256 scaledUsdcTokenReceived = usdcTokenReceived * 10**12; //scale for decimals difference between USDC (6) and FraxUSD (18)
        if (scaledUsdcTokenReceived < amountToWithdraw) revert InsufficientReturnAmount();
        
        emit UsdcWithdrawal(safe, fraxusd, amountToWithdraw, scaledUsdcTokenReceived);
    }
}
