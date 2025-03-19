// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { IAavePoolV3 } from "../../interfaces/IAavePoolV3.sol";
import { IAaveWrappedTokenGateway } from "../../interfaces/IAaveWrappedTokenGatewayV3.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { IWETH } from "../../interfaces/IWETH.sol";
import { ModuleBase } from "../ModuleBase.sol";

/**
 * @title AaveV3Module
 * @author ether.fi
 * @notice Module for interacting with Aave V3 Protocol from a Safe
 * @dev Extends ModuleBase to provide Aave V3 integration for Safes
 */
contract AaveV3Module is ModuleBase {
    using MessageHashUtils for bytes32;

    /// @notice Aave V3 Pool contract interface for lending/borrowing operations
    IAavePoolV3 public immutable aaveV3Pool;
    
    /// @notice Aave V3 Wrapped Token Gateway contract interface for ETH operations
    IAaveWrappedTokenGateway public immutable aaveWrappedTokenGateway;
    
    /// @notice Variable interest rate mode (2) used for Aave borrowing operations
    /// @dev Aave uses 1 for stable rate and 2 for variable rate
    uint256 public constant INTEREST_RATE_MODE = 2; 
    
    /// @notice TypeHash for supply function signature used in EIP-712 signatures
    bytes32 public constant SUPPLY_SIG = keccak256("supply");
    
    /// @notice TypeHash for borrow function signature used in EIP-712 signatures
    bytes32 public constant BORROW_SIG = keccak256("borrow");
    
    /// @notice TypeHash for withdraw function signature used in EIP-712 signatures
    bytes32 public constant WITHDRAW_SIG = keccak256("withdraw");
    
    /// @notice TypeHash for repay function signature used in EIP-712 signatures
    bytes32 public constant REPAY_SIG = keccak256("repay");

    /// @notice Thrown when the Safe doesn't have sufficient token balance for an operation
    error InsufficientBalanceOnSafe();

    /**
     * @notice Contract constructor
     * @param _aavePool Address of the Aave V3 Pool contract
     * @param _wrappedTokenGateway Address of the Aave V3 Wrapped Token Gateway
     * @param _etherFiDataProvider Address of the EtherFiDataProvider contract
     * @dev Initializes the contract with necessary Aave V3 protocol contracts
     * @custom:throws InvalidInput If any provided address is zero
     */
    constructor(address _aavePool, address _wrappedTokenGateway, address _etherFiDataProvider) ModuleBase(_etherFiDataProvider) {
        if (_aavePool == address(0) || _wrappedTokenGateway == address(0)) revert InvalidInput();
        aaveV3Pool = IAavePoolV3(_aavePool);
        aaveWrappedTokenGateway = IAaveWrappedTokenGateway(_wrappedTokenGateway);
    }

    /**
     * @notice Supply tokens to Aave V3 Pool using signature verification
     * @param safe The Safe address which holds the tokens
     * @param asset The address of the ERC20 token to be supplied (or ETH address for ETH)
     * @param amount The amount of tokens to be supplied
     * @param signer The address that signed the transaction
     * @param signature The signature authorizing the transaction
     * @dev Verifies signature then executes token approval and supply through the Safe's module execution
     * @custom:throws InsufficientBalanceOnSafe If the Safe doesn't have enough tokens
     * @custom:throws InvalidInput If amount is zero
     * @custom:throws OnlySafeAdmin If signer is not an admin of the Safe
     * @custom:throws InvalidSignature If the signature is invalid
     */
    function supply(address safe, address asset, uint256 amount, address signer, bytes calldata signature) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = keccak256(abi.encode(SUPPLY_SIG, block.chainid, address(this), _useNonce(safe), safe, asset, amount)).toEthSignedMessageHash();
        _verifyAdminSig(digestHash, signer, signature);
        _supply(safe, asset, amount);
    }

    /**
     * @notice Borrow tokens from Aave V3 Pool using signature verification
     * @param safe The Safe address which holds the collateral
     * @param asset The address of the ERC20 token to borrow (or ETH address for ETH)
     * @param amount The amount of tokens to borrow
     * @param signer The address that signed the transaction
     * @param signature The signature authorizing the transaction
     * @dev Verifies signature then executes borrowing through the Safe's module execution
     * @custom:throws InvalidInput If amount is zero
     * @custom:throws OnlySafeAdmin If signer is not an admin of the Safe
     * @custom:throws InvalidSignature If the signature is invalid
     */
    function borrow(address safe, address asset, uint256 amount, address signer, bytes calldata signature) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = keccak256(abi.encode(BORROW_SIG, block.chainid, address(this), _useNonce(safe), safe, asset, amount)).toEthSignedMessageHash();
        _verifyAdminSig(digestHash, signer, signature);
        _borrow(safe, asset, amount);
    }

    /**
     * @notice Withdraw tokens from Aave V3 Pool using signature verification
     * @param safe The Safe address which holds the aToken
     * @param asset The address of the asset to be withdrawn (or ETH address for ETH)
     * @param amount The amount of tokens to be withdrawn
     * @param signer The address that signed the transaction
     * @param signature The signature authorizing the transaction
     * @dev Verifies signature then executes withdrawal through the Safe's module execution
     * @custom:throws InvalidInput If amount is zero
     * @custom:throws OnlySafeAdmin If signer is not an admin of the Safe
     * @custom:throws InvalidSignature If the signature is invalid
     */
    function withdraw(address safe, address asset, uint256 amount, address signer, bytes calldata signature) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = keccak256(abi.encode(WITHDRAW_SIG, block.chainid, address(this), _useNonce(safe), safe, asset, amount)).toEthSignedMessageHash();
        _verifyAdminSig(digestHash, signer, signature);
        _withdraw(safe, asset, amount);
    }

    /**
     * @notice Repay debt on Aave V3 Pool using signature verification
     * @param safe The Safe address which holds the tokens to repay the debt
     * @param asset The address of the asset to be repaid (or ETH address for ETH)
     * @param amount The amount of tokens to be repaid
     * @param signer The address that signed the transaction
     * @param signature The signature authorizing the transaction
     * @dev Verifies signature then executes repayment through the Safe's module execution
     * @custom:throws InsufficientBalanceOnSafe If the Safe doesn't have enough tokens
     * @custom:throws InvalidInput If amount is zero
     * @custom:throws OnlySafeAdmin If signer is not an admin of the Safe
     * @custom:throws InvalidSignature If the signature is invalid
     */
    function repay(address safe, address asset, uint256 amount, address signer, bytes calldata signature) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = keccak256(abi.encode(REPAY_SIG, block.chainid, address(this), _useNonce(safe), safe, asset, amount)).toEthSignedMessageHash();
        _verifyAdminSig(digestHash, signer, signature);
        _repay(safe, asset, amount);
    }

    /**
     * @dev Internal function to supply assets to Aave V3
     * @param safe The Safe address which holds the tokens
     * @param asset The address of the token to be supplied (or ETH address for ETH)
     * @param amount The amount of tokens to be supplied
     * @custom:throws InvalidInput If amount is zero
     * @custom:throws InsufficientBalanceOnSafe If the Safe doesn't have enough tokens
     */
    function _supply(address safe, address asset, uint256 amount) internal {
        uint256 bal;

        if (amount == 0) revert InvalidInput();
        
        if (asset == ETH) bal = safe.balance;        
        else bal = IERC20(asset).balanceOf(safe);
        
        if (bal < amount) revert InsufficientBalanceOnSafe();

        address[] memory to;
        bytes[] memory data;
        uint256[] memory values;

        if (asset == ETH) {
            to = new address[](1);
            data = new bytes[](1);
            values = new uint256[](1);

            to[0] = address(aaveWrappedTokenGateway);
            data[0] = abi.encodeWithSelector(IAaveWrappedTokenGateway.depositETH.selector, address(aaveV3Pool), safe, 0);
            values[0] = amount;
        } else {
            to = new address[](2);
            data = new bytes[](2);
            values = new uint256[](2);

            to[0] = asset;
            data[0] = abi.encodeWithSelector(IERC20.approve.selector, address(aaveV3Pool), amount);
            
            to[1] = address(aaveV3Pool);
            data[1] = abi.encodeWithSelector(IAavePoolV3.supply.selector, asset, amount, safe, 0);
        }

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
    }

    /**
     * @dev Internal function to borrow assets from Aave V3
     * @param safe The Safe address which holds the collateral
     * @param asset The address of the token to borrow (or ETH address for ETH)
     * @param amount The amount of tokens to borrow
     * @custom:throws InvalidInput If amount is zero
     */
    function _borrow(address safe, address asset, uint256 amount) internal {
        if (amount == 0) revert InvalidInput();

        address[] memory to = new address[](1);
        bytes[] memory data = new bytes[](1);
        uint256[] memory values = new uint256[](1);

        if (asset == ETH) {
            to = new address[](2);
            data = new bytes[](2);
            values = new uint256[](2);

            address weth = aaveWrappedTokenGateway.getWETHAddress();
            to[0] = address(aaveV3Pool);
            data[0] = abi.encodeWithSelector(IAavePoolV3.borrow.selector, weth, amount, INTEREST_RATE_MODE, 0, safe);
            
            to[1] = address(weth);
            data[1] = abi.encodeWithSelector(IWETH.withdraw.selector, amount);
        } else {
            to = new address[](1);
            data = new bytes[](1);
            values = new uint256[](1);

            to[0] = address(aaveV3Pool);
            data[0] = abi.encodeWithSelector(IAavePoolV3.borrow.selector, asset, amount, INTEREST_RATE_MODE, 0, safe);
        }

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
    }

    /**
     * @dev Internal function to withdraw assets from Aave V3
     * @param safe The Safe address which holds the aToken
     * @param asset The address of the asset to be withdrawn (or ETH address for ETH)
     * @param amount The amount of tokens to be withdrawn
     * @custom:throws InvalidInput If amount is zero
     */
    function _withdraw(address safe, address asset, uint256 amount) internal {
        if (amount == 0) revert InvalidInput();

        address[] memory to;
        bytes[] memory data;
        uint256[] memory values;

        if (asset == ETH) {
            to = new address[](2);
            data = new bytes[](2);
            values = new uint256[](2);

            address weth = aaveWrappedTokenGateway.getWETHAddress();

            to[0] = address(aaveV3Pool);
            data[0] = abi.encodeWithSelector(IAavePoolV3.withdraw.selector, weth, amount, safe);

            to[1] = weth;
            data[1] = abi.encodeWithSelector(IWETH.withdraw.selector, amount);
        } else {
            to = new address[](1);
            data = new bytes[](1);
            values = new uint256[](1);

            to[0] = address(aaveV3Pool);
            data[0] = abi.encodeWithSelector(IAavePoolV3.withdraw.selector, asset, amount, safe);
        }

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
    }

    /**
     * @dev Internal function to repay debt on Aave V3
     * @param safe The Safe address which holds the tokens to repay the debt
     * @param asset The address of the asset to be repaid (or ETH address for ETH)
     * @param amount The amount of tokens to be repaid
     * @custom:throws InvalidInput If amount is zero
     * @custom:throws InsufficientBalanceOnSafe If the Safe doesn't have enough tokens
     */
    function _repay(address safe, address asset, uint256 amount) internal {
        if (amount == 0) revert InvalidInput();
        
        uint256 bal;
        
        if (asset == ETH) bal = safe.balance;        
        else bal = IERC20(asset).balanceOf(safe);
        
        if (bal < amount) revert InsufficientBalanceOnSafe();

        address[] memory to;
        bytes[] memory data;
        uint256[] memory values;

        if (asset == ETH) {
            to = new address[](1);
            data = new bytes[](1);
            values = new uint256[](1);

            to[0] = address(aaveWrappedTokenGateway);
            data[0] = abi.encodeWithSelector(IAaveWrappedTokenGateway.repayETH.selector, address(aaveV3Pool), amount, safe);
            values[0] = amount;
        } else {
            to = new address[](2);
            data = new bytes[](2);
            values = new uint256[](2);
            
            to[0] = asset;
            data[0] = abi.encodeWithSelector(IERC20.approve.selector, address(aaveV3Pool), amount);
            
            to[1] = address(aaveV3Pool);
            data[1] = abi.encodeWithSelector(IAavePoolV3.repay.selector, asset, amount, INTEREST_RATE_MODE, safe);
        }

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
    }
}