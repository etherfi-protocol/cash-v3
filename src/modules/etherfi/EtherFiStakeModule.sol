// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ModuleBase } from "../ModuleBase.sol";
import { IL2SyncPool } from "../../../src/interfaces/IL2SyncPool.sol";
import { IWETH } from "../../interfaces/IWETH.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";

/**
 * @title EtherFiStakeModule
 * @author ether.fi
 * @notice Module for staking ETH and WETH through the EtherFi protocol
 * @dev Extends ModuleBase to provide staking functionality for Safes
 */
contract EtherFiStakeModule is ModuleBase {
    using MessageHashUtils for bytes32;

    /// @notice Reference to the L2SyncPool contract for staking operations
    IL2SyncPool public immutable syncPool;
    
    /// @notice Address of the wrapped ETH contract
    address public immutable weth;
    
    /// @notice Address of the weETH (wrapped eETH) contract received upon staking
    address public immutable weETH;

    /// @notice TypeHash for deposit function signature 
    bytes32 public constant DEPOSIT_SIG = keccak256("deposit");

    event StakeDeposit(address indexed safe, address indexed inputAsset, address indexed outputAsset, uint256 inputAmount, uint256 outputAmount);

    /// @notice Thrown when an unsupported asset is provided for staking
    error UnsupportedAsset();
    
    /// @notice Thrown when the amount of weETH returned is less than the specified minimum
    error InsufficientReturnAmount();
    
    /// @notice Thrown when the Safe doesn't have sufficient balance for staking
    error InsufficientBalanceOnSafe();

    /**
     * @notice Contract constructor
     * @param _dataProvider Address of the EtherFiDataProvider contract
     * @param _syncPool Address of the L2SyncPool contract
     * @param _weth Address of the wrapped ETH contract
     * @param _weETH Address of the weETH contract
     * @dev Initializes the contract with required contract references
     */
    constructor(address _dataProvider, address _syncPool, address _weth, address _weETH) ModuleBase(_dataProvider) {
        syncPool = IL2SyncPool(_syncPool);
        weth = _weth;
        weETH = _weETH;
    }

    /**
     * @notice Deposits ETH or WETH for staking using signature verification
     * @param safe The Safe address which holds the tokens
     * @param assetToDeposit The address of the asset to deposit (ETH or WETH)
     * @param amountToDeposit The amount of tokens to deposit
     * @param minReturn The minimum amount of weETH to receive
     * @param signer The address that signed the transaction
     * @param signature The signature authorizing the transaction
     * @dev Verifies signature then executes the staking operation through the Safe's module execution
     * @custom:throws UnsupportedAsset If the asset is not ETH or WETH
     * @custom:throws InvalidInput If amountToDeposit or minReturn is zero
     * @custom:throws InsufficientBalanceOnSafe If the Safe doesn't have enough tokens
     * @custom:throws InsufficientReturnAmount If the received weETH is less than minReturn
     * @custom:throws OnlyEtherFiSafe If the calling safe is not a valid EtherFiSafe
     * @custom:throws OnlySafeAdmin If signer is not an admin of the Safe
     * @custom:throws InvalidSignature If the signature is invalid
     */
    function deposit(address safe, address assetToDeposit, uint256 amountToDeposit, uint256 minReturn, address signer, bytes calldata signature) external onlyEtherFiSafe(safe) onlySafeAdmin(safe, signer) {
        bytes32 digestHash = _getDepositDigestHash(safe, assetToDeposit, amountToDeposit, minReturn);
        _verifyAdminSig(digestHash, signer, signature);
        _deposit(safe, assetToDeposit, amountToDeposit, minReturn);
    }

    /**
     * @dev Creates a digest hash for the deposit operation
     * @param safe The Safe address which holds the tokens
     * @param assetToDeposit The address of the asset to deposit
     * @param amountToDeposit The amount to deposit
     * @param minReturn The minimum amount of weETH to receive
     * @return The EIP-712 compatible digest hash for signature verification
     */
    function _getDepositDigestHash(address safe, address assetToDeposit, uint256 amountToDeposit, uint256 minReturn) internal returns (bytes32) {
        return keccak256(abi.encodePacked(DEPOSIT_SIG, block.chainid, address(this), _useNonce(safe), safe, abi.encode(assetToDeposit, amountToDeposit, minReturn))).toEthSignedMessageHash();
    } 

    /**
     * @dev Internal function to deposit assets for staking
     * @param safe The Safe address which holds the tokens
     * @param assetToDeposit The address of the asset to deposit (ETH or WETH)
     * @param amountToDeposit The amount of tokens to deposit
     * @param minReturn The minimum amount of weETH to receive
     * @custom:throws UnsupportedAsset If the asset is not ETH or WETH
     * @custom:throws InvalidInput If amountToDeposit or minReturn is zero
     * @custom:throws InsufficientBalanceOnSafe If the Safe doesn't have enough tokens
     * @custom:throws InsufficientReturnAmount If the received weETH is less than minReturn
     */
    function _deposit(address safe, address assetToDeposit, uint256 amountToDeposit, uint256 minReturn) internal {
        if (assetToDeposit != weth && assetToDeposit != ETH) revert UnsupportedAsset();
        if (amountToDeposit == 0 || minReturn == 0) revert InvalidInput();

        uint256 bal;
        if (assetToDeposit == ETH) bal = safe.balance;        
        else bal = IERC20(assetToDeposit).balanceOf(safe);

        if (bal < amountToDeposit) revert InsufficientBalanceOnSafe();

        address[] memory to;
        bytes[] memory data;
        uint256[] memory values;

        if (assetToDeposit == weth) {
            to = new address[](2);
            data = new bytes[](2);
            values = new uint256[](2);

            to[0] = weth;
            data[0] = abi.encodeWithSelector(IWETH.withdraw.selector, amountToDeposit);

            to[1] = address(syncPool);
            values[1] = amountToDeposit;
            data[1] = abi.encodeWithSelector(IL2SyncPool.deposit.selector, ETH, amountToDeposit, minReturn);
        } else {
            to = new address[](1);
            data = new bytes[](1);
            values = new uint256[](1);

            to[0] = address(syncPool);
            values[0] = amountToDeposit;
            data[0] = abi.encodeWithSelector(IL2SyncPool.deposit.selector, ETH, amountToDeposit, minReturn);
        }

        uint256 weETHBalBefore = IERC20(weETH).balanceOf(safe);
        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
        uint256 weETHAmtReceived = IERC20(weETH).balanceOf(safe) - weETHBalBefore;

        if (weETHAmtReceived < minReturn) revert InsufficientReturnAmount();

        emit StakeDeposit(safe, assetToDeposit, weETH, amountToDeposit, weETHAmtReceived);
    }
}