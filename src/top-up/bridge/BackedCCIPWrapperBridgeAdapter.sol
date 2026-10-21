// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IBackedCCIPBridge } from "../../interfaces/IBackedCCIPBridge.sol";
import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";

/**
 * @title BackedCCIPWrapperBridgeAdapter
 * @notice Bridge adapter that redeems a Backed xStock wrapper (ERC-4626) for its raw stock and sends the raw
 *         stock over Backed's CCIP bridge. The raw stock arrives 1:1 on the destination as a plain transfer
 *         from Backed's custody there, where TopUpDest wraps it again.
 * @dev Delegatecalled by `TopUpFactory.bridge()`, so the wrapper shares and the native fee are the factory's.
 *      `additionalData` is `abi.encode(address bridge, uint64 destChainSelector)`. `maxSlippage` is unused:
 *      the redeem is at the vault rate and the bridge carries the exact amount.
 * @author ether.fi
 */
contract BackedCCIPWrapperBridgeAdapter is BridgeAdapterBase {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted when a wrapper is redeemed and the raw stock is sent over Backed's bridge.
     * @param wrapper The wrapper redeemed.
     * @param shares The wrapper shares redeemed.
     * @param token The raw stock token sent.
     * @param amount The raw amount sent.
     * @param destRecipient The recipient on the destination chain.
     * @param messageId The CCIP message id.
     */
    event BridgeBackedCCIPWrapper(address indexed wrapper, uint256 shares, address indexed token, uint256 amount, address indexed destRecipient, bytes32 messageId);

    /**
     * @notice Redeems the wrapper shares and sends the raw stock over Backed's bridge.
     * @param token The wrapper token.
     * @param amount The wrapper shares to redeem and send.
     * @param destRecipient The recipient address on the destination chain.
     * @param additionalData ABI-encoded (address bridge, uint64 destChainSelector).
     * @custom:throws InsufficientNativeFee if the balance can't cover the delivery fee.
     */
    function bridge(address token, uint256 amount, address destRecipient, uint256, bytes calldata additionalData) external payable override {
        (IBackedCCIPBridge ccipBridge, uint64 selector) = _decode(additionalData);
        bytes32 receiver = bytes32(uint256(uint160(destRecipient)));

        address raw = IERC4626(token).asset();
        uint256 rawAmount = IERC4626(token).redeem(amount, address(this), address(this));

        uint256 fee = ccipBridge.getDeliveryFeeCost(selector, receiver, raw, rawAmount, "");
        if (address(this).balance < fee) revert InsufficientNativeFee();

        // The bridge moves whole shares of the rebasing stock, so a sub-share remainder stays in the factory
        IERC20(raw).forceApprove(address(ccipBridge), rawAmount);
        bytes32 messageId = ccipBridge.send{ value: fee }(selector, receiver, raw, rawAmount, "");

        emit BridgeBackedCCIPWrapper(token, amount, raw, rawAmount, destRecipient, messageId);
    }

    /**
     * @notice The native fee for redeeming `amount` wrapper shares and sending the raw stock.
     * @param token The wrapper token.
     * @param amount The wrapper shares to redeem and send.
     * @param destRecipient The recipient address on the destination chain.
     * @param additionalData ABI-encoded (address bridge, uint64 destChainSelector).
     * @return ETH address and the required native fee amount.
     */
    function getBridgeFee(address token, uint256 amount, address destRecipient, uint256, bytes calldata additionalData) external view override returns (address, uint256) {
        (IBackedCCIPBridge ccipBridge, uint64 selector) = _decode(additionalData);
        uint256 rawAmount = IERC4626(token).previewRedeem(amount);
        return (ETH, ccipBridge.getDeliveryFeeCost(selector, bytes32(uint256(uint160(destRecipient))), IERC4626(token).asset(), rawAmount, ""));
    }

    /// @dev Unpacks the token config's (bridge, destination chain selector)
    function _decode(bytes calldata additionalData) internal pure returns (IBackedCCIPBridge, uint64) {
        (address ccipBridge, uint64 selector) = abi.decode(additionalData, (address, uint64));
        return (IBackedCCIPBridge(ccipBridge), selector);
    }
}
