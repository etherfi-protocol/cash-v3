// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeTestSetup } from "../../SafeTestSetup.t.sol";
import { UUPSProxy } from "../../../../src/UUPSProxy.sol";
import { IRecoveryModule } from "../../../../src/interfaces/IRecoveryModule.sol";
import { RecoveryModule } from "../../../../src/modules/recovery/RecoveryModule.sol";
import { ModuleBase } from "../../../../src/modules/ModuleBase.sol";
import { MockERC20 } from "../../../../src/mocks/MockERC20.sol";
import { LZEndpointMock } from "../../../mocks/LZEndpointMock.sol";

contract RecoveryModuleTest is SafeTestSetup {
    RecoveryModule public module;
    LZEndpointMock public lzEndpoint;
    MockERC20 public token;
    address public safeAddr;

    address public dispatcher = makeAddr("dispatcher");
    uint32 public constant ARB_EID = 30_110;

    function setUp() public override {
        super.setUp();

        safeAddr = address(safe);

        vm.startPrank(owner);

        // 1. Deploy LZ endpoint mock
        lzEndpoint = new LZEndpointMock();

        // 2. Deploy RecoveryModule implementation + proxy
        address moduleImpl = address(new RecoveryModule(address(dataProvider), address(lzEndpoint)));
        module = RecoveryModule(address(new UUPSProxy(moduleImpl, abi.encodeWithSelector(RecoveryModule.initialize.selector, owner))));

        // 3. Wire peer so destEid validation inside requestRecovery passes
        module.setPeer(ARB_EID, bytes32(uint256(uint160(dispatcher))));

        // 4. Whitelist the module globally on the data provider
        address[] memory modules = new address[](1);
        modules[0] = address(module);
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;
        dataProvider.configureModules(modules, shouldWhitelist);

        // 5. Attach the module to the safe (threshold=2 quorum is handled by _configureModules helper)
        bytes[] memory moduleSetupData = new bytes[](1);
        moduleSetupData[0] = "";
        _configureModules(modules, shouldWhitelist, moduleSetupData);

        // 6. Deploy a test ERC20 (not used by Task 6 semantics yet, but kept for digest coverage)
        token = new MockERC20("Mock", "MOCK", 18);

        vm.stopPrank();
    }

    function test_requestRecovery_happyPath() public {
        uint256 amount = 1e18;
        address recipient = makeAddr("recipient");
        uint32 destEid = ARB_EID;

        // Digest must mirror exactly what requestRecovery computes. `_useNonce` is a
        // post-increment; the value embedded in the digest equals `getNonce(safe)` before the call.
        uint256 nonce = module.getNonce(safeAddr);
        bytes32 digest = keccak256(abi.encode(
            block.chainid,
            address(module),
            nonce,
            safeAddr,
            address(token),
            amount,
            recipient,
            destEid
        ));

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signDigest(owner1Pk, digest);
        sigs[1] = _signDigest(owner2Pk, digest);

        // The recoveryNonce used to derive the id is the per-safe counter in RecoveryModuleStorage,
        // which starts at 0 and is post-incremented inside requestRecovery.
        bytes32 expectedId = keccak256(abi.encode(safeAddr, uint256(0)));
        uint64 expectedUnlockAt = uint64(block.timestamp) + module.TIMELOCK();

        vm.expectEmit(true, true, true, true);
        emit IRecoveryModule.RecoveryRequested(safeAddr, expectedId, address(token), amount, recipient, destEid, expectedUnlockAt);
        bytes32 id = module.requestRecovery(safeAddr, address(token), amount, recipient, destEid, signers, sigs);

        assertEq(id, expectedId, "id mismatch");

        IRecoveryModule.PendingRecovery memory pr = module.getRecovery(safeAddr, id);
        assertEq(pr.token, address(token), "token mismatch");
        assertEq(pr.amount, amount, "amount mismatch");
        assertEq(pr.recipient, recipient, "recipient mismatch");
        assertEq(uint256(pr.destEid), uint256(destEid), "destEid mismatch");
        assertEq(uint256(pr.unlockAt), uint256(expectedUnlockAt), "unlockAt mismatch");
        assertFalse(pr.executed, "should not be executed");
        assertFalse(pr.cancelled, "should not be cancelled");
    }

    function test_executeRecovery_revertsBeforeUnlock() public {
        bytes32 id = _createPending(address(token), 1e18, makeAddr("recipient"), ARB_EID);
        vm.deal(owner1, 1 ether);
        vm.prank(owner1);
        vm.expectRevert(IRecoveryModule.RecoveryStillLocked.selector);
        module.executeRecovery{value: 1e15}(safeAddr, id, "");
    }

    function test_executeRecovery_sendsLzMessageAfterUnlock() public {
        address recipient = makeAddr("recipient");
        bytes32 id = _createPending(address(token), 1e18, recipient, ARB_EID);

        skip(3 days + 1);

        vm.deal(owner1, 1 ether);

        vm.prank(owner1);
        module.executeRecovery{value: 1e15}(safeAddr, id, "");

        // Assert stored state flipped to executed
        IRecoveryModule.PendingRecovery memory pr = module.getRecovery(safeAddr, id);
        assertTrue(pr.executed, "should be executed");

        // Assert LZ mock captured a send with expected params
        (uint32 dstEid, bytes memory message) = lzEndpoint.lastSendArgs();
        assertEq(uint256(dstEid), uint256(ARB_EID), "destEid mismatch");
        (address payloadSafe, address payloadToken, uint256 payloadAmount, address payloadRecipient) =
            abi.decode(message, (address, address, uint256, address));
        assertEq(payloadSafe, safeAddr, "payload safe mismatch");
        assertEq(payloadToken, address(token), "payload token mismatch");
        assertEq(payloadAmount, 1e18, "payload amount mismatch");
        assertEq(payloadRecipient, recipient, "payload recipient mismatch");
    }

    function test_executeRecovery_revertsIfAlreadyExecuted() public {
        bytes32 id = _createPending(address(token), 1e18, makeAddr("recipient"), ARB_EID);
        skip(3 days + 1);
        vm.deal(owner1, 1 ether);
        vm.prank(owner1);
        module.executeRecovery{value: 1e15}(safeAddr, id, "");
        vm.prank(owner1);
        vm.expectRevert(IRecoveryModule.RecoveryAlreadyFinalized.selector);
        module.executeRecovery{value: 1e15}(safeAddr, id, "");
    }

    function test_executeRecovery_revertsIfNotFound() public {
        bytes32 fakeId = keccak256("not a real id");
        vm.deal(owner1, 1 ether);
        vm.prank(owner1);
        vm.expectRevert(IRecoveryModule.RecoveryNotFound.selector);
        module.executeRecovery{value: 1e15}(safeAddr, fakeId, "");
    }

    /// @dev Creates a pending recovery by calling `requestRecovery` with 2/2 owner sigs.
    ///      Uses the live per-safe nonce so the helper is safe to call multiple times per test.
    function _createPending(address token_, uint256 amount, address recipient, uint32 destEid)
        internal
        returns (bytes32 id)
    {
        uint256 nonce = module.getNonce(safeAddr);
        bytes32 digest = keccak256(abi.encode(
            block.chainid,
            address(module),
            nonce,
            safeAddr,
            token_,
            amount,
            recipient,
            destEid
        ));

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signDigest(owner1Pk, digest);
        sigs[1] = _signDigest(owner2Pk, digest);

        id = module.requestRecovery(safeAddr, token_, amount, recipient, destEid, signers, sigs);
    }

    function _signDigest(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_cancelRecovery_blocksExecution() public {
        bytes32 id = _createPending(address(token), 1e18, makeAddr("recipient"), ARB_EID);

        // owner1 + owner2 sign the cancel digest
        bytes32 digest = keccak256(abi.encode(
            "cancel",
            block.chainid,
            address(module),
            module.getNonce(safeAddr),
            safeAddr,
            id
        ));
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signDigest(owner1Pk, digest);
        sigs[1] = _signDigest(owner2Pk, digest);

        module.cancelRecovery(safeAddr, id, signers, sigs);

        skip(3 days + 1);
        vm.deal(owner1, 1 ether);
        vm.prank(owner1);
        vm.expectRevert(IRecoveryModule.RecoveryAlreadyFinalized.selector);
        module.executeRecovery{value: 1e15}(safeAddr, id, "");
    }

    function test_pause_blocksRequestAndExecute() public {
        // `pauser` (from SafeTestSetup) already holds the PAUSER role.
        vm.prank(pauser);
        module.pause();

        // Pre-compute digest + sigs so the NEXT external call is the paused one.
        address recipient = makeAddr("recipient");
        uint256 nonce = module.getNonce(safeAddr);
        bytes32 digest = keccak256(abi.encode(
            block.chainid,
            address(module),
            nonce,
            safeAddr,
            address(token),
            uint256(1e18),
            recipient,
            ARB_EID
        ));
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signDigest(owner1Pk, digest);
        sigs[1] = _signDigest(owner2Pk, digest);

        vm.expectRevert();
        module.requestRecovery(safeAddr, address(token), 1e18, recipient, ARB_EID, signers, sigs);

        // Unpause, create, repause, try to execute
        vm.prank(unpauser);
        module.unpause();
        bytes32 id = _createPending(address(token), 1e18, recipient, ARB_EID);
        skip(3 days + 1);
        vm.prank(pauser);
        module.pause();

        vm.deal(owner1, 1 ether);
        vm.prank(owner1);
        vm.expectRevert();
        module.executeRecovery{value: 1e15}(safeAddr, id, "");
    }

    function test_pause_onlyPauser() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        module.pause();
    }

    function test_requestRecovery_revertsIfTokenZero() public {
        uint256 amount = 1e18;
        address recipient = makeAddr("recipient");
        uint32 destEid = ARB_EID;

        bytes32 digest = keccak256(abi.encode(
            block.chainid,
            address(module),
            module.getNonce(safeAddr),
            safeAddr,
            address(0),
            amount,
            recipient,
            destEid
        ));
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signDigest(owner1Pk, digest);
        sigs[1] = _signDigest(owner2Pk, digest);

        vm.expectRevert(IRecoveryModule.InvalidToken.selector);
        module.requestRecovery(safeAddr, address(0), amount, recipient, destEid, signers, sigs);
    }

    function test_requestRecovery_revertsIfPeerUnset() public {
        // Unset peer for ARB_EID — `module.owner()` is `owner` (from SafeTestSetup.setUp).
        vm.prank(module.owner());
        module.setPeer(ARB_EID, bytes32(0));

        bytes32 digest = keccak256(abi.encode(
            block.chainid,
            address(module),
            module.getNonce(safeAddr),
            safeAddr,
            address(token),
            uint256(1e18),
            makeAddr("recipient"),
            ARB_EID
        ));
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signDigest(owner1Pk, digest);
        sigs[1] = _signDigest(owner2Pk, digest);

        vm.expectRevert(IRecoveryModule.InvalidDestEid.selector);
        module.requestRecovery(safeAddr, address(token), 1e18, makeAddr("recipient"), ARB_EID, signers, sigs);
    }

    function test_quoteExecute_returnsEndpointQuote() public {
        bytes32 id = _createPending(address(token), 1e18, makeAddr("recipient"), ARB_EID);
        // LZEndpointMock returns (0, 0); the call path is what we're exercising.
        uint256 fee = module.quoteExecute(safeAddr, id, "");
        assertEq(fee, 0, "mock endpoint returns zero fee");
    }

    function test_quoteExecute_revertsIfNotFound() public {
        vm.expectRevert(IRecoveryModule.RecoveryNotFound.selector);
        module.quoteExecute(safeAddr, keccak256("missing"), "");
    }

    function test_cancelRecovery_worksWhilePaused() public {
        // Cancel must remain callable while paused so owners can abort in-flight requests
        // even if the module is frozen.
        bytes32 id = _createPending(address(token), 1e18, makeAddr("recipient"), ARB_EID);

        vm.prank(pauser);
        module.pause();

        bytes32 digest = keccak256(abi.encode(
            "cancel",
            block.chainid,
            address(module),
            module.getNonce(safeAddr),
            safeAddr,
            id
        ));
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signDigest(owner1Pk, digest);
        sigs[1] = _signDigest(owner2Pk, digest);

        module.cancelRecovery(safeAddr, id, signers, sigs);

        IRecoveryModule.PendingRecovery memory pr = module.getRecovery(safeAddr, id);
        assertTrue(pr.cancelled, "cancel should succeed while paused");
    }

    function test_requestRecovery_digestReplayReverts() public {
        // The per-safe nonce is baked into the digest; re-submitting a signed digest with
        // a stale nonce must fail signature verification.
        address recipient = makeAddr("recipient");
        uint256 amount = 1e18;
        uint256 nonce = module.getNonce(safeAddr);
        bytes32 digest = keccak256(abi.encode(
            block.chainid,
            address(module),
            nonce,
            safeAddr,
            address(token),
            amount,
            recipient,
            ARB_EID
        ));
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signDigest(owner1Pk, digest);
        sigs[1] = _signDigest(owner2Pk, digest);

        module.requestRecovery(safeAddr, address(token), amount, recipient, ARB_EID, signers, sigs);

        // Re-submit the same signed digest — nonce has advanced, digest no longer matches.
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        module.requestRecovery(safeAddr, address(token), amount, recipient, ARB_EID, signers, sigs);
    }
}
