// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Origin } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppReceiverUpgradeable.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { IOwnershipBridgeReceiver } from "../../src/interfaces/IOwnershipBridgeReceiver.sol";
import { OwnershipBridgeMessageLib } from "../../src/libraries/OwnershipBridgeMessageLib.sol";
import { OwnershipBridgeReceiver } from "../../src/ownership-bridge/OwnershipBridgeReceiver.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TradingSafe } from "../../src/trading-safe/TradingSafe.sol";
import { TradingSafeFactory } from "../../src/trading-safe/TradingSafeFactory.sol";
import { LZEndpointMock } from "../mocks/LZEndpointMock.sol";
import { TradingSafeTestBase } from "../trading-safe/TradingSafeTestBase.t.sol";

/// @dev End-to-end receiver tests with a real `TradingSafeFactory` + `TradingSafe`. The deploy
///      ordering resolves a chicken-and-egg cycle: `TradingSafe` immutables include the
///      bridge-receiver address (so the safe must know the receiver at construction), and the
///      receiver immutables include the factory address (so the receiver must know the
///      factory at construction). We resolve this with CREATE3: the receiver proxy address is
///      a function of a salt + `address(this)`, independent of deploy order.
contract OwnershipBridgeReceiverTest is TradingSafeTestBase {
    OwnershipBridgeReceiver public receiver;
    TradingSafeFactory public factory;
    TradingSafe public tradingSafe;
    LZEndpointMock public endpoint;

    address public senderPeer = makeAddr("senderPeer");
    address public sourceSafe = makeAddr("sourceSafe");
    address public tradingSafeOwner = makeAddr("tradingSafeOwner");
    address public pauser = makeAddr("pauser");
    address public unpauser = makeAddr("unpauser");

    uint32 public constant OP_EID = 30_111;
    bytes32 public constant GUID = bytes32(uint256(1));
    bytes32 public constant RECEIVER_PROXY_SALT = keccak256("OwnershipBridgeReceiver");

    function setUp() public {
        _setupCore();
        endpoint = new LZEndpointMock();

        address predictedReceiver = CREATE3.predictDeterministicAddress(RECEIVER_PROXY_SALT);

        factory = _deployFactory(predictedReceiver);
        _initDataProvider(address(factory));

        address recvImpl = address(new OwnershipBridgeReceiver(address(endpoint), OP_EID, address(factory)));
        bytes memory proxyCreationCode = abi.encodePacked(
            type(UUPSProxy).creationCode,
            abi.encode(
                recvImpl,
                abi.encodeWithSelector(OwnershipBridgeReceiver.initialize.selector, owner, address(roleRegistry))
            )
        );
        receiver = OwnershipBridgeReceiver(CREATE3.deployDeterministic(proxyCreationCode, RECEIVER_PROXY_SALT));
        assertEq(address(receiver), predictedReceiver, "receiver proxy drifted from CREATE3 prediction");

        vm.startPrank(owner);
        receiver.setPeer(OP_EID, bytes32(uint256(uint160(senderPeer))));
        roleRegistry.grantRole(roleRegistry.PAUSER(), pauser);
        roleRegistry.grantRole(roleRegistry.UNPAUSER(), unpauser);
        roleRegistry.grantRole(factory.TRADING_SAFE_FACTORY_ADMIN_ROLE(), owner);

        address[] memory tsOwners = new address[](1);
        tsOwners[0] = tradingSafeOwner;
        tradingSafe = _deployTradingSafe(factory, sourceSafe, tsOwners, 1);
        vm.stopPrank();
    }

    // ---- helpers ----

    function _origin() internal view returns (Origin memory) {
        return Origin({ srcEid: OP_EID, sender: bytes32(uint256(uint160(senderPeer))), nonce: 1 });
    }

    function _wrongOrigin() internal view returns (Origin memory) {
        return Origin({ srcEid: 9999, sender: bytes32(uint256(uint160(senderPeer))), nonce: 1 });
    }

    function _send(Origin memory origin, bytes memory message) internal {
        vm.prank(address(endpoint));
        receiver.lzReceive(origin, GUID, message, address(0), "");
    }

    // ---- Each op kind: applied to the real TradingSafe ----

    function test_lzReceive_configureOwners_appliesToTradingSafe() public {
        address newOwner = makeAddr("newOwnerAdd");
        address[] memory owners = new address[](1);
        owners[0] = newOwner;
        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;

        bytes memory message = OwnershipBridgeMessageLib.encodeEnvelope(OwnershipBridgeMessageLib.Envelope({
            kind: OwnershipBridgeMessageLib.OpKind.ConfigureOwners,
            safe: sourceSafe,
            opData: OwnershipBridgeMessageLib.encodeConfigureOwners(owners, shouldAdd, 2)
        }));

        _send(_origin(), message);

        assertTrue(tradingSafe.isOwner(tradingSafeOwner), "original owner retained");
        assertTrue(tradingSafe.isOwner(newOwner), "new owner added");
        assertEq(tradingSafe.getThreshold(), 2);
        assertTrue(roleRegistry.isSafeAdmin(address(tradingSafe), newOwner), "admin role mirrored");
    }

    function test_lzReceive_setThreshold_appliesToTradingSafe() public {
        // First add a second owner so threshold=2 is valid.
        address secondOwner = makeAddr("secondOwner");
        address[] memory addOwners = new address[](1);
        addOwners[0] = secondOwner;
        bool[] memory addFlags = new bool[](1);
        addFlags[0] = true;
        bytes memory addMsg = OwnershipBridgeMessageLib.encodeEnvelope(OwnershipBridgeMessageLib.Envelope({
            kind: OwnershipBridgeMessageLib.OpKind.ConfigureOwners,
            safe: sourceSafe,
            opData: OwnershipBridgeMessageLib.encodeConfigureOwners(addOwners, addFlags, 1)
        }));
        _send(_origin(), addMsg);

        bytes memory message = OwnershipBridgeMessageLib.encodeEnvelope(OwnershipBridgeMessageLib.Envelope({
            kind: OwnershipBridgeMessageLib.OpKind.SetThreshold,
            safe: sourceSafe,
            opData: OwnershipBridgeMessageLib.encodeSetThreshold(2)
        }));
        _send(_origin(), message);

        assertEq(tradingSafe.getThreshold(), 2);
    }

    function test_lzReceive_recover_appliesToTradingSafe() public {
        address newOwner = makeAddr("recoveryOwner");
        uint256 effectiveAt = block.timestamp + 7 days;
        bytes memory message = OwnershipBridgeMessageLib.encodeEnvelope(OwnershipBridgeMessageLib.Envelope({
            kind: OwnershipBridgeMessageLib.OpKind.Recover,
            safe: sourceSafe,
            opData: OwnershipBridgeMessageLib.encodeRecover(newOwner, effectiveAt)
        }));

        _send(_origin(), message);

        assertEq(tradingSafe.getIncomingOwner(), newOwner);
        assertEq(tradingSafe.getIncomingOwnerStartTime(), effectiveAt);
    }

    function test_lzReceive_cancelRecovery_appliesToTradingSafe() public {
        // Seed an incoming owner first.
        address newOwner = makeAddr("recoveryOwner");
        bytes memory recoverMsg = OwnershipBridgeMessageLib.encodeEnvelope(OwnershipBridgeMessageLib.Envelope({
            kind: OwnershipBridgeMessageLib.OpKind.Recover,
            safe: sourceSafe,
            opData: OwnershipBridgeMessageLib.encodeRecover(newOwner, block.timestamp + 7 days)
        }));
        _send(_origin(), recoverMsg);
        assertEq(tradingSafe.getIncomingOwner(), newOwner);

        bytes memory message = OwnershipBridgeMessageLib.encodeEnvelope(OwnershipBridgeMessageLib.Envelope({
            kind: OwnershipBridgeMessageLib.OpKind.CancelRecovery,
            safe: sourceSafe,
            opData: OwnershipBridgeMessageLib.encodeCancelRecovery()
        }));
        _send(_origin(), message);

        assertEq(tradingSafe.getIncomingOwner(), address(0));
        assertEq(tradingSafe.getIncomingOwnerStartTime(), 0);
    }

    // ---- Deferred when TradingSafe not deployed ----

    function test_lzReceive_emitsDeferred_whenTradingSafeUndeployed() public {
        // Use a source-safe we never call `_deployTradingSafe` for — the factory predicts a
        // deterministic address but no contract exists at it.
        address undeployedSource = makeAddr("undeployedSource");
        address predicted = factory.getDeterministicAddress(undeployedSource);
        assertEq(predicted.code.length, 0, "predicted address should be empty");

        bytes memory message = OwnershipBridgeMessageLib.encodeEnvelope(OwnershipBridgeMessageLib.Envelope({
            kind: OwnershipBridgeMessageLib.OpKind.SetThreshold,
            safe: undeployedSource,
            opData: OwnershipBridgeMessageLib.encodeSetThreshold(5)
        }));

        vm.expectEmit(true, true, true, true);
        emit IOwnershipBridgeReceiver.OwnershipApplyDeferred(undeployedSource, predicted, GUID, uint8(OwnershipBridgeMessageLib.OpKind.SetThreshold));

        _send(_origin(), message);

        // Deployed TradingSafe (for `sourceSafe`) is untouched — threshold still 1.
        assertEq(tradingSafe.getThreshold(), 1);
    }

    // ---- Source EID validation ----

    function test_lzReceive_revertsWhen_wrongSrcEid() public {
        bytes memory message = OwnershipBridgeMessageLib.encodeEnvelope(OwnershipBridgeMessageLib.Envelope({
            kind: OwnershipBridgeMessageLib.OpKind.SetThreshold,
            safe: sourceSafe,
            opData: OwnershipBridgeMessageLib.encodeSetThreshold(2)
        }));

        // Peer for src 9999 isn't set; OAppReceiver's peer check fails first with OnlyPeer.
        vm.expectRevert();
        vm.prank(address(endpoint));
        receiver.lzReceive(_wrongOrigin(), GUID, message, address(0), "");
    }

    // ---- Pause / unpause ----

    function test_pause_pauserOnly() public {
        vm.expectRevert(RoleRegistry.OnlyPauser.selector);
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
