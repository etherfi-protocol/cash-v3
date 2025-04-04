// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {OpenOceanSwapDescription, IOpenOceanCaller, IOpenOceanRouter} from "../../interfaces/IOpenOcean.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { ModuleBase } from "../ModuleBase.sol";

/**
 * @title OpenOceanSwapModule
 * @author ether.fi
 * @notice Module for executing token swaps through OpenOcean exchange
 * @dev Extends ModuleBase to integrate with the EtherFi ecosystem
 */
contract OpenOceanSwapModule is ModuleBase {
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

    /// @notice Thrown when trying to swap more tokens than available in the safe
    error InsufficientBalanceOnSafe();
    /// @notice Thrown when trying to swap a token for the same token
    error SwappingToSameAsset();
    /// @notice Thrown when swap returns less than the minimum expected amount
    error OutputLessThanMinAmount();
    /// @notice Error for Invalid Owner quorum signatures
    error InvalidSignatures();

    /**
     * @notice Initializes the OpenOceanSwapModule
     * @param _swapRouter Address of the OpenOcean swap router contract
     * @param _dataProvider Address of the EtherFi data provider contract
     */
    constructor(address _swapRouter, address _dataProvider) ModuleBase(_dataProvider) {
        swapRouter = _swapRouter;
    }

    /**
     * @notice Executes a token swap through OpenOcean
     * @param safe Address of the EtherFi safe to execute the swap from
     * @param fromAsset Address of the token being sold (or ETH address for native swaps)
     * @param toAsset Address of the token being purchased (or ETH address for native swaps)
     * @param fromAssetAmount Amount of the source token to swap
     * @param minToAssetAmount Minimum amount of the destination token to receive
     * @param guaranteedAmount Guaranteed amount as per OpenOcean's protocol
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
        uint256 guaranteedAmount, 
        bytes calldata data, 
        address[] calldata signers, 
        bytes[] calldata signatures
    ) external onlyEtherFiSafe(safe) {
        _checkSignatures(safe, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, data, signers, signatures);
        _swap(safe, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, data);
    }

    /**
     * @notice Checks if the owner signatures are valid
     * @param safe Address of the EtherFi safe to execute the swap from
     * @param fromAsset Address of the token being sold (or ETH address for native swaps)
     * @param toAsset Address of the token being purchased (or ETH address for native swaps)
     * @param fromAssetAmount Amount of the source token to swap
     * @param minToAssetAmount Minimum amount of the destination token to receive
     * @param guaranteedAmount Guaranteed amount as per OpenOcean's protocol
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
        uint256 guaranteedAmount, 
        bytes calldata data, 
        address[] calldata signers, 
        bytes[] calldata signatures
    ) internal {
        bytes32 digestHash = _createDigest(safe, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, data);
        if (!IEtherFiSafe(safe).checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
    }

    /**
     * @notice Creates a digest hash for signature verification
     * @param safe Address of the EtherFi safe
     * @param fromAsset Address of the source token
     * @param toAsset Address of the destination token
     * @param fromAssetAmount Amount of the source token
     * @param minToAssetAmount Minimum expected amount of destination token
     * @param guaranteedAmount Guaranteed amount as per OpenOcean
     * @param data Additional swap data
     * @return Digest hash for signature verification
     */
    function _createDigest(
        address safe,
        address fromAsset,
        address toAsset,
        uint256 fromAssetAmount,
        uint256 minToAssetAmount,
        uint256 guaranteedAmount,
        bytes calldata data
    ) internal returns(bytes32) {
        return keccak256(abi.encodePacked(
            SWAP_SIG, 
            block.chainid, 
            address(this), 
            IEtherFiSafe(safe).useNonce(), 
            safe, 
            abi.encode(fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, data)
        )).toEthSignedMessageHash();
    }

    /**
     * @notice Internal function to execute the token swap
     * @param safe Address of the EtherFi safe
     * @param fromAsset Address of the source token
     * @param toAsset Address of the destination token
     * @param fromAssetAmount Amount of the source token
     * @param minToAssetAmount Minimum expected amount of destination token
     * @param guaranteedAmount Guaranteed amount as per OpenOcean
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
        uint256 guaranteedAmount,
        bytes calldata data
    ) internal {
        if (fromAsset == toAsset) revert SwappingToSameAsset();
        if (minToAssetAmount == 0) revert InvalidInput();
        
        uint256 balBefore;
        if (toAsset == ETH) balBefore = address(safe).balance;
        else balBefore = IERC20(toAsset).balanceOf(safe);

        address[] memory to; 
        uint256[] memory value; 
        bytes[] memory callData;
        if (fromAsset == ETH) (to, value, callData) = _swapNative(safe, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, data);
        else (to, value, callData) = _swapERC20(safe, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, data);

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
     * @param safe Address of the EtherFi safe
     * @param fromAsset Address of the source ERC20 token
     * @param toAsset Address of the destination token
     * @param fromAssetAmount Amount of the source token
     * @param minToAssetAmount Minimum expected amount of destination token
     * @param guaranteedAmount Guaranteed amount as per OpenOcean
     * @param data Additional swap data
     * @return to Array of target addresses for transactions
     * @return value Array of ETH values for transactions
     * @return callData Array of calldata for transactions
     * @dev Creates both the approval and swap transactions
     * @custom:throws InsufficientBalanceOnSafe If safe doesn't have enough tokens
     */
    function _swapERC20(
        address safe,
        address fromAsset,
        address toAsset,
        uint256 fromAssetAmount,
        uint256 minToAssetAmount,
        uint256 guaranteedAmount,
        bytes calldata data
    ) internal view returns (address[] memory to, uint256[] memory value, bytes[] memory callData) { 
        if (IERC20(fromAsset).balanceOf(safe) < fromAssetAmount) revert InsufficientBalanceOnSafe();

        to = new address[](2);
        value = new uint256[](2);
        callData = new bytes[](2);

        to[0] = fromAsset;
        callData[0] = abi.encodeWithSelector(IERC20.approve.selector, swapRouter, fromAssetAmount);

        to[1] = swapRouter;
        callData[1] = _getSwapData(false, safe, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, data);
    }

    /**
     * @notice Prepares a native ETH swap transaction
     * @param safe Address of the EtherFi safe
     * @param fromAsset Address representing ETH (should be ETH address constant)
     * @param toAsset Address of the destination token
     * @param fromAssetAmount Amount of ETH to swap
     * @param minToAssetAmount Minimum expected amount of destination token
     * @param guaranteedAmount Guaranteed amount as per OpenOcean
     * @param data Additional swap data
     * @return to Array of target addresses for transactions
     * @return value Array of ETH values for transactions
     * @return callData Array of calldata for transactions
     * @dev Creates the swap transaction with ETH value
     * @custom:throws InsufficientBalanceOnSafe If safe doesn't have enough ETH
     */
    function _swapNative(
        address safe,
        address fromAsset,
        address toAsset,
        uint256 fromAssetAmount,
        uint256 minToAssetAmount,
        uint256 guaranteedAmount,
        bytes calldata data
    ) internal view returns (address[] memory to, uint256[] memory value, bytes[] memory callData) {
        if (address(safe).balance < fromAssetAmount) revert InsufficientBalanceOnSafe();

        to = new address[](1);
        value = new uint256[](1);
        callData = new bytes[](1);

        to[0] = swapRouter;
        value[0] = fromAssetAmount;
        callData[0] = _getSwapData(true, safe, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, data);
    }

    /**
     * @notice Generates the OpenOcean swap function call data
     * @param isNative Whether the swap involves native ETH
     * @param safe Address of the EtherFi safe
     * @param fromAsset Address of the source token
     * @param toAsset Address of the destination token
     * @param fromAssetAmount Amount of the source token
     * @param minToAssetAmount Minimum expected amount of destination token
     * @param guaranteedAmount Guaranteed amount as per OpenOcean
     * @param data Additional swap data
     * @return Encoded calldata for the OpenOcean swap function
     * @dev Decodes the provided data and constructs the OpenOcean swap description
     */
    function _getSwapData(
        bool isNative,
        address safe,
        address fromAsset,
        address toAsset,
        uint256 fromAssetAmount,
        uint256 minToAssetAmount,
        uint256 guaranteedAmount,
        bytes calldata data
    ) internal pure returns (bytes memory) {
        ( , address executor, IOpenOceanCaller.CallDescription[] memory calls) = abi.decode(data, (bytes4, address, IOpenOceanCaller.CallDescription[]));

        OpenOceanSwapDescription memory swapDesc = OpenOceanSwapDescription({
            srcToken: IERC20(fromAsset),
            dstToken: IERC20(toAsset),
            srcReceiver: payable(executor),
            dstReceiver: payable(safe),
            amount: fromAssetAmount,
            minReturnAmount: minToAssetAmount,
            guaranteedAmount: guaranteedAmount,
            flags: isNative ? 0 : 2,
            referrer: safe,
            permit: hex""
        });

        return abi.encodeWithSelector(IOpenOceanRouter.swap.selector, IOpenOceanCaller(executor), swapDesc, calls);
    }
}