// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { IOwnershipBridgeSender } from "../../src/interfaces/IOwnershipBridgeSender.sol";
import { OwnershipBridgeMessageLib } from "../../src/libraries/OwnershipBridgeMessageLib.sol";
import { OwnershipBridgeSender } from "../../src/ownership-bridge/OwnershipBridgeSender.sol";
import { LZEndpointMock } from "../mocks/LZEndpointMock.sol";

/// @dev Minimal IEtherFiDataProvider stub — only `isEtherFiSafe` + `roleRegistry`.
contract DataProviderMock {
    mapping(address => bool) public isEtherFiSafeMap;
    address public roleRegistryAddr;

    function setSafe(address safe, bool ok) external { isEtherFiSafeMap[safe] = ok; }
    function setRoleRegistry(address r) external { roleRegistryAddr = r; }

    function isEtherFiSafe(address a) external view returns (bool) { return isEtherFiSafeMap[a]; }
    function roleRegistry() external view returns (address) { return roleRegistryAddr; }
}

/// @dev Minimal IRoleRegistry stub.
contract RoleRegistryStub {
    address public pauserAddr;
    address public unpauserAddr;
    mapping(bytes32 => mapping(address => bool)) public roles;
    error NotPauser();
    error NotUnpauser();
    constructor(address p, address u) { pauserAddr = p; unpauserAddr = u; }
    function onlyPauser(address a) external view { if (a != pauserAddr) revert NotPauser(); }
    function onlyUnpauser(address a) external view { if (a != unpauserAddr) revert NotUnpauser(); }
    function hasRole(bytes32 role, address account) external view returns (bool) { return roles[role][account]; }
    function grantRole(bytes32 role, address account) external { roles[role][account] = true; }
}

/// @dev Helper to call the sender as if we were a safe. The sender requires `msg.sender == safe`.
contract SafeCaller {
    OwnershipBridgeSender public immutable sender;
    constructor(OwnershipBridgeSender _sender) { sender = _sender; }

    function publishConfigureOwners(address[] calldata owners, bool[] calldata shouldAdd, uint8 threshold) external payable {
        sender.publishConfigureOwners{value: msg.value}(address(this), owners, shouldAdd, threshold);
    }
    function publishSetThreshold(uint8 threshold) external payable {
        sender.publishSetThreshold{value: msg.value}(address(this), threshold);
    }
    function publishRecover(address newOwner, uint256 incomingOwnerEffectiveAt) external payable {
        sender.publishRecover{value: msg.value}(address(this), newOwner, incomingOwnerEffectiveAt);
    }
    function publishCancelRecovery() external payable {
        sender.publishCancelRecovery{value: msg.value}(address(this));
    }

    receive() external payable {}
}

contract OwnershipBridgeSenderTest is Test {
    OwnershipBridgeSender public sender;
    LZEndpointMock public endpoint;
    DataProviderMock public dataProvider;
    RoleRegistryStub public roleRegistry;
    SafeCaller public safeCaller;

    address public delegate = makeAddr("delegate");
    address public pauser = makeAddr("pauser");
    address public unpauser = makeAddr("unpauser");
    address public etherFiWallet = makeAddr("etherFiWallet");
    address public receiverPeer = makeAddr("receiverPeer");
    uint32 public constant MAINNET_EID = 30_101;

    function setUp() public {
        endpoint = new LZEndpointMock();
        dataProvider = new DataProviderMock();
        roleRegistry = new RoleRegistryStub(pauser, unpauser);
        dataProvider.setRoleRegistry(address(roleRegistry));

        vm.startPrank(delegate);
        sender = new OwnershipBridgeSender(address(dataProvider), address(endpoint), delegate);
        sender.setPeer(MAINNET_EID, bytes32(uint256(uint160(receiverPeer))));
        sender.configureDestination(MAINNET_EID, "", true);
        vm.stopPrank();

        safeCaller = new SafeCaller(sender);
        dataProvider.setSafe(address(safeCaller), true);

        // Grant ETHER_FI_WALLET role and enable the SafeCaller — most tests expect the
        // bridge to be active. The disabled-path tests deploy and use a separate safe.
        roleRegistry.grantRole(sender.ETHER_FI_WALLET_ROLE(), etherFiWallet);
        vm.prank(etherFiWallet);
        sender.enable(address(safeCaller), MAINNET_EID);
    }

    function _owners() internal pure returns (address[] memory o, bool[] memory s) {
        o = new address[](2);
        o[0] = address(0xA1A1);
        o[1] = address(0xB2B2);
        s = new bool[](2);
        s[0] = true;
        s[1] = false;
    }

    // ---- Happy path: each publish kind dispatches to LZ and emits ----

    function test_publishConfigureOwners_happyPath() public {
        (address[] memory owners, bool[] memory shouldAdd) = _owners();

        safeCaller.publishConfigureOwners(owners, shouldAdd, 2);

        (uint32 dstEid, bytes memory message) = endpoint.lastSendArgs();
        assertEq(uint256(dstEid), uint256(MAINNET_EID));

        (uint8 kind, address envSafe, ) = abi.decode(message, (uint8, address, bytes));
        assertEq(kind, uint8(OwnershipBridgeMessageLib.OpKind.ConfigureOwners));
        assertEq(envSafe, address(safeCaller));
    }

    function test_publishSetThreshold_happyPath() public {
        safeCaller.publishSetThreshold(3);
        (uint32 dstEid, bytes memory message) = endpoint.lastSendArgs();
        assertEq(uint256(dstEid), uint256(MAINNET_EID));
        (uint8 kind, , ) = abi.decode(message, (uint8, address, bytes));
        assertEq(kind, uint8(OwnershipBridgeMessageLib.OpKind.SetThreshold));
    }

    function test_publishRecover_happyPath() public {
        address newOwner = makeAddr("newOwner");
        uint256 effectiveAt = block.timestamp + 7 days;
        safeCaller.publishRecover(newOwner, effectiveAt);
        (uint8 kind, , bytes memory opData) = abi.decode(endpoint.lastMessage(), (uint8, address, bytes));
        assertEq(kind, uint8(OwnershipBridgeMessageLib.OpKind.Recover));
        (address decodedOwner, uint256 decodedEffectiveAt) = abi.decode(opData, (address, uint256));
        assertEq(decodedOwner, newOwner);
        assertEq(decodedEffectiveAt, effectiveAt);
    }

    function test_publishCancelRecovery_happyPath() public {
        safeCaller.publishCancelRecovery();
        (uint8 kind, , ) = abi.decode(endpoint.lastMessage(), (uint8, address, bytes));
        assertEq(kind, uint8(OwnershipBridgeMessageLib.OpKind.CancelRecovery));
    }

    // ---- Auth: caller must be the safe AND a registered EtherFiSafe ----

    function test_publish_revertsWhen_callerNotSafe() public {
        address notSafe = makeAddr("notSafe");
        (address[] memory owners, bool[] memory shouldAdd) = _owners();
        vm.expectRevert(IOwnershipBridgeSender.CallerNotSafe.selector);
        vm.prank(notSafe);
        sender.publishConfigureOwners(address(safeCaller), owners, shouldAdd, 2);
    }

    function test_publish_revertsWhen_safeNotRegistered() public {
        SafeCaller rogue = new SafeCaller(sender);
        // No registration in dataProvider.
        (address[] memory owners, bool[] memory shouldAdd) = _owners();
        vm.expectRevert(IOwnershipBridgeSender.NotEtherFiSafe.selector);
        rogue.publishConfigureOwners(owners, shouldAdd, 2);
    }

    // ---- Destination state ----

    function test_publish_revertsWhen_destinationLaterRemoved() public {
        // safeCaller is enabled for MAINNET_EID in setUp. Admin removes it globally; an
        // enabled-but-no-longer-configured destination must surface explicitly during publish.
        vm.prank(delegate);
        sender.configureDestination(MAINNET_EID, "", false);

        (address[] memory owners, bool[] memory shouldAdd) = _owners();
        vm.expectRevert(abi.encodeWithSelector(IOwnershipBridgeSender.DestinationNotConfigured.selector, MAINNET_EID));
        safeCaller.publishConfigureOwners(owners, shouldAdd, 2);
    }

    function test_publish_revertsWhen_peerMissing() public {
        // Configure destEid 9999 globally but never call setPeer; create a fresh safe enabled
        // for ONLY 9999 so the dispatch loop hits the missing-peer destination cleanly.
        vm.prank(delegate);
        sender.configureDestination(9999, "", true);

        SafeCaller other = new SafeCaller(sender);
        dataProvider.setSafe(address(other), true);
        vm.prank(etherFiWallet);
        sender.enable(address(other), 9999);

        (address[] memory owners, bool[] memory shouldAdd) = _owners();
        vm.expectRevert(abi.encodeWithSelector(IOwnershipBridgeSender.PeerNotConfigured.selector, uint32(9999)));
        other.publishConfigureOwners(owners, shouldAdd, 2);
    }

    // ---- Fee handling ----

    function test_publish_revertsWhen_insufficientFee() public {
        endpoint.setFee(1 ether);
        (address[] memory owners, bool[] memory shouldAdd) = _owners();
        vm.deal(address(safeCaller), 0.5 ether);

        vm.expectRevert(abi.encodeWithSelector(IOwnershipBridgeSender.InsufficientFee.selector, uint256(0.5 ether), uint256(1 ether)));
        safeCaller.publishConfigureOwners{value: 0.5 ether}(owners, shouldAdd, 2);
    }

    function test_publish_refundsExcess() public {
        endpoint.setFee(0.1 ether);
        (address[] memory owners, bool[] memory shouldAdd) = _owners();
        vm.deal(address(this), 1 ether);

        uint256 safeBefore = address(safeCaller).balance;
        uint256 endpointBefore = address(endpoint).balance;

        // Test contract sends 0.5 ETH via {value:}; safeCaller forwards it to sender;
        // sender spends 0.1 on LZ; refunds remaining 0.4 back to safeCaller (its msg.sender).
        safeCaller.publishConfigureOwners{value: 0.5 ether}(owners, shouldAdd, 2);

        assertEq(address(safeCaller).balance, safeBefore + 0.4 ether, "safe should net +0.4");
        assertEq(address(endpoint).balance, endpointBefore + 0.1 ether, "endpoint should net +0.1");
    }

    // ---- Array length validation ----

    function test_publishConfigureOwners_revertsWhen_lengthMismatch() public {
        address[] memory owners = new address[](2);
        owners[0] = address(0xA);
        owners[1] = address(0xB);
        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;

        vm.expectRevert(IOwnershipBridgeSender.ArrayLengthMismatch.selector);
        safeCaller.publishConfigureOwners(owners, shouldAdd, 2);
    }

    // ---- Pause / unpause ----

    function test_pause_pauserOnly() public {
        vm.expectRevert(RoleRegistryStub.NotPauser.selector);
        sender.pause();

        vm.prank(pauser);
        sender.pause();
    }

    function test_publish_revertsWhen_paused() public {
        vm.prank(pauser);
        sender.pause();

        (address[] memory owners, bool[] memory shouldAdd) = _owners();
        vm.expectRevert(); // Pausable.EnforcedPause()
        safeCaller.publishConfigureOwners(owners, shouldAdd, 2);
    }

    function test_unpause_unpauserOnly() public {
        vm.prank(pauser);
        sender.pause();

        vm.expectRevert(RoleRegistryStub.NotUnpauser.selector);
        sender.unpause();

        vm.prank(unpauser);
        sender.unpause();
    }

    // ---- Destination admin ----

    function test_configureDestination_ownerOnly() public {
        vm.expectRevert();
        sender.configureDestination(MAINNET_EID, "", false);
    }

    // ---- Enable / disabled-safe short-circuit ----

    function test_enable_revertsWhen_callerLacksRole() public {
        SafeCaller other = new SafeCaller(sender);
        dataProvider.setSafe(address(other), true);

        vm.expectRevert(IOwnershipBridgeSender.OnlyEtherFiWallet.selector);
        sender.enable(address(other), MAINNET_EID);
    }

    function test_enable_revertsWhen_safeNotRegistered() public {
        SafeCaller rogue = new SafeCaller(sender);
        // rogue isn't in dataProvider.

        vm.expectRevert(IOwnershipBridgeSender.NotEtherFiSafe.selector);
        vm.prank(etherFiWallet);
        sender.enable(address(rogue), MAINNET_EID);
    }

    function test_enable_revertsWhen_destNotConfigured() public {
        SafeCaller other = new SafeCaller(sender);
        dataProvider.setSafe(address(other), true);

        vm.expectRevert(abi.encodeWithSelector(IOwnershipBridgeSender.DestinationNotConfigured.selector, uint32(424242)));
        vm.prank(etherFiWallet);
        sender.enable(address(other), 424242);
    }

    function test_enable_isIdempotent() public {
        SafeCaller other = new SafeCaller(sender);
        dataProvider.setSafe(address(other), true);

        vm.startPrank(etherFiWallet);
        sender.enable(address(other), MAINNET_EID);
        sender.enable(address(other), MAINNET_EID); // second call should be a no-op
        vm.stopPrank();

        assertTrue(sender.isEnabled(address(other), MAINNET_EID));
        uint32[] memory eids = sender.getEnabledDestinations(address(other));
        assertEq(eids.length, 1);
        assertEq(uint256(eids[0]), uint256(MAINNET_EID));
    }

    function test_enable_perDestEid() public {
        SafeCaller other = new SafeCaller(sender);
        dataProvider.setSafe(address(other), true);
        // Configure a second destination so we can enable for both.
        uint32 ARB_EID = 30_110;
        vm.startPrank(delegate);
        sender.setPeer(ARB_EID, bytes32(uint256(uint160(receiverPeer))));
        sender.configureDestination(ARB_EID, "", true);
        vm.stopPrank();

        vm.startPrank(etherFiWallet);
        sender.enable(address(other), MAINNET_EID);
        // Enabling for one destination must not enable for another.
        assertTrue(sender.isEnabled(address(other), MAINNET_EID));
        assertFalse(sender.isEnabled(address(other), ARB_EID));

        sender.enable(address(other), ARB_EID);
        vm.stopPrank();

        assertTrue(sender.isEnabled(address(other), ARB_EID));
        uint32[] memory eids = sender.getEnabledDestinations(address(other));
        assertEq(eids.length, 2);
    }

    function test_publish_skipsAndRefunds_whenNotEnabled() public {
        SafeCaller other = new SafeCaller(sender);
        dataProvider.setSafe(address(other), true);
        // NOT enabling.

        endpoint.setFee(0.1 ether);
        (address[] memory owners, bool[] memory shouldAdd) = _owners();
        vm.deal(address(this), 1 ether);

        uint256 otherBefore = address(other).balance;
        uint256 endpointBefore = address(endpoint).balance;

        other.publishConfigureOwners{value: 0.5 ether}(owners, shouldAdd, 2);

        assertEq(address(other).balance, otherBefore + 0.5 ether, "full msg.value refunded");
        assertEq(address(endpoint).balance, endpointBefore, "endpoint should be untouched");
    }

    function test_isPublishLive_reflectsState() public {
        SafeCaller other = new SafeCaller(sender);
        dataProvider.setSafe(address(other), true);

        assertFalse(sender.isPublishLive(address(other)), "not enabled yet");

        vm.prank(etherFiWallet);
        sender.enable(address(other), MAINNET_EID);
        assertTrue(sender.isPublishLive(address(other)), "enabled + not paused");

        vm.prank(pauser);
        sender.pause();
        assertFalse(sender.isPublishLive(address(other)), "paused");

        vm.prank(unpauser);
        sender.unpause();
        assertTrue(sender.isPublishLive(address(other)), "unpaused, still enabled");
    }

    // ---- Destination admin ----

    function test_configureDestination_addAndRemove() public {
        vm.startPrank(delegate);

        // Already has MAINNET_EID from setUp.
        uint32[] memory dests = sender.getDestinations();
        assertEq(dests.length, 1);
        assertEq(uint256(dests[0]), uint256(MAINNET_EID));

        // Add a second.
        sender.configureDestination(42_161, hex"01", true);
        dests = sender.getDestinations();
        assertEq(dests.length, 2);

        // Remove the first; the second should swap into its slot.
        sender.configureDestination(MAINNET_EID, "", false);
        dests = sender.getDestinations();
        assertEq(dests.length, 1);
        assertEq(uint256(dests[0]), uint256(42_161));

        vm.stopPrank();
    }
}
