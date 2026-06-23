// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title OwnershipBridgeMessageLib
 * @author ether.fi
 * @notice Encode / decode for the cross-chain ownership-bridge envelope and per-kind payloads.
 * @dev Each safe owner-mutating operation on the source chain is published as one envelope.
 *      The envelope carries an `OpKind` discriminator + source safe address + ABI-encoded
 *      per-kind payload. The receiver decodes by kind and dispatches to the matching
 *      `applyBridge*` function on the destination TradingSafe.
 */
library OwnershipBridgeMessageLib {
    /**
     * @notice Identifies which owner-mutating operation an envelope carries.
     * @dev The receiver decodes `opData` against the matching kind-specific struct below.
     */
    enum OpKind {
        ConfigureOwners,
        SetThreshold,
        Recover,
        CancelRecovery
    }

    /**
     * @notice Top-level envelope sent over LayerZero.
     * @param kind Discriminator for the operation type.
     * @param safe Source-chain safe address whose state is changing.
     * @param opData ABI-encoded kind-specific payload (see per-kind structs).
     */
    struct Envelope {
        OpKind kind;
        address safe;
        bytes opData;
    }

    /**
     * @notice Payload for `OpKind.ConfigureOwners`.
     * @param owners Owners to add or remove.
     * @param shouldAdd Per-owner flag; true to add, false to remove.
     * @param threshold New signature threshold after the change is applied.
     */
    struct ConfigureOwnersData {
        address[] owners;
        bool[] shouldAdd;
        uint8 threshold;
    }

    /**
     * @notice Payload for `OpKind.SetThreshold`.
     * @param threshold New signature threshold.
     */
    struct SetThresholdData {
        uint8 threshold;
    }

    /**
     * @notice Payload for `OpKind.Recover`.
     * @param newOwner Incoming owner that will take effect after the destination's timelock.
     * @param incomingOwnerEffectiveAt Source-chain UNIX timestamp at which the incoming owner
     *        should become active on the destination. Lets the destination mirror the source's
     *        timelock target instead of computing its own local one.
     */
    struct RecoverData {
        address newOwner;
        uint256 incomingOwnerEffectiveAt;
    }

    // `OpKind.CancelRecovery` has no payload data; opData is empty bytes.

    /**
     * @notice ABI-encodes an envelope for LZ transit.
     * @param e Envelope to encode.
     * @return The encoded bytes ready to be passed as the LZ message payload.
     */
    function encodeEnvelope(Envelope memory e) internal pure returns (bytes memory) {
        return abi.encode(uint8(e.kind), e.safe, e.opData);
    }

    /**
     * @notice ABI-decodes an envelope received over LZ.
     * @param data Calldata bytes of the envelope payload.
     * @return e Decoded envelope.
     */
    function decodeEnvelope(bytes calldata data) internal pure returns (Envelope memory e) {
        uint8 k;
        (k, e.safe, e.opData) = abi.decode(data, (uint8, address, bytes));
        e.kind = OpKind(k);
    }

    /**
     * @notice ABI-encodes a `ConfigureOwners` payload for use inside `Envelope.opData`.
     * @param owners Owners to add or remove.
     * @param shouldAdd Per-owner add (true) / remove (false) flag.
     * @param threshold New signature threshold.
     * @return The encoded payload bytes.
     */
    function encodeConfigureOwners(address[] memory owners, bool[] memory shouldAdd, uint8 threshold) internal pure returns (bytes memory) {
        return abi.encode(owners, shouldAdd, threshold);
    }

    /**
     * @notice ABI-decodes a `ConfigureOwners` payload.
     * @param data Encoded payload bytes (from `Envelope.opData`).
     * @return d Decoded data struct.
     */
    function decodeConfigureOwners(bytes memory data) internal pure returns (ConfigureOwnersData memory d) {
        (d.owners, d.shouldAdd, d.threshold) = abi.decode(data, (address[], bool[], uint8));
    }

    /**
     * @notice ABI-encodes a `SetThreshold` payload.
     * @param threshold New signature threshold.
     * @return The encoded payload bytes.
     */
    function encodeSetThreshold(uint8 threshold) internal pure returns (bytes memory) {
        return abi.encode(threshold);
    }

    /**
     * @notice ABI-decodes a `SetThreshold` payload.
     * @param data Encoded payload bytes.
     * @return d Decoded data struct.
     */
    function decodeSetThreshold(bytes memory data) internal pure returns (SetThresholdData memory d) {
        d.threshold = abi.decode(data, (uint8));
    }

    /**
     * @notice ABI-encodes a `Recover` payload.
     * @param newOwner Incoming owner that will take effect after the destination's timelock.
     * @param incomingOwnerEffectiveAt Source-chain UNIX timestamp at which the incoming owner activates.
     * @return The encoded payload bytes.
     */
    function encodeRecover(address newOwner, uint256 incomingOwnerEffectiveAt) internal pure returns (bytes memory) {
        return abi.encode(newOwner, incomingOwnerEffectiveAt);
    }

    /**
     * @notice ABI-decodes a `Recover` payload.
     * @param data Encoded payload bytes.
     * @return d Decoded data struct.
     */
    function decodeRecover(bytes memory data) internal pure returns (RecoverData memory d) {
        (d.newOwner, d.incomingOwnerEffectiveAt) = abi.decode(data, (address, uint256));
    }

    /**
     * @notice Returns the empty-bytes payload for `OpKind.CancelRecovery`.
     * @dev Provided for symmetry with the other `encode*` helpers; cancel-recovery carries
     *      no parameters.
     * @return Empty bytes (no payload data needed).
     */
    function encodeCancelRecovery() internal pure returns (bytes memory) {
        return new bytes(0);
    }
}
