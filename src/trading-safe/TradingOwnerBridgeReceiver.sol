// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ITradingSafeBridgeReceiver } from "../interfaces/ITradingSafeBridgeReceiver.sol";
import { EtherFiSafe } from "../safe/EtherFiSafe.sol";

/**
 * @title TradingOwnerBridgeReceiver
 * @author ether.fi
 * @notice Bridge-applied owner mutations for a destination-chain safe. Sits between
 *         `EtherFiSafe` and `TradingSafe` and exposes the four `applyBridge*` functions
 *         that the on-chain `OwnershipBridgeReceiver` peer is permitted to invoke.
 * @dev Abstract — deployed only as part of `TradingSafe`. The `applyBridge*` functions skip
 *      signature verification because the source-chain safe has already verified its
 *      owners' intents and `BRIDGE_RECEIVER` is a trusted on-chain peer.
 */
abstract contract TradingOwnerBridgeReceiver is EtherFiSafe, ITradingSafeBridgeReceiver {
    /// @notice Address of the `OwnershipBridgeReceiver` which is permitted to call the `applyBridge*` functions on this safe.
    address public immutable BRIDGE_RECEIVER;

    /// @notice Reverts when an `applyBridge*` function is called by an address other than `BRIDGE_RECEIVER`.
    error OnlyBridgeReceiver();

    /**
     * @dev Restricts a function to be callable only by `BRIDGE_RECEIVER`.
     */
    modifier onlyBridgeReceiver() {
        if (msg.sender != BRIDGE_RECEIVER) revert OnlyBridgeReceiver();
        _;
    }

    /**
     * @param _dataProvider Address of the `EtherFiDataProvider` on this chain.
     * @param _bridgeReceiver Address of the `OwnershipBridgeReceiver` permitted to call
     *        `applyBridge*` functions on instances of this safe.
     */
    constructor(address _dataProvider, address _bridgeReceiver) payable EtherFiSafe(_dataProvider) {
        BRIDGE_RECEIVER = _bridgeReceiver;
    }

    /**
     * @notice Mirrors a `configureOwners` call from the source-chain safe. Adds and/or
     *         removes owners and updates the signature threshold.
     * @param owners Owners to add or remove.
     * @param shouldAdd Per-owner flag: `true` = add, `false` = remove.
     * @param threshold New signature threshold after the change.
     */
    function applyBridgeConfigureOwners(
        address[] calldata owners,
        bool[] calldata shouldAdd,
        uint8 threshold
    ) external override onlyBridgeReceiver {
        _configureOwners(owners, shouldAdd, threshold);
        _configureAdmin(owners, shouldAdd);
    }

    /**
     * @notice Mirrors a `setThreshold` call from the source-chain safe.
     * @param threshold New signature threshold.
     */
    function applyBridgeSetThreshold(uint8 threshold) external override onlyBridgeReceiver {
        _setThreshold(threshold);
    }

    /**
     * @notice Mirrors a `recoverSafe` call from the source-chain safe. Stages an incoming
     *         owner that becomes active at `incomingOwnerEffectiveAt`.
     * @param newOwner Owner queued to take over after the recovery timelock.
     * @param incomingOwnerEffectiveAt Timestamp (matching the source-chain timelock) at
     *        which `newOwner` becomes the active owner.
     */
    function applyBridgeRecover(address newOwner, uint256 incomingOwnerEffectiveAt) external override onlyBridgeReceiver {
        _setIncomingOwner(newOwner, incomingOwnerEffectiveAt);
    }

    /**
     * @notice Mirrors a `cancelRecovery` call from the source-chain safe. Clears any
     *         pending incoming owner.
     */
    function applyBridgeCancelRecovery() external override onlyBridgeReceiver {
        _removeIncomingOwner();
    }
}
