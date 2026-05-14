// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Origin } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppReceiverUpgradeable.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { IOwnershipBridgeReceiver } from "../../src/interfaces/IOwnershipBridgeReceiver.sol";
import { ITradingSafeBridgeReceiver } from "../../src/interfaces/ITradingSafeBridgeReceiver.sol";
import { OwnershipBridgeMessageLib } from "../../src/libraries/OwnershipBridgeMessageLib.sol";
import { OwnershipBridgeReceiver } from "../../src/ownership-bridge/OwnershipBridgeReceiver.sol";
import { LZEndpointMock } from "../mocks/LZEndpointMock.sol";
import { RoleRegistryMock } from "../mocks/RoleRegistryMock.sol";

/// @dev Stub TradingSafeFactory: returns a configurable address per source safe.
contract TradingSafeFactoryStub {
    mapping(address => address) public deterministicAddressFor;
    function setDeterministicAddress(address sourceSafe, address tradingSafe) external {
        deterministicAddressFor[sourceSafe] = tradingSafe;
    }
    function getDeterministicAddress(address sourceSafe) external view returns (address) {
        return deterministicAddressFor[sourceSafe];
    }
}

/// @dev Stub TradingSafe: records each `applyBridge*` call for assertions.
contract TradingSafeStub is ITradingSafeBridgeReceiver {
    address[] public lastConfigureOwners_owners;
    bool[] public lastConfigureOwners_shouldAdd;
    uint8 public lastConfigureOwners_threshold;
    uint256 public configureOwnersCallCount;

    uint8 public lastSetThreshold_threshold;
    uint256 public setThresholdCallCount;

    address public lastRecover_newOwner;
    uint256 public lastRecover_incomingOwnerEffectiveAt;
    uint256 public recoverCallCount;

    uint256 public cancelRecoveryCallCount;

    function applyBridgeConfigureOwners(address[] calldata owners, bool[] calldata shouldAdd, uint8 threshold) external override {
        delete lastConfigureOwners_owners;
        delete lastConfigureOwners_shouldAdd;
        for (uint256 i = 0; i < owners.length; i++) lastConfigureOwners_owners.push(owners[i]);
        for (uint256 i = 0; i < shouldAdd.length; i++) lastConfigureOwners_shouldAdd.push(shouldAdd[i]);
        lastConfigureOwners_threshold = threshold;
        configureOwnersCallCount++;
    }

    function applyBridgeSetThreshold(uint8 threshold) external override {
        lastSetThreshold_threshold = threshold;
        setThresholdCallCount++;
    }

    function applyBridgeRecover(address newOwner, uint256 incomingOwnerEffectiveAt) external override {
        lastRecover_newOwner = newOwner;
        lastRecover_incomingOwnerEffectiveAt = incomingOwnerEffectiveAt;
        recoverCallCount++;
    }

    function applyBridgeCancelRecovery() external override {
        cancelRecoveryCallCount++;
    }
}

contract OwnershipBridgeReceiverTest is Test {
    OwnershipBridgeReceiver public receiver;
    LZEndpointMock public endpoint;
    RoleRegistryMock public roleRegistry;
    TradingSafeFactoryStub public factory;
    TradingSafeStub public tradingSafe;

    address public delegate = makeAddr("delegate");
    address public pauser = makeAddr("pauser");
    address public unpauser = makeAddr("unpauser");
    address public senderPeer = makeAddr("senderPeer");
    address public sourceSafe = makeAddr("sourceSafe");

    uint32 public constant OP_EID = 30_111;
    bytes32 public constant GUID = bytes32(uint256(1));

    function setUp() public {
        endpoint = new LZEndpointMock();
        roleRegistry = new RoleRegistryMock(pauser, unpauser);
        factory = new TradingSafeFactoryStub();
        tradingSafe = new TradingSafeStub();

        factory.setDeterministicAddress(sourceSafe, address(tradingSafe));

        address impl = address(new OwnershipBridgeReceiver(address(endpoint), OP_EID, address(factory)));
        receiver = OwnershipBridgeReceiver(
            address(new UUPSProxy(impl, abi.encodeWithSelector(OwnershipBridgeReceiver.initialize.selector, delegate, address(roleRegistry))))
        );

        vm.prank(delegate);
        receiver.setPeer(OP_EID, bytes32(uint256(uint160(senderPeer))));
    }

    function _origin() internal view returns (Origin memory) {
        return Origin({ srcEid: OP_EID, sender: bytes32(uint256(uint160(senderPeer))), nonce: 1 });
    }

    function _wrongOrigin() internal view returns (Origin memory) {
        return Origin({ srcEid: 9999, sender: bytes32(uint256(uint160(senderPeer))), nonce: 1 });
    }

    function _envelopeConfigureOwners(address[] memory owners, bool[] memory shouldAdd, uint8 threshold) internal pure returns (bytes memory) {
        return OwnershipBridgeMessageLib.encodeEnvelope(OwnershipBridgeMessageLib.Envelope({
            kind: OwnershipBridgeMessageLib.OpKind.ConfigureOwners,
            safe: address(0), // overwritten below
            opData: OwnershipBridgeMessageLib.encodeConfigureOwners(owners, shouldAdd, threshold)
        }));
    }

    function _send(Origin memory origin, bytes memory message) internal {
        vm.prank(address(endpoint));
        receiver.lzReceive(origin, GUID, message, address(0), "");
    }

    // ---- Each op kind: correct dispatch ----

    function test_lzReceive_configureOwners_dispatchesToTradingSafe() public {
        address[] memory owners = new address[](2);
        owners[0] = address(0xA1A1);
        owners[1] = address(0xB2B2);
        bool[] memory shouldAdd = new bool[](2);
        shouldAdd[0] = true;
        shouldAdd[1] = false;

        bytes memory message = OwnershipBridgeMessageLib.encodeEnvelope(OwnershipBridgeMessageLib.Envelope({
            kind: OwnershipBridgeMessageLib.OpKind.ConfigureOwners,
            safe: sourceSafe,
            opData: OwnershipBridgeMessageLib.encodeConfigureOwners(owners, shouldAdd, 2)
        }));

        _send(_origin(), message);

        assertEq(tradingSafe.configureOwnersCallCount(), 1);
        assertEq(tradingSafe.lastConfigureOwners_threshold(), 2);
        assertEq(tradingSafe.lastConfigureOwners_owners(0), address(0xA1A1));
        assertEq(tradingSafe.lastConfigureOwners_owners(1), address(0xB2B2));
        assertTrue(tradingSafe.lastConfigureOwners_shouldAdd(0));
        assertFalse(tradingSafe.lastConfigureOwners_shouldAdd(1));
    }

    function test_lzReceive_setThreshold_dispatches() public {
        bytes memory message = OwnershipBridgeMessageLib.encodeEnvelope(OwnershipBridgeMessageLib.Envelope({
            kind: OwnershipBridgeMessageLib.OpKind.SetThreshold,
            safe: sourceSafe,
            opData: OwnershipBridgeMessageLib.encodeSetThreshold(4)
        }));

        _send(_origin(), message);

        assertEq(tradingSafe.setThresholdCallCount(), 1);
        assertEq(tradingSafe.lastSetThreshold_threshold(), 4);
    }

    function test_lzReceive_recover_dispatches() public {
        address newOwner = makeAddr("newOwner");
        uint256 effectiveAt = block.timestamp + 7 days;
        bytes memory message = OwnershipBridgeMessageLib.encodeEnvelope(OwnershipBridgeMessageLib.Envelope({
            kind: OwnershipBridgeMessageLib.OpKind.Recover,
            safe: sourceSafe,
            opData: OwnershipBridgeMessageLib.encodeRecover(newOwner, effectiveAt)
        }));

        _send(_origin(), message);

        assertEq(tradingSafe.recoverCallCount(), 1);
        assertEq(tradingSafe.lastRecover_newOwner(), newOwner);
        assertEq(tradingSafe.lastRecover_incomingOwnerEffectiveAt(), effectiveAt);
    }

    function test_lzReceive_cancelRecovery_dispatches() public {
        bytes memory message = OwnershipBridgeMessageLib.encodeEnvelope(OwnershipBridgeMessageLib.Envelope({
            kind: OwnershipBridgeMessageLib.OpKind.CancelRecovery,
            safe: sourceSafe,
            opData: OwnershipBridgeMessageLib.encodeCancelRecovery()
        }));

        _send(_origin(), message);

        assertEq(tradingSafe.cancelRecoveryCallCount(), 1);
    }

    // ---- Deferred when TradingSafe not deployed ----

    function test_lzReceive_emitsDeferred_whenTradingSafeUndeployed() public {
        address newSourceSafe = makeAddr("anotherSource");
        address predictedAddr = makeAddr("predictedTradingSafe"); // not deployed (no code at this address)
        factory.setDeterministicAddress(newSourceSafe, predictedAddr);

        bytes memory message = OwnershipBridgeMessageLib.encodeEnvelope(OwnershipBridgeMessageLib.Envelope({
            kind: OwnershipBridgeMessageLib.OpKind.SetThreshold,
            safe: newSourceSafe,
            opData: OwnershipBridgeMessageLib.encodeSetThreshold(5)
        }));

        vm.expectEmit(true, true, true, true);
        emit IOwnershipBridgeReceiver.OwnershipApplyDeferred(newSourceSafe, predictedAddr, GUID, uint8(OwnershipBridgeMessageLib.OpKind.SetThreshold));

        _send(_origin(), message);

        // No-op on the stub.
        assertEq(tradingSafe.setThresholdCallCount(), 0);
    }

    // ---- Source EID validation ----

    function test_lzReceive_revertsWhen_wrongSrcEid() public {
        bytes memory message = OwnershipBridgeMessageLib.encodeEnvelope(OwnershipBridgeMessageLib.Envelope({
            kind: OwnershipBridgeMessageLib.OpKind.SetThreshold,
            safe: sourceSafe,
            opData: OwnershipBridgeMessageLib.encodeSetThreshold(2)
        }));

        // Peer for src 9999 isn't set, so OAppReceiver's peer check fails first with OnlyPeer.
        // We just assert it reverts — either check protects us.
        vm.expectRevert();
        vm.prank(address(endpoint));
        receiver.lzReceive(_wrongOrigin(), GUID, message, address(0), "");
    }

    // ---- Pause / unpause ----

    function test_pause_pauserOnly() public {
        vm.expectRevert(RoleRegistryMock.NotPauser.selector);
        receiver.pause();

        vm.prank(pauser);
        receiver.pause();
    }

    function test_lzReceive_revertsWhen_paused() public {
        vm.prank(pauser);
        receiver.pause();

        bytes memory message = OwnershipBridgeMessageLib.encodeEnvelope(OwnershipBridgeMessageLib.Envelope({
            kind: OwnershipBridgeMessageLib.OpKind.SetThreshold,
            safe: sourceSafe,
            opData: OwnershipBridgeMessageLib.encodeSetThreshold(2)
        }));

        vm.expectRevert();
        vm.prank(address(endpoint));
        receiver.lzReceive(_origin(), GUID, message, address(0), "");
    }
}
