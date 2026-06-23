// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IOwnershipBridgeReceiver
 * @author ether.fi
 * @notice Destination-chain (mainnet) singleton that receives owner-mutating operations from
 *         the source-chain `OwnershipBridgeSender` via LayerZero and applies them to the
 *         user's TradingSafe.
 */
interface IOwnershipBridgeReceiver {
    /**
     * @notice Emitted when a `configureOwners` operation is successfully applied on a TradingSafe.
     * @param sourceSafe Source-chain safe whose owners changed.
     * @param tradingSafe Destination TradingSafe that received the update.
     * @param guid LayerZero message GUID for traceability.
     * @param owners Owners added or removed.
     * @param shouldAdd Per-owner add (true) / remove (false) flag.
     * @param threshold New signature threshold.
     */
    event ConfigureOwnersApplied(
        address indexed sourceSafe,
        address indexed tradingSafe,
        bytes32 indexed guid,
        address[] owners,
        bool[] shouldAdd,
        uint8 threshold
    );

    /**
     * @notice Emitted when a `setThreshold` operation is applied.
     * @param sourceSafe Source-chain safe.
     * @param tradingSafe Destination TradingSafe.
     * @param guid LayerZero message GUID.
     * @param threshold New signature threshold.
     */
    event SetThresholdApplied(
        address indexed sourceSafe,
        address indexed tradingSafe,
        bytes32 indexed guid,
        uint8 threshold
    );

    /**
     * @notice Emitted when a `recover` operation is applied.
     * @param sourceSafe Source-chain safe.
     * @param tradingSafe Destination TradingSafe.
     * @param guid LayerZero message GUID.
     * @param newOwner Incoming owner that will take effect after the local timelock.
     * @param incomingOwnerEffectiveAt Source-chain UNIX timestamp at which `newOwner` should activate.
     */
    event RecoverApplied(
        address indexed sourceSafe,
        address indexed tradingSafe,
        bytes32 indexed guid,
        address newOwner,
        uint256 incomingOwnerEffectiveAt
    );

    /**
     * @notice Emitted when a `cancelRecovery` operation is applied.
     * @param sourceSafe Source-chain safe.
     * @param tradingSafe Destination TradingSafe.
     * @param guid LayerZero message GUID.
     */
    event CancelRecoveryApplied(
        address indexed sourceSafe,
        address indexed tradingSafe,
        bytes32 indexed guid
    );

    /**
     * @notice Emitted when a message arrives for a TradingSafe that has not been deployed yet.
     * @dev The eventual lazy-deploy reads the current source-chain owner state, so the missed
     *      bridge update is a no-op in practice. We log + exit cleanly to let the LZ packet
     *      succeed (instead of reverting and pinning the inbound queue).
     * @param sourceSafe Source-chain safe whose update could not be applied.
     * @param tradingSafe The pre-computed (but not deployed) destination address.
     * @param guid LayerZero message GUID.
     * @param kind The `OpKind` of the deferred operation, cast to `uint8`.
     */
    event OwnershipApplyDeferred(
        address indexed sourceSafe,
        address indexed tradingSafe,
        bytes32 indexed guid,
        uint8 kind
    );

    /// @notice Reverts when the LZ packet's source EID doesn't match the configured `SOURCE_EID`.
    error WrongSrcEid();

    /**
     * @notice Reverts when the envelope's `OpKind` discriminator is outside the known set.
     * @param kind The unknown kind value, cast to `uint8`.
     */
    error UnknownMessageKind(uint8 kind);
}
