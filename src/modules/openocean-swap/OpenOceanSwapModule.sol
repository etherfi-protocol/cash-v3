// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {OpenOceanSwapDescription, IOpenOceanCaller, IOpenOceanRouter} from "../../interfaces/IOpenOcean.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { ModuleBase } from "../ModuleBase.sol";
import { ModuleCheckBalance } from "../ModuleCheckBalance.sol";

/**
 * @title OpenOceanSwapModule
 * @author ether.fi
 * @notice Module for executing token swaps through OpenOcean exchange
 * @dev Extends ModuleBase to integrate with the EtherFi ecosystem
 */
contract OpenOceanSwapModule is ModuleBase, ModuleCheckBalance {
    using MessageHashUtils for bytes32;

    /// @notice OpenOcean router contract to give allowance to perform swaps
    address public immutable swapRouter;

    /// @notice TypeHash for swap function signature
    bytes32 public constant SWAP_SIG = keccak256("swap");

    /**
     * @notice Emitted when a swap is executed on a Safe
     * @param safe Address of the EtherFi safe to execute the swap from
     * @param fromAsset Address of the token being sold (or ETH address for native swaps)
     * @param toAsset Address of the token being purchased (or ETH address for native swaps)
     * @param fromAssetAmount Amount of the source token to swap
     * @param minToAssetAmount Min return amount
     * @param returnAmt Final return amount
     */
    event SwapOnOpenOcean(address indexed safe, address indexed fromAsset, address indexed toAsset, uint256 fromAssetAmount, uint256 minToAssetAmount, uint256 returnAmt);

    /// @notice Thrown when trying to swap a token for the same token
    error SwappingToSameAsset();
    /// @notice Thrown when swap returns less than the minimum expected amount
    error OutputLessThanMinAmount();
    /// @notice Error for Invalid Owner quorum signatures
    error InvalidSignatures();
    /// @notice Thrown when slippage from OpenOcean is too high
    error SlippageTooHigh();

    /**
     * @notice Initializes the OpenOceanSwapModule
     * @param _swapRouter Address of the OpenOcean swap router contract
     * @param _dataProvider Address of the EtherFi data provider contract
     */
    constructor(address _swapRouter, address _dataProvider) ModuleBase(_dataProvider) ModuleCheckBalance(_dataProvider) {
        swapRouter = _swapRouter;
    }

    /**
     * @notice Executes a token swap through OpenOcean
     * @param safe Address of the EtherFi safe to execute the swap from
     * @param fromAsset Address of the token being sold (or ETH address for native swaps)
     * @param toAsset Address of the token being purchased (or ETH address for native swaps)
     * @param fromAssetAmount Amount of the source token to swap
     * @param minToAssetAmount Minimum amount of the destination token to receive
     * @param data Additional data needed for the swap, encoded as (bytes4, address, CallDescription[])
     * @param signers Addresses of the safe owners authorizing this swap
     * @param signatures Signatures from the signers authorizing this transaction
     * @dev Can only be called by an EtherFi safe, and requires signature from a safe admin
     * @custom:throws InsufficientBalanceOnSafe If safe doesn't have enough source tokens 
     * @custom:throws SwappingToSameAsset If trying to swap a token for itself
     * @custom:throws OutputLessThanMinAmount If swap returns less than the specified minimum
     */
    function swap(
        address safe, 
        address fromAsset, 
        address toAsset, 
        uint256 fromAssetAmount, 
        uint256 minToAssetAmount, 
        bytes calldata data, 
        address[] calldata signers, 
        bytes[] calldata signatures
    ) external onlyEtherFiSafe(safe) {
        _checkSignatures(safe, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, data, signers, signatures);
        _swap(safe, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, data);
    }

    /**
     * @notice Checks if the owner signatures are valid
     * @param safe Address of the EtherFi safe to execute the swap from
     * @param fromAsset Address of the token being sold (or ETH address for native swaps)
     * @param toAsset Address of the token being purchased (or ETH address for native swaps)
     * @param fromAssetAmount Amount of the source token to swap
     * @param minToAssetAmount Minimum amount of the destination token to receive
     * @param data Additional data needed for the swap, encoded as (bytes4, address, CallDescription[])
     * @param signers Addresses of the safe owners authorizing this swap
     * @param signatures Signatures from the signers authorizing this transaction
     * @custom:throws InvalidSignatures if the signatures are invalid
     */
    function _checkSignatures(
        address safe, 
        address fromAsset, 
        address toAsset, 
        uint256 fromAssetAmount, 
        uint256 minToAssetAmount, 
        bytes calldata data, 
        address[] calldata signers, 
        bytes[] calldata signatures
    ) internal {
        bytes32 digestHash = _createDigest(safe, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, data);
        if (!IEtherFiSafe(safe).checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
    }

    /**
     * @notice Creates a digest hash for signature verification
     * @param safe Address of the EtherFi safe
     * @param fromAsset Address of the source token
     * @param toAsset Address of the destination token
     * @param fromAssetAmount Amount of the source token
     * @param minToAssetAmount Minimum expected amount of destination token
     * @param data Additional swap data
     * @return Digest hash for signature verification
     */
    function _createDigest(
        address safe,
        address fromAsset,
        address toAsset,
        uint256 fromAssetAmount,
        uint256 minToAssetAmount,
        bytes calldata data
    ) internal returns(bytes32) {
        return keccak256(abi.encodePacked(
            SWAP_SIG, 
            block.chainid, 
            address(this), 
            IEtherFiSafe(safe).useNonce(), 
            safe, 
            abi.encode(fromAsset, toAsset, fromAssetAmount, minToAssetAmount, data)
        )).toEthSignedMessageHash();
    }

    /**
     * @notice Internal function to execute the token swap
     * @param safe Address of the EtherFi safe
     * @param fromAsset Address of the source token
     * @param toAsset Address of the destination token
     * @param fromAssetAmount Amount of the source token
     * @param minToAssetAmount Minimum expected amount of destination token
     * @param data Additional swap data
     * @dev Handles the core swap logic and verification of received amounts
     * @custom:throws SwappingToSameAsset If trying to swap a token for itself
     * @custom:throws InvalidInput If minimum expected amount is 0
     * @custom:throws OutputLessThanMinAmount If swap returns less than expected
     */
    function _swap(
        address safe,
        address fromAsset,
        address toAsset,
        uint256 fromAssetAmount,
        uint256 minToAssetAmount,
        bytes calldata data
    ) internal {
        if (fromAsset == toAsset) revert SwappingToSameAsset();
        if (minToAssetAmount == 0) revert InvalidInput();
        
        _checkAmountAvailable(safe, fromAsset, fromAssetAmount);

        uint256 balBefore;
        if (toAsset == ETH) balBefore = address(safe).balance;
        else balBefore = IERC20(toAsset).balanceOf(safe);

        _validateSwapData(safe, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, data);

        address[] memory to; 
        uint256[] memory value; 
        bytes[] memory callData;
        if (fromAsset == ETH) (to, value, callData) = _swapNative(fromAssetAmount, data);
        else (to, value, callData) = _swapERC20(fromAsset, fromAssetAmount, data);

        IEtherFiSafe(safe).execTransactionFromModule(to, value, callData);

        uint256 balAfter;
        if (toAsset == ETH) balAfter = address(safe).balance;
        else balAfter = IERC20(toAsset).balanceOf(safe);

        uint256 receivedAmt = balAfter - balBefore;
        if (receivedAmt < minToAssetAmount) revert OutputLessThanMinAmount();

        emit SwapOnOpenOcean(safe, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, receivedAmt);
    }

    /**
     * @notice Prepares an ERC20 token swap transaction
     * @param fromAsset Address of the source ERC20 token
     * @param fromAssetAmount Amount of the source token
     * @param data Additional swap data
     * @return to Array of target addresses for transactions
     * @return value Array of ETH values for transactions
     * @return callData Array of calldata for transactions
     * @dev Creates both the approval and swap transactions
     */
    function _swapERC20(
        address fromAsset,
        uint256 fromAssetAmount,
        bytes calldata data
    ) internal view returns (address[] memory to, uint256[] memory value, bytes[] memory callData) { 
        to = new address[](3);
        value = new uint256[](3);
        callData = new bytes[](3);

        to[0] = fromAsset;
        callData[0] = abi.encodeWithSelector(IERC20.approve.selector, swapRouter, fromAssetAmount);

        to[1] = swapRouter;
        callData[1] = data;

        to[2] = fromAsset;
        callData[2] = abi.encodeWithSelector(IERC20.approve.selector, swapRouter, 0);
    }

    /**
     * @notice Prepares a native ETH swap transaction
     * @param fromAssetAmount Amount of ETH to swap
     * @param data Additional swap data
     * @return to Array of target addresses for transactions
     * @return value Array of ETH values for transactions
     * @return callData Array of calldata for transactions
     * @dev Creates the swap transaction with ETH value
     */
    function _swapNative(
        uint256 fromAssetAmount,
        bytes calldata data
    ) internal view returns (address[] memory to, uint256[] memory value, bytes[] memory callData) {
        to = new address[](1);
        value = new uint256[](1);
        callData = new bytes[](1);

        to[0] = swapRouter;
        value[0] = fromAssetAmount;
        callData[0] = data;
    }

    /**
     * @notice Validates the OpenOcean swap function call data
     * @param safe Address of the EtherFi safe
     * @param fromAsset Address of the source token
     * @param toAsset Address of the destination token
     * @param fromAssetAmount Amount of the source token
     * @param minToAssetAmount Minimum expected amount of destination token
     * @param data Additional swap data
     * @dev Decodes the provided data and constructs the OpenOcean swap description
     */
    function _validateSwapData(
        address safe,
        address fromAsset,
        address toAsset,
        uint256 fromAssetAmount,
        uint256 minToAssetAmount,
        bytes calldata data
    ) internal pure {
        (, OpenOceanSwapDescription memory swapDesc) = abi.decode(data[4:], (address, OpenOceanSwapDescription));

        if (
            swapDesc.srcToken != IERC20(fromAsset) ||
            swapDesc.dstToken != IERC20(toAsset) || 
            swapDesc.dstReceiver != payable(safe) || 
            swapDesc.amount != fromAssetAmount 
        ) revert InvalidInput();

        if (swapDesc.minReturnAmount < minToAssetAmount) revert SlippageTooHigh();
    }
}