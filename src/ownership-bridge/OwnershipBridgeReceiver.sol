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
 *      In addition to LayerZero's transport authentication and GUID replay protection, the
 *      receiver tracks the last applied source-safe nonce. Older or duplicate operations are
 *      consumed without application so delayed messages cannot overwrite newer owner state.
 *      `srcEid` is checked as defence-in-depth against peer misconfiguration.
 *
 *      If a message arrives for a TradingSafe that hasn't been deployed yet, we emit
 *      `OwnershipApplyDeferred` and exit cleanly. The eventual lazy-deploy reads the current
 *      source-chain owner state, so the missed bridge update is a no-op in practice.
 */
contract OwnershipBridgeReceiver is IOwnershipBridgeReceiver, OAppReceiverUpgradeable, UpgradeableProxy {
    /// @custom:storage-location erc7201:etherfi.storage.OwnershipBridgeReceiver
    struct OwnershipBridgeReceiverStorage {
        mapping(address sourceSafe => uint256 nonce) lastAppliedSourceNonce;
        mapping(address sourceSafe => bool initialized) hasAppliedSourceNonce;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.OwnershipBridgeReceiver")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OwnershipBridgeReceiverStorageLocation =
        0x0837cfcd8214934b45c9229c8defc12d69d66511b675670079b781633d90bb00;

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
        if (env.version != OwnershipBridgeMessageLib.ENVELOPE_VERSION) {
            revert UnsupportedEnvelopeVersion(env.version);
        }
        address tradingSafe = TRADING_SAFE_FACTORY.getDeterministicAddress(env.safe);

        if (tradingSafe.code.length == 0) {
            emit OwnershipApplyDeferred(env.safe, tradingSafe, _guid, uint8(env.kind));
            return;
        }

        if (!_recordSourceNonce(env.safe, tradingSafe, _guid, env.kind, env.sourceNonce)) return;

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

    function lastAppliedSourceNonce(address sourceSafe) external view returns (uint256 nonce, bool initialized) {
        OwnershipBridgeReceiverStorage storage $ = _getOwnershipBridgeReceiverStorage();
        return ($.lastAppliedSourceNonce[sourceSafe], $.hasAppliedSourceNonce[sourceSafe]);
    }

    function _recordSourceNonce(
        address sourceSafe,
        address tradingSafe,
        bytes32 guid,
        OwnershipBridgeMessageLib.OpKind kind,
        uint256 sourceNonce
    ) internal returns (bool) {
        OwnershipBridgeReceiverStorage storage $ = _getOwnershipBridgeReceiverStorage();
        if (
            $.hasAppliedSourceNonce[sourceSafe] &&
            sourceNonce <= $.lastAppliedSourceNonce[sourceSafe]
        ) {
            emit StaleOwnershipMessageSkipped(
                sourceSafe,
                tradingSafe,
                guid,
                uint8(kind),
                sourceNonce,
                $.lastAppliedSourceNonce[sourceSafe]
            );
            return false;
        }

        $.lastAppliedSourceNonce[sourceSafe] = sourceNonce;
        $.hasAppliedSourceNonce[sourceSafe] = true;
        return true;
    }

    function _getOwnershipBridgeReceiverStorage()
        private
        pure
        returns (OwnershipBridgeReceiverStorage storage $)
    {
        assembly {
            $.slot := OwnershipBridgeReceiverStorageLocation
        }
    }
}
