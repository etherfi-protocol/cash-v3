// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { OwnershipBridgeMessageLib } from "../../src/libraries/OwnershipBridgeMessageLib.sol";

/// @dev Foundry can't take a `calldata` slice from a `memory` bytes, so we route the
///      envelope through this helper contract to convert it to calldata for the decoder.
contract DecoderHarness {
    function decodeEnvelope(bytes calldata data) external pure returns (OwnershipBridgeMessageLib.Envelope memory) {
        return OwnershipBridgeMessageLib.decodeEnvelope(data);
    }
}

contract OwnershipBridgeMessageLibTest is Test {
    DecoderHarness public harness;

    function setUp() public {
        harness = new DecoderHarness();
    }

    function test_envelope_roundtrip_configureOwners() public view {
        address safe = address(0xCAFE);
        address[] memory owners = new address[](2);
        owners[0] = address(0xA);
        owners[1] = address(0xB);
        bool[] memory shouldAdd = new bool[](2);
        shouldAdd[0] = true;
        shouldAdd[1] = false;
        uint8 threshold = 2;

        bytes memory opData = OwnershipBridgeMessageLib.encodeConfigureOwners(owners, shouldAdd, threshold);
        bytes memory encoded = OwnershipBridgeMessageLib.encodeEnvelope(
            OwnershipBridgeMessageLib.Envelope({
                kind: OwnershipBridgeMessageLib.OpKind.ConfigureOwners,
                safe: safe,
                opData: opData
            })
        );

        OwnershipBridgeMessageLib.Envelope memory env = harness.decodeEnvelope(encoded);
        assertEq(uint8(env.kind), uint8(OwnershipBridgeMessageLib.OpKind.ConfigureOwners));
        assertEq(env.safe, safe);

        OwnershipBridgeMessageLib.ConfigureOwnersData memory d = OwnershipBridgeMessageLib.decodeConfigureOwners(env.opData);
        assertEq(d.owners.length, 2);
        assertEq(d.owners[0], address(0xA));
        assertEq(d.owners[1], address(0xB));
        assertEq(d.shouldAdd.length, 2);
        assertTrue(d.shouldAdd[0]);
        assertFalse(d.shouldAdd[1]);
        assertEq(d.threshold, threshold);
    }

    function test_envelope_roundtrip_setThreshold() public view {
        bytes memory opData = OwnershipBridgeMessageLib.encodeSetThreshold(3);
        bytes memory encoded = OwnershipBridgeMessageLib.encodeEnvelope(
            OwnershipBridgeMessageLib.Envelope({
                kind: OwnershipBridgeMessageLib.OpKind.SetThreshold,
                safe: address(0x1234),
                opData: opData
            })
        );

        OwnershipBridgeMessageLib.Envelope memory env = harness.decodeEnvelope(encoded);
        assertEq(uint8(env.kind), uint8(OwnershipBridgeMessageLib.OpKind.SetThreshold));

        OwnershipBridgeMessageLib.SetThresholdData memory d = OwnershipBridgeMessageLib.decodeSetThreshold(env.opData);
        assertEq(d.threshold, 3);
    }

    function test_envelope_roundtrip_recover() public {
        address newOwner = makeAddr("newOwner");
        uint256 effectiveAt = 1_800_000_000;
        bytes memory opData = OwnershipBridgeMessageLib.encodeRecover(newOwner, effectiveAt);
        bytes memory encoded = OwnershipBridgeMessageLib.encodeEnvelope(
            OwnershipBridgeMessageLib.Envelope({
                kind: OwnershipBridgeMessageLib.OpKind.Recover,
                safe: address(0xBEEF),
                opData: opData
            })
        );

        OwnershipBridgeMessageLib.Envelope memory env = harness.decodeEnvelope(encoded);
        assertEq(uint8(env.kind), uint8(OwnershipBridgeMessageLib.OpKind.Recover));
        assertEq(env.safe, address(0xBEEF));

        OwnershipBridgeMessageLib.RecoverData memory d = OwnershipBridgeMessageLib.decodeRecover(env.opData);
        assertEq(d.newOwner, newOwner);
        assertEq(d.incomingOwnerEffectiveAt, effectiveAt);
    }

    function test_envelope_roundtrip_cancelRecovery() public view {
        bytes memory opData = OwnershipBridgeMessageLib.encodeCancelRecovery();
        bytes memory encoded = OwnershipBridgeMessageLib.encodeEnvelope(
            OwnershipBridgeMessageLib.Envelope({
                kind: OwnershipBridgeMessageLib.OpKind.CancelRecovery,
                safe: address(0xC0DE),
                opData: opData
            })
        );

        OwnershipBridgeMessageLib.Envelope memory env = harness.decodeEnvelope(encoded);
        assertEq(uint8(env.kind), uint8(OwnershipBridgeMessageLib.OpKind.CancelRecovery));
        assertEq(env.safe, address(0xC0DE));
        assertEq(env.opData.length, 0);
    }
}
