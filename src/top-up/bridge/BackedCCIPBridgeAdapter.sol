// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IBackedCCIPBridge } from "../../interfaces/IBackedCCIPBridge.sol";
import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";

/**
 * @title BackedCCIPBridgeAdapter
 * @notice Bridge adapter that sends a raw Backed xStock over Backed's CCIP bridge. The token arrives 1:1 on the
 *         destination as a plain transfer from Backed's custody there.
 * @dev Delegatecalled by `TopUpFactory.bridge()`, so the token and the native fee are the factory's.
 *      `additionalData` is `abi.encode(address bridge, uint64 destChainSelector)`. `maxSlippage` is unused:
 *      the bridge carries the exact amount.
 * @author ether.fi
 */
contract BackedCCIPBridgeAdapter is BridgeAdapterBase {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted when a raw stock is sent over Backed's bridge.
     * @param token The raw stock token sent.
     * @param amount The amount sent.
     * @param destRecipient The recipient on the destination chain.
     * @param messageId The CCIP message id.
     */
    event BridgeBackedCCIP(address indexed token, uint256 amount, address indexed destRecipient, bytes32 messageId);

    /**
     * @notice Sends the raw stock over Backed's bridge.
     * @param token The raw stock token.
     * @param amount The amount to send.
     * @param destRecipient The recipient address on the destination chain.
     * @param additionalData ABI-encoded (address bridge, uint64 destChainSelector).
     * @custom:throws InsufficientNativeFee if the balance can't cover the delivery fee.
     */
    function bridge(address token, uint256 amount, address destRecipient, uint256, bytes calldata additionalData) external payable override {
        (IBackedCCIPBridge ccipBridge, uint64 selector) = _decode(additionalData);
        bytes32 receiver = bytes32(uint256(uint160(destRecipient)));

        uint256 fee = ccipBridge.getDeliveryFeeCost(selector, receiver, token, amount, "");
        if (address(this).balance < fee) revert InsufficientNativeFee();

        // The bridge moves whole shares of the rebasing stock, so a sub-share remainder stays in the factory
        IERC20(token).forceApprove(address(ccipBridge), amount);
        bytes32 messageId = ccipBridge.send{ value: fee }(selector, receiver, token, amount, "");

        emit BridgeBackedCCIP(token, amount, destRecipient, messageId);
    }

    /**
     * @notice The native fee for sending `amount` of `token`.
     * @param token The raw stock token.
     * @param amount The amount to send.
     * @param destRecipient The recipient address on the destination chain.
     * @param additionalData ABI-encoded (address bridge, uint64 destChainSelector).
     * @return ETH address and the required native fee amount.
     */
    function getBridgeFee(address token, uint256 amount, address destRecipient, uint256, bytes calldata additionalData) external view override returns (address, uint256) {
        (IBackedCCIPBridge ccipBridge, uint64 selector) = _decode(additionalData);
        return (ETH, ccipBridge.getDeliveryFeeCost(selector, bytes32(uint256(uint160(destRecipient))), token, amount, ""));
    }

    /// @dev Unpacks the token config's (bridge, destination chain selector)
    function _decode(bytes calldata additionalData) internal pure returns (IBackedCCIPBridge, uint64) {
        (address ccipBridge, uint64 selector) = abi.decode(additionalData, (address, uint64));
        return (IBackedCCIPBridge(ccipBridge), selector);
    }
}
