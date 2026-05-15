// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { IOwnershipBridgeSender } from "../interfaces/IOwnershipBridgeSender.sol";

/**
 * @title OwnerBridgePublisher
 * @author ether.fi
 * @notice Mixin used by owner-mutating safe functions to broadcast the change to
 *         destination chains via `OwnershipBridgeSender`. Quotes the LZ fee up-front and
 *         forwards only what's required; falls through cleanly (full refund, no LZ touch)
 *         when no bridge is wired up on this chain or when the safe hasn't enabled any
 *         destinations.
 * @dev Inherited by `EtherFiSafeBase`. Concrete safes implement `_getDataProvider`
 *      so this mixin doesn't have to duplicate the data-provider immutable that the safe
 *      already holds.
 */
abstract contract OwnerBridgePublisher {
    /// @notice Reverts when forwarding the caller's refund fails — typically because the
    ///         caller is a contract that rejects native value on `receive`. Surface
    ///         explicitly rather than silently swallowing the refund.
    error BridgeRefundFailed();

    /// @notice Reverts when the caller forwarded less native value than the LZ fee returned
    ///         by `OwnershipBridgeSender.quote*`. Tells the caller exactly how much short
    ///         they were so they can re-submit with the right amount.
    /// @param supplied The `msg.value` the safe received.
    /// @param required The total LZ fee quoted across the safe's enabled destinations.
    error InsufficientBridgeFee(uint256 supplied, uint256 required);

    /// @dev Returns the data provider.
    function _getDataProvider() internal view virtual returns (IEtherFiDataProvider);

    /**
     * @dev Publishes a `configureOwners` mutation. No-bridge / not-live → full refund.
     *      Otherwise quotes the LZ fee, forwards exactly that to the sender, and refunds
     *      any leftover (the sender may return unused fee if a per-destination quote
     *      shifted between our quote and dispatch).
     */
    function _publishConfigureOwners(address[] calldata owners, bool[] calldata shouldAdd, uint8 threshold) internal {
        IOwnershipBridgeSender sender = _resolveLiveBridgeSender();
        if (address(sender) == address(0)) return;
        uint256 fee = sender.quoteConfigureOwners(address(this), owners, shouldAdd, threshold);
        uint256 preCallBalance = _validateFeeAndSnapshot(fee);
        sender.publishConfigureOwners{ value: fee }(address(this), owners, shouldAdd, threshold);
        _refundLeftover(preCallBalance);
    }

    /// @dev See `_publishConfigureOwners`. Refund semantics are identical.
    function _publishSetThreshold(uint8 threshold) internal {
        IOwnershipBridgeSender sender = _resolveLiveBridgeSender();
        if (address(sender) == address(0)) return;
        uint256 fee = sender.quoteSetThreshold(address(this), threshold);
        uint256 preCallBalance = _validateFeeAndSnapshot(fee);
        sender.publishSetThreshold{ value: fee }(address(this), threshold);
        _refundLeftover(preCallBalance);
    }

    /// @dev Publishes a `recover`. The local timelock target is passed through so the
    ///      destination mirrors the same wall-clock activation moment.
    function _publishRecover(address newOwner, uint256 incomingOwnerEffectiveAt) internal {
        IOwnershipBridgeSender sender = _resolveLiveBridgeSender();
        if (address(sender) == address(0)) return;
        uint256 fee = sender.quoteRecover(address(this), newOwner, incomingOwnerEffectiveAt);
        uint256 preCallBalance = _validateFeeAndSnapshot(fee);
        sender.publishRecover{ value: fee }(address(this), newOwner, incomingOwnerEffectiveAt);
        _refundLeftover(preCallBalance);
    }

    /// @dev See `_publishConfigureOwners`. Refund semantics are identical.
    function _publishCancelRecovery() internal {
        IOwnershipBridgeSender sender = _resolveLiveBridgeSender();
        if (address(sender) == address(0)) return;
        uint256 fee = sender.quoteCancelRecovery(address(this));
        uint256 preCallBalance = _validateFeeAndSnapshot(fee);
        sender.publishCancelRecovery{ value: fee }(address(this));
        _refundLeftover(preCallBalance);
    }

    /**
     * @dev Resolves the live bridge sender for this safe, or refunds full and returns zero.
     *      A non-zero return means: a sender is configured on this chain AND
     *      `isPublishLive(this)` is true. On the zero-return path, `msg.value` has been
     *      refunded to the caller already, so callers must short-circuit and return.
     * @return sender The live bridge sender, or zero if bridging is not live.
     */
    function _resolveLiveBridgeSender() private returns (IOwnershipBridgeSender sender) {
        address senderAddr = _getDataProvider().getOwnershipBridgeSender();
        if (senderAddr != address(0)) {
            sender = IOwnershipBridgeSender(senderAddr);
            if (sender.isPublishLive(address(this))) return sender;
        }
        _refundFullValue();
        return IOwnershipBridgeSender(address(0));
    }

    /**
     * @dev Validates that `msg.value` covers `fee` and snapshots the pre-call balance for
     *      the leftover-refund step.
     * @param fee Fee quoted by the bridge sender for the upcoming publish.
     * @return preCallBalance `address(this).balance - msg.value` — the balance before the
     *         caller's forwarded `msg.value`.
     */
    function _validateFeeAndSnapshot(uint256 fee) private view returns (uint256 preCallBalance) {
        if (msg.value < fee) revert InsufficientBridgeFee(msg.value, fee);
        return address(this).balance - msg.value;
    }

    /**
     * @dev Returns the entire `msg.value` to the caller. Used on every skip path so users
     *      don't accidentally trap ETH on chains where bridging isn't live.
     */
    function _refundFullValue() private {
        if (msg.value == 0) return;
        (bool ok, ) = payable(msg.sender).call{ value: msg.value }("");
        if (!ok) revert BridgeRefundFailed();
    }

    /**
     * @dev Forwards anything above the captured pre-call balance back to the caller.
     *      Captures (msg.value - fee) on the happy path plus any extra refund the sender
     *      pushed back to us (e.g. a per-destination fee shrank between quote and dispatch).
     * @param preCallBalance Balance snapshot taken before forwarding `fee` to the sender —
     *        i.e. `address(this).balance - msg.value` measured at entry.
     */
    function _refundLeftover(uint256 preCallBalance) private {
        uint256 currentBalance = address(this).balance;
        if (currentBalance <= preCallBalance) return;
        uint256 leftover = currentBalance - preCallBalance;
        (bool ok, ) = payable(msg.sender).call{ value: leftover }("");
        if (!ok) revert BridgeRefundFailed();
    }
}
