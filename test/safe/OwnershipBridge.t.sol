// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IOwnershipBridgeSender } from "../../src/interfaces/IOwnershipBridgeSender.sol";
import { OwnershipBridgeMessageLib } from "../../src/libraries/OwnershipBridgeMessageLib.sol";
import { OwnershipBridgeSender } from "../../src/ownership-bridge/OwnershipBridgeSender.sol";
import { OwnerBridgePublisher } from "../../src/safe/OwnerBridgePublisher.sol";
import { LZEndpointMock } from "../mocks/LZEndpointMock.sol";
import { SafeTestSetup } from "./SafeTestSetup.t.sol";

/// @notice The four owner-mutating EtherFiSafe entrypoints must call the matching
///         `publish*` on `OwnershipBridgeSender` after applying the local change. Tests cover
///         both the wired path (sender configured) and the no-bridge path (sender unset).
contract OwnershipBridgeTest is SafeTestSetup {
    OwnershipBridgeSender public bridgeSender;
    LZEndpointMock public lzEndpoint;
    address public lzDelegate = makeAddr("lzDelegate");
    address public receiverPeer = makeAddr("receiverPeer");
    uint32 public constant MAINNET_EID = 30_101;

    receive() external payable {}

    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);
        lzEndpoint = new LZEndpointMock();
        bridgeSender = new OwnershipBridgeSender(address(dataProvider), address(lzEndpoint), lzDelegate);
        vm.stopPrank();

        vm.startPrank(lzDelegate);
        bridgeSender.setPeer(MAINNET_EID, bytes32(uint256(uint160(receiverPeer))));
        bridgeSender.configureDestination(MAINNET_EID, "", true);
        vm.stopPrank();

        // Grant the safe the wallet role so it can enable itself for the destination.
        vm.startPrank(owner);
        roleRegistry.grantRole(bridgeSender.ETHER_FI_WALLET_ROLE(), etherFiWallet);
        vm.stopPrank();

        vm.prank(etherFiWallet);
        bridgeSender.enable(address(safe), MAINNET_EID);
    }

    function _wireSenderOnDataProvider() internal {
        vm.prank(owner);
        dataProvider.setOwnershipBridgeSender(address(bridgeSender));
    }

    function test_setThreshold_publishesToLZ_whenSenderWired() public {
        _wireSenderOnDataProvider();

        uint8 newThreshold = 3;
        bytes32 structHash = keccak256(abi.encode(safe.SET_THRESHOLD_TYPEHASH(), newThreshold, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        safe.setThreshold(newThreshold, signers, signatures);

        assertEq(safe.getThreshold(), newThreshold, "local threshold updated");
        (uint32 dstEid, bytes memory message) = lzEndpoint.lastSendArgs();
        assertEq(uint256(dstEid), uint256(MAINNET_EID));
        (uint8 kind, address envSafe, ) = abi.decode(message, (uint8, address, bytes));
        assertEq(kind, uint8(OwnershipBridgeMessageLib.OpKind.SetThreshold));
        assertEq(envSafe, address(safe));
    }

    function test_configureOwners_publishesToLZ_whenSenderWired() public {
        _wireSenderOnDataProvider();
        address newOwner = makeAddr("newOwner");
        _signAndCallConfigureOwners(newOwner, true, 2);

        assertTrue(safe.isOwner(newOwner), "local owner added");
        (uint32 dstEid, bytes memory message) = lzEndpoint.lastSendArgs();
        assertEq(uint256(dstEid), uint256(MAINNET_EID));
        (uint8 kind, address envSafe, ) = abi.decode(message, (uint8, address, bytes));
        assertEq(kind, uint8(OwnershipBridgeMessageLib.OpKind.ConfigureOwners));
        assertEq(envSafe, address(safe));
    }

    function _signAndCallConfigureOwners(address newOwner, bool addFlag, uint8 newThreshold) internal {
        address[] memory ownersArr = new address[](1);
        ownersArr[0] = newOwner;
        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = addFlag;
        (address[] memory signers, bytes[] memory signatures) = _signConfigureOwners(ownersArr, shouldAdd, newThreshold);
        safe.configureOwners(ownersArr, shouldAdd, newThreshold, signers, signatures);
    }

    function _signConfigureOwners(address[] memory ownersArr, bool[] memory shouldAdd, uint8 newThreshold)
        internal
        view
        returns (address[] memory signers, bytes[] memory signatures)
    {
        bytes32 digestHash = keccak256(abi.encodePacked(
            "\x19\x01",
            safe.getDomainSeparator(),
            keccak256(abi.encode(
                safe.CONFIGURE_OWNERS_TYPEHASH(),
                keccak256(abi.encodePacked(ownersArr)),
                keccak256(abi.encodePacked(shouldAdd)),
                newThreshold,
                safe.nonce()
            ))
        ));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);
        signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;
    }

    function test_recoverSafe_publishesToLZ_andForwardsIncomingOwnerEffectiveAt() public {
        _wireSenderOnDataProvider();

        address newOwner = makeAddr("newOwner");
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;

        _recoverSafeWithSigners(newOwner, recoverySigners);

        uint256 expectedEffectiveAt = block.timestamp + dataProvider.getRecoveryDelayPeriod();
        assertEq(safe.getIncomingOwner(), newOwner, "local incoming owner");
        assertEq(safe.getIncomingOwnerStartTime(), expectedEffectiveAt, "local start time");

        (uint8 kind, address envSafe, bytes memory opData) = abi.decode(lzEndpoint.lastMessage(), (uint8, address, bytes));
        assertEq(kind, uint8(OwnershipBridgeMessageLib.OpKind.Recover));
        assertEq(envSafe, address(safe));
        (address publishedOwner, uint256 publishedEffectiveAt) = abi.decode(opData, (address, uint256));
        assertEq(publishedOwner, newOwner);
        assertEq(publishedEffectiveAt, expectedEffectiveAt, "destination timelock target matches source");
    }

    function test_cancelRecovery_publishesToLZ_whenSenderWired() public {
        _wireSenderOnDataProvider();

        // Stage a recovery first so cancellation has something to cancel locally.
        address newOwner = makeAddr("newOwner");
        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;
        _recoverSafeWithSigners(newOwner, recoverySigners);

        _cancelRecovery();

        assertEq(safe.getIncomingOwner(), address(0), "local cancellation applied");
        (uint8 kind, address envSafe, ) = abi.decode(lzEndpoint.lastMessage(), (uint8, address, bytes));
        assertEq(kind, uint8(OwnershipBridgeMessageLib.OpKind.CancelRecovery));
        assertEq(envSafe, address(safe));
    }

    // ---- Insufficient fee revert ----

    function test_setThreshold_revertsWhen_msgValueBelowQuote() public {
        _wireSenderOnDataProvider();
        lzEndpoint.setFee(0.2 ether);

        uint8 newThreshold = 3;
        bytes32 structHash = keccak256(abi.encode(safe.SET_THRESHOLD_TYPEHASH(), newThreshold, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(OwnerBridgePublisher.InsufficientBridgeFee.selector, uint256(0.1 ether), uint256(0.2 ether)));
        safe.setThreshold{ value: 0.1 ether }(newThreshold, signers, signatures);
    }

    // ---- Publish-not-live: sender configured but safe not enabled → full refund, no LZ touch ----

    function test_setThreshold_refundsFullValue_whenSafeNotEnabled() public {
        _wireSenderOnDataProvider();
        // Disable this safe at the sender so isPublishLive(safe) returns false.
        vm.prank(lzDelegate);
        bridgeSender.configureDestination(MAINNET_EID, "", false);
        // (the safe is still in enabledEids but the destination is gone — actually
        // isPublishLive only checks the enabled-set length and pause state, so we need to
        // use a separate safe that was never enabled. Reset by re-enabling and using a
        // different setup instead — but for this test, easier: pause the sender, which
        // also flips isPublishLive.)
        vm.prank(lzDelegate);
        bridgeSender.configureDestination(MAINNET_EID, "", true);

        // Use a fresh safe that was never enabled at the sender.
        bytes32 salt = keccak256("unenabledSafe");
        address[] memory newOwners = new address[](1);
        newOwners[0] = owner1;
        address[] memory mods = new address[](2);
        mods[0] = module1;
        mods[1] = module2;
        bytes[] memory setupData = new bytes[](2);

        vm.prank(owner);
        safeFactory.deployEtherFiSafe(salt, newOwners, mods, setupData, 1);
        address unenabledSafeAddr = safeFactory.getDeterministicAddress(salt);

        // Sanity: bridge is not live for the un-enabled safe.
        assertFalse(bridgeSender.isPublishLive(unenabledSafeAddr));

        uint8 newThreshold = 1;
        bytes32 typeHash = safe.SET_THRESHOLD_TYPEHASH();
        bytes32 domSep = _domainSeparatorOf(unenabledSafeAddr);
        uint256 unenabledNonce = _nonceOf(unenabledSafeAddr);
        bytes32 structHash = keccak256(abi.encode(typeHash, newThreshold, unenabledNonce));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", domSep, structHash));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        address[] memory signers = new address[](1);
        signers[0] = owner1;

        vm.deal(address(this), 1 ether);
        uint256 callerBefore = address(this).balance;
        uint256 endpointBefore = address(lzEndpoint).balance;

        (bool ok, ) = unenabledSafeAddr.call{ value: 0.3 ether }(
            abi.encodeWithSignature("setThreshold(uint8,address[],bytes[])", newThreshold, signers, signatures)
        );
        require(ok, "setThreshold failed");

        assertEq(address(this).balance, callerBefore, "caller fully refunded (not-live path)");
        assertEq(address(lzEndpoint).balance, endpointBefore, "endpoint untouched (no LZ send)");
    }

    function _domainSeparatorOf(address target) internal view returns (bytes32) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature("getDomainSeparator()"));
        require(ok, "getDomainSeparator failed");
        return abi.decode(ret, (bytes32));
    }

    function _nonceOf(address target) internal view returns (uint256) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature("nonce()"));
        require(ok, "nonce() failed");
        return abi.decode(ret, (uint256));
    }

    // ---- No-bridge path: sender not configured → publish skipped, msg.value refunded ----

    function test_setThreshold_refundsFullValue_whenSenderUnwired() public {
        // dataProvider.getOwnershipBridgeSender() returns 0 by default.
        uint8 newThreshold = 3;
        bytes32 structHash = keccak256(abi.encode(safe.SET_THRESHOLD_TYPEHASH(), newThreshold, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        vm.deal(address(this), 1 ether);
        uint256 callerBefore = address(this).balance;
        uint256 safeBefore = address(safe).balance;

        safe.setThreshold{ value: 0.3 ether }(newThreshold, signers, signatures);

        assertEq(safe.getThreshold(), newThreshold, "local threshold updated even without bridge");
        assertEq(address(this).balance, callerBefore, "caller fully refunded");
        assertEq(address(safe).balance, safeBefore, "safe holds no stranded ETH");
    }

    // ---- Wired path with non-zero LZ fee: leftover refunded to caller ----

    function test_setThreshold_refundsExcess_whenSenderWired() public {
        _wireSenderOnDataProvider();
        lzEndpoint.setFee(0.1 ether);

        uint8 newThreshold = 3;
        bytes32 structHash = keccak256(abi.encode(safe.SET_THRESHOLD_TYPEHASH(), newThreshold, safe.nonce()));
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        vm.deal(address(this), 1 ether);
        uint256 callerBefore = address(this).balance;
        uint256 endpointBefore = address(lzEndpoint).balance;

        safe.setThreshold{ value: 0.5 ether }(newThreshold, signers, signatures);

        // Caller spent only the 0.1 ETH LZ fee; 0.4 ETH refund propagated all the way back.
        assertEq(address(this).balance, callerBefore - 0.1 ether, "caller refunded leftover");
        assertEq(address(lzEndpoint).balance, endpointBefore + 0.1 ether, "endpoint received fee");
        assertEq(address(safe).balance, 0, "safe forwards refund, holds nothing");
    }

}
