// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { OAppReceiverUpgradeable, Origin } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppReceiverUpgradeable.sol";
import { OAppCoreUpgradeable } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppCoreUpgradeable.sol";

import { IOwnershipBridgeReceiver } from "../interfaces/IOwnershipBridgeReceiver.sol";
import { ITradingSafeBridgeReceiver } from "../interfaces/ITradingSafeBridgeReceiver.sol";
import { ITradingSafeFactory } from "../interfaces/ITradingSafeFactory.sol";
import { OwnershipBridgeMessageLib } from "../libraries/OwnershipBridgeMessageLib.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title OwnershipBridgeReceiver
 * @author ether.fi
 * @notice Destination-chain singleton. Receives owner-mutating envelopes from the
 *         source-chain `OwnershipBridgeSender` via LayerZero and applies them to the
 *         corresponding TradingSafe via the `ITradingSafeBridgeReceiver` interface.
 * @dev Holds a privileged role on every TradingSafe — TradingSafe gates its
 *      `applyBridge*` functions to this contract's address.
 *
 *      LayerZero v2's default ordered-delivery + GUID-based replay protection are relied on;
 *      no application-level nonce is tracked here. `srcEid` is checked as defence-in-depth
 *      against peer misconfiguration.
 *
 *      If a message arrives for a TradingSafe that hasn't been deployed yet, we emit
 *      `OwnershipApplyDeferred` and exit cleanly. The eventual lazy-deploy reads the current
 *      source-chain owner state, so the missed bridge update is a no-op in practice.
 */
contract OwnershipBridgeReceiver is IOwnershipBridgeReceiver, OAppReceiverUpgradeable, UpgradeableProxy {
    /// @notice Trusted source EID. Pinned at deploy.
    uint32 public immutable SOURCE_EID;
    /// @notice Mainnet TradingSafe factory used to resolve `sourceSafe → tradingSafe`.
    ITradingSafeFactory public immutable TRADING_SAFE_FACTORY;

    /**
     * @notice Deploys the receiver implementation.
     * @dev Disables initializers on the implementation; only the proxy is initialised.
     * @param _endpoint LayerZero v2 endpoint on this chain.
     * @param _sourceEid Trusted source-chain EID (e.g. OP). Messages from other EIDs revert.
     * @param _tradingSafeFactory Address of the destination-chain TradingSafe factory.
     */
    constructor(address _endpoint, uint32 _sourceEid, address _tradingSafeFactory) OAppCoreUpgradeable(_endpoint) {
        SOURCE_EID = _sourceEid;
        TRADING_SAFE_FACTORY = ITradingSafeFactory(_tradingSafeFactory);
        _disableInitializers();
    }

    /**
     * @notice Initialises the proxy.
     * @param _delegate Ownable owner + LZ delegate for the receiver.
     * @param _roleRegistry Address of the role registry for pause / upgrade authority.
     */
    function initialize(address _delegate, address _roleRegistry) external initializer {
        __Ownable_init(_delegate);
        __OAppCore_init(_delegate);
        __UpgradeableProxy_init(_roleRegistry);
    }

    /**
     * @dev Entry point for inbound LZ messages. Validates source EID, resolves the
     *      destination TradingSafe address, and either applies the operation or emits a
     *      deferred event if the safe isn't deployed yet.
     * @param _origin LZ origin metadata (source EID + sender + nonce).
     * @param _guid LZ message GUID for traceability.
     * @param _message Encoded envelope payload.
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal override whenNotPaused {
        if (_origin.srcEid != SOURCE_EID) revert WrongSrcEid();

        OwnershipBridgeMessageLib.Envelope memory env = OwnershipBridgeMessageLib.decodeEnvelope(_message);
        address tradingSafe = TRADING_SAFE_FACTORY.getDeterministicAddress(env.safe);

        if (tradingSafe.code.length == 0) {
            emit OwnershipApplyDeferred(env.safe, tradingSafe, _guid, uint8(env.kind));
            return;
        }

        if (env.kind == OwnershipBridgeMessageLib.OpKind.ConfigureOwners) {
            _applyConfigureOwners(env.safe, tradingSafe, _guid, env.opData);
        } else if (env.kind == OwnershipBridgeMessageLib.OpKind.SetThreshold) {
            _applySetThreshold(env.safe, tradingSafe, _guid, env.opData);
        } else if (env.kind == OwnershipBridgeMessageLib.OpKind.Recover) {
            _applyRecover(env.safe, tradingSafe, _guid, env.opData);
        } else if (env.kind == OwnershipBridgeMessageLib.OpKind.CancelRecovery) {
            _applyCancelRecovery(env.safe, tradingSafe, _guid);
        } else {
            revert UnknownMessageKind(uint8(env.kind));
        }
    }

    /**
     * @dev Dispatches a decoded `configureOwners` operation to the TradingSafe.
     * @param sourceSafe Source-chain safe whose owners changed.
     * @param tradingSafe Destination TradingSafe address.
     * @param guid LZ message GUID, echoed in the emitted event.
     * @param opData Encoded `ConfigureOwnersData` payload.
     */
    function _applyConfigureOwners(address sourceSafe, address tradingSafe, bytes32 guid, bytes memory opData) internal {
        OwnershipBridgeMessageLib.ConfigureOwnersData memory d = OwnershipBridgeMessageLib.decodeConfigureOwners(opData);
        ITradingSafeBridgeReceiver(tradingSafe).applyBridgeConfigureOwners(d.owners, d.shouldAdd, d.threshold);
        emit ConfigureOwnersApplied(sourceSafe, tradingSafe, guid, d.owners, d.shouldAdd, d.threshold);
    }

    /**
     * @dev Dispatches a decoded `setThreshold` operation to the TradingSafe.
     * @param sourceSafe Source-chain safe.
     * @param tradingSafe Destination TradingSafe address.
     * @param guid LZ message GUID.
     * @param opData Encoded `SetThresholdData` payload.
     */
    function _applySetThreshold(address sourceSafe, address tradingSafe, bytes32 guid, bytes memory opData) internal {
        OwnershipBridgeMessageLib.SetThresholdData memory d = OwnershipBridgeMessageLib.decodeSetThreshold(opData);
        ITradingSafeBridgeReceiver(tradingSafe).applyBridgeSetThreshold(d.threshold);
        emit SetThresholdApplied(sourceSafe, tradingSafe, guid, d.threshold);
    }

    /**
     * @dev Dispatches a decoded `recover` operation to the TradingSafe.
     * @param sourceSafe Source-chain safe.
     * @param tradingSafe Destination TradingSafe address.
     * @param guid LZ message GUID.
     * @param opData Encoded `RecoverData` payload.
     */
    function _applyRecover(address sourceSafe, address tradingSafe, bytes32 guid, bytes memory opData) internal {
        OwnershipBridgeMessageLib.RecoverData memory d = OwnershipBridgeMessageLib.decodeRecover(opData);
        ITradingSafeBridgeReceiver(tradingSafe).applyBridgeRecover(d.newOwner, d.incomingOwnerEffectiveAt);
        emit RecoverApplied(sourceSafe, tradingSafe, guid, d.newOwner, d.incomingOwnerEffectiveAt);
    }

    /**
     * @dev Dispatches a decoded `cancelRecovery` operation to the TradingSafe.
     * @param sourceSafe Source-chain safe.
     * @param tradingSafe Destination TradingSafe address.
     * @param guid LZ message GUID.
     */
    function _applyCancelRecovery(address sourceSafe, address tradingSafe, bytes32 guid) internal {
        ITradingSafeBridgeReceiver(tradingSafe).applyBridgeCancelRecovery();
        emit CancelRecoveryApplied(sourceSafe, tradingSafe, guid);
    }
}
