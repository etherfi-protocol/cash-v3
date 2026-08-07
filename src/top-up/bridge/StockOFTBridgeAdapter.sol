// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

import { IOFT, MessagingFee, MessagingReceipt, OFTReceipt, SendParam } from "../../interfaces/IOFT.sol";
import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";

/**
 * @title StockOFTBridgeAdapter
 * @notice Bridge adapter that wraps a raw Backed stock token (e.g. SPYx) into its
 *         ERC-4626 wrapper (e.g. wSPYx) and OFT-sends the resulting shares through the
 *         wrapper's LayerZero OFTAdapter.
 * @dev Delegatecalled by `TopUpFactory.bridge()`, so deposited shares and approvals
 *      belong to the factory. `additionalData` is `abi.encode(address oftAdapter,
 *      uint32 destEid, uint128 lzReceiveGas)`. The wrapper is never configured: it is
 *      derived as `IOFT(oftAdapter).token()` and must satisfy
 *      `IERC4626(wrapper).asset() == token`, so a wrapper/OFT mismatch is unconfigurable.
 *
 *      Unlike `EtherFiOFTBridgeAdapter`, the send carries explicit executor lzReceive
 *      gas: the third-party Backed OFT adapters have no enforced SEND options, so empty
 *      options make the executor fee library revert with `Executor_NoOptions`.
 *
 *      Token configs for this adapter MUST use a small nonzero `maxSlippageInBps`:
 *      slippage applies to the wrapped shares, and its practical role is absorbing the
 *      OFT's shared-decimals dust truncation — at 0 bps any dust reverts the send.
 * @author ether.fi
 */
contract StockOFTBridgeAdapter is BridgeAdapterBase {
    using SafeERC20 for IERC20;
    using OptionsBuilder for bytes;

    /**
     * @notice Emitted when a stock is wrapped and its shares bridged through OFT.
     * @param token The raw stock token that was wrapped.
     * @param wrapper The ERC-4626 wrapper the stock was deposited into.
     * @param amount The raw stock amount deposited.
     * @param shares The wrapper shares minted and sent.
     * @param messageReceipt Receipt of the LayerZero message.
     * @param oftReceipt Receipt of the OFT operation.
     */
    event BridgeStockOFT(address indexed token, address indexed wrapper, uint256 amount, uint256 shares, MessagingReceipt messageReceipt, OFTReceipt oftReceipt);

    /// @notice Error thrown when the configured token is not the wrapper's underlying asset.
    error InvalidWrapperAsset();

    /**
     * @notice Wraps the stock into its ERC-4626 wrapper and bridges the shares via OFT.
     * @param token The raw stock token to wrap and bridge.
     * @param amount The raw stock amount.
     * @param destRecipient The recipient address on the destination chain.
     * @param maxSlippage Maximum allowed slippage in basis points, applied to the shares.
     * @param additionalData ABI-encoded (address oftAdapter, uint32 destEid, uint128 lzReceiveGas).
     * @custom:throws InvalidWrapperAsset if `token` is not the wrapper's underlying.
     * @custom:throws InsufficientNativeFee if the balance can't cover the messaging fee.
     * @custom:throws InsufficientMinAmount if the received amount is below minimum.
     */
    function bridge(address token, uint256 amount, address destRecipient, uint256 maxSlippage, bytes calldata additionalData) external payable override {
        (address oftAddr, address wrapper) = _resolveWrapper(token, additionalData);

        IERC20(token).forceApprove(wrapper, amount);
        uint256 shares = IERC4626(wrapper).deposit(amount, address(this));

        (MessagingReceipt memory messageReceipt, OFTReceipt memory oftReceipt) = _send(oftAddr, wrapper, _buildSendParam(destRecipient, shares, maxSlippage, additionalData));

        emit BridgeStockOFT(token, wrapper, amount, shares, messageReceipt, oftReceipt);
    }

    /**
     * @notice Calculates the native fee for wrapping + bridging.
     * @dev Uses `previewDeposit` to size the OFT send in shares.
     * @param token The raw stock token.
     * @param amount The raw stock amount.
     * @param destRecipient The recipient address on the destination chain.
     * @param maxSlippage Maximum allowed slippage in basis points, applied to the shares.
     * @param additionalData ABI-encoded (address oftAdapter, uint32 destEid, uint128 lzReceiveGas).
     * @return ETH address and the required native fee amount.
     * @custom:throws InvalidWrapperAsset if `token` is not the wrapper's underlying.
     */
    function getBridgeFee(address token, uint256 amount, address destRecipient, uint256 maxSlippage, bytes calldata additionalData) external view override returns (address, uint256) {
        (address oftAddr, address wrapper) = _resolveWrapper(token, additionalData);

        MessagingFee memory messagingFee = IOFT(oftAddr).quoteSend(_buildSendParam(destRecipient, IERC4626(wrapper).previewDeposit(amount), maxSlippage, additionalData), false);
        return (ETH, messagingFee.nativeFee);
    }

    /**
     * @dev Decodes the OFT adapter from `additionalData`, derives the wrapper it locks
     *      and checks `token` is the wrapper's underlying asset.
     * @custom:throws InvalidWrapperAsset if `token` is not the wrapper's underlying.
     */
    function _resolveWrapper(address token, bytes calldata additionalData) internal view returns (address oftAddr, address wrapper) {
        (oftAddr,,) = abi.decode(additionalData, (address, uint32, uint128));
        wrapper = IOFT(oftAddr).token();
        if (IERC4626(wrapper).asset() != token) revert InvalidWrapperAsset();
    }

    /**
     * @dev Builds the OFT SendParam for `shares` of the wrapper: slippage floor on the
     *      shares and explicit executor lzReceive gas (the Backed OFTs have no enforced
     *      SEND options), no compose, no oftCmd.
     */
    function _buildSendParam(address destRecipient, uint256 shares, uint256 maxSlippage, bytes calldata additionalData) internal pure returns (SendParam memory) {
        (, uint32 destEid, uint128 lzReceiveGas) = abi.decode(additionalData, (address, uint32, uint128));
        return SendParam({ dstEid: destEid, to: bytes32(uint256(uint160(destRecipient))), amountLD: shares, minAmountLD: deductSlippage(shares, maxSlippage), extraOptions: OptionsBuilder.newOptions().addExecutorLzReceiveOption(lzReceiveGas, 0), composeMsg: new bytes(0), oftCmd: new bytes(0) });
    }

    /**
     * @dev Quotes and executes the OFT send of `sendParam.amountLD` wrapper shares.
     * @custom:throws InsufficientNativeFee if the balance can't cover the messaging fee.
     * @custom:throws InsufficientMinAmount if the received amount is below minimum.
     */
    function _send(address oftAddr, address wrapper, SendParam memory sendParam) internal returns (MessagingReceipt memory messageReceipt, OFTReceipt memory oftReceipt) {
        MessagingFee memory messagingFee = IOFT(oftAddr).quoteSend(sendParam, false);
        if (address(this).balance < messagingFee.nativeFee) revert InsufficientNativeFee();

        if (IOFT(oftAddr).approvalRequired()) IERC20(wrapper).forceApprove(oftAddr, sendParam.amountLD);

        (messageReceipt, oftReceipt) = IOFT(oftAddr).send{ value: messagingFee.nativeFee }(sendParam, messagingFee, payable(address(this)));
        if (oftReceipt.amountReceivedLD < sendParam.minAmountLD) revert InsufficientMinAmount();
    }
}
