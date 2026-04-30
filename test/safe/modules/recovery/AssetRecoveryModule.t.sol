// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OAppSender } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import { Vm } from "forge-std/Vm.sol";

import { SafeTestSetup } from "../../SafeTestSetup.t.sol";
import { IAssetRecoveryModule } from "../../../../src/interfaces/IAssetRecoveryModule.sol";
import { AssetRecoveryModule } from "../../../../src/modules/recovery/AssetRecoveryModule.sol";
import { ModuleBase } from "../../../../src/modules/ModuleBase.sol";
import { RoleRegistry } from "../../../../src/role-registry/RoleRegistry.sol";
import { MockERC20 } from "../../../../src/mocks/MockERC20.sol";
import { LZEndpointMock } from "../../../mocks/LZEndpointMock.sol";

/// @dev Helper that calls `recover` from a non-payable context so we can prove `_payNative`'s
///      refund branch reverts when the caller cannot accept ETH.
contract NonPayableCaller {
    AssetRecoveryModule public immutable module;

    constructor(AssetRecoveryModule _module) {
        module = _module;
    }

    /// @dev Forwards `value` and the recovery args to the module. No `receive`/`fallback`,
    ///      so any refund attempt by `_payNative` reverts.
    function callRecover(
        address safe,
        address token,
        address recipient,
        uint32 destEid,
        bytes calldata lzOptions,
        address[] calldata signers,
        bytes[] calldata sigs
    ) external payable returns (bytes32) {
        return module.recover{value: msg.value}(safe, token, recipient, destEid, lzOptions, signers, sigs);
    }
}

contract AssetRecoveryModuleTest is SafeTestSetup {
    AssetRecoveryModule public module;
    LZEndpointMock public lzEndpoint;
    MockERC20 public token;
    address public safeAddr;

    address public dispatcher = makeAddr("dispatcher");
    uint32 public constant ARB_EID = 30_110;

    function setUp() public override {
        super.setUp();

        safeAddr = address(safe);

        vm.startPrank(owner);

        lzEndpoint = new LZEndpointMock();

        module = new AssetRecoveryModule(address(dataProvider), address(lzEndpoint), owner);

        module.setPeer(ARB_EID, bytes32(uint256(uint160(dispatcher))));

        address[] memory modules = new address[](1);
        modules[0] = address(module);
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;
        dataProvider.configureModules(modules, shouldWhitelist);

        bytes[] memory moduleSetupData = new bytes[](1);
        moduleSetupData[0] = "";
        _configureModules(modules, shouldWhitelist, moduleSetupData);

        token = new MockERC20("Mock", "MOCK", 18);

        vm.stopPrank();
    }

    function test_recover_happyPath_emitsRecoverySentAndDispatchesLz() public {
        address recipient = makeAddr("recipient");
        uint32 destEid = ARB_EID;

        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(token), recipient, destEid);

        vm.deal(owner1, 1 ether);
        // Assert the full RecoverySent event. lzGuid is a runtime-computed indexed topic, so we
        // can't pre-compute it here — but that's fine: expectEmit checks all four topics + data
        // against whatever the call actually emits.
        vm.recordLogs();
        vm.prank(owner1);
        bytes32 lzGuid = module.recover{value: 1e15}(
            safeAddr, address(token), recipient, destEid, "", signers, sigs
        );
        assertTrue(lzGuid != bytes32(0), "guid should be non-zero");

        // Locate the RecoverySent log and verify its topics + data.
        bytes32 recoverySentTopic = keccak256("RecoverySent(address,bytes32,address,address,uint32)");
        bool found;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(module) && logs[i].topics[0] == recoverySentTopic) {
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(safeAddr))), "topic safe");
                assertEq(logs[i].topics[2], lzGuid, "topic lzGuid");
                assertEq(logs[i].topics[3], bytes32(uint256(uint160(address(token)))), "topic token");
                (address dataRecipient, uint32 dataDestEid) = abi.decode(logs[i].data, (address, uint32));
                assertEq(dataRecipient, recipient, "data recipient");
                assertEq(uint256(dataDestEid), uint256(destEid), "data destEid");
                found = true;
                break;
            }
        }
        assertTrue(found, "RecoverySent not emitted");

        (uint32 dstEid, bytes memory message) = lzEndpoint.lastSendArgs();
        assertEq(uint256(dstEid), uint256(destEid), "destEid mismatch");
        (address payloadSafe, address payloadToken, address payloadRecipient) =
            abi.decode(message, (address, address, address));
        assertEq(payloadSafe, safeAddr, "payload safe mismatch");
        assertEq(payloadToken, address(token), "payload token mismatch");
        assertEq(payloadRecipient, recipient, "payload recipient mismatch");
    }

    function test_recover_revertsIfTokenZero() public {
        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(0), makeAddr("recipient"), ARB_EID);
        vm.deal(owner1, 1 ether);
        vm.prank(owner1);
        vm.expectRevert(IAssetRecoveryModule.InvalidToken.selector);
        module.recover{value: 1e15}(safeAddr, address(0), makeAddr("recipient"), ARB_EID, "", signers, sigs);
    }

    function test_recover_revertsIfRecipientZero() public {
        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(token), address(0), ARB_EID);
        vm.deal(owner1, 1 ether);
        vm.prank(owner1);
        vm.expectRevert(IAssetRecoveryModule.InvalidRecipient.selector);
        module.recover{value: 1e15}(safeAddr, address(token), address(0), ARB_EID, "", signers, sigs);
    }

    function test_recover_revertsIfPeerUnset() public {
        vm.prank(module.owner());
        module.setPeer(ARB_EID, bytes32(0));

        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(token), makeAddr("recipient"), ARB_EID);
        vm.deal(owner1, 1 ether);
        vm.prank(owner1);
        vm.expectRevert(IAssetRecoveryModule.InvalidDestEid.selector);
        module.recover{value: 1e15}(safeAddr, address(token), makeAddr("recipient"), ARB_EID, "", signers, sigs);
    }

    function test_recover_revertsIfBadSignature() public {
        // Owners sign over a different recipient — checkSignatures rejects.
        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(token), makeAddr("recipient"), ARB_EID);
        vm.deal(owner1, 1 ether);
        vm.prank(owner1);
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        module.recover{value: 1e15}(safeAddr, address(token), makeAddr("differentRecipient"), ARB_EID, "", signers, sigs);
    }

    function test_recover_digestReplayReverts() public {
        address recipient = makeAddr("recipient");
        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(token), recipient, ARB_EID);

        vm.deal(owner1, 1 ether);
        vm.startPrank(owner1);
        module.recover{value: 1e15}(safeAddr, address(token), recipient, ARB_EID, "", signers, sigs);

        // Replay with same sigs — nonce has advanced, digest no longer matches.
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        module.recover{value: 1e15}(safeAddr, address(token), recipient, ARB_EID, "", signers, sigs);
        vm.stopPrank();
    }

    function test_recover_revertsIfLzOptionsMismatch() public {
        // Owners sign for one set of lzOptions; submitter swaps in different options.
        // Digest binding on `keccak256(lzOptions)` must reject this.
        bytes memory signedOptions = hex"00030100110100000000000000000000000000030d40";
        bytes memory submittedOptions = hex"00030100110100000000000000000000000000000001";

        (address[] memory signers, bytes[] memory sigs) =
            _signRecoverWithOptions(address(token), makeAddr("recipient"), ARB_EID, signedOptions);

        vm.deal(owner1, 1 ether);
        vm.prank(owner1);
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        module.recover{value: 1e15}(
            safeAddr, address(token), makeAddr("recipient"), ARB_EID, submittedOptions, signers, sigs
        );
    }

    function test_recover_revertsWhenPaused() public {
        vm.prank(pauser);
        module.pause();

        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(token), makeAddr("recipient"), ARB_EID);
        vm.deal(owner1, 1 ether);
        vm.prank(owner1);
        // Pinned to OZ Pausable's `EnforcedPause()` — `whenNotPaused` is the first guard.
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        module.recover{value: 1e15}(safeAddr, address(token), makeAddr("recipient"), ARB_EID, "", signers, sigs);
    }

    function test_pause_onlyPauser() public {
        vm.prank(makeAddr("random"));
        // Pinned to RoleRegistry.OnlyPauser via `_roleRegistry().onlyPauser(msg.sender)`.
        vm.expectRevert(RoleRegistry.OnlyPauser.selector);
        module.pause();
    }

    function test_recover_revertsOnFeeUnderpay() public {
        lzEndpoint.setFee(0.1 ether);

        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(token), makeAddr("recipient"), ARB_EID);
        vm.deal(owner1, 1 ether);
        vm.prank(owner1);
        // OAppSender._payNative reverts with `NotEnoughNative(uint256)` when msg.value < fee.
        // Our override pins to the same selector.
        vm.expectRevert(abi.encodeWithSelector(OAppSender.NotEnoughNative.selector, 0.05 ether));
        module.recover{value: 0.05 ether}(
            safeAddr, address(token), makeAddr("recipient"), ARB_EID, "", signers, sigs
        );
    }

    function test_recover_refundsExcessOnOverpay() public {
        lzEndpoint.setFee(0.1 ether);
        address recipient = makeAddr("recipient");
        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(token), recipient, ARB_EID);

        vm.deal(owner1, 1 ether);
        uint256 startBal = owner1.balance;

        vm.prank(owner1);
        module.recover{value: 0.5 ether}(safeAddr, address(token), recipient, ARB_EID, "", signers, sigs);

        // 0.4 ether refunded; net cost = 0.1 ether (the quoted fee).
        assertEq(owner1.balance, startBal - 0.1 ether, "should be charged exactly the fee");
    }

    function test_recover_refundFails_whenSenderNotPayable() public {
        lzEndpoint.setFee(0.1 ether);
        address recipient = makeAddr("recipient");

        NonPayableCaller caller = new NonPayableCaller(module);
        vm.deal(address(caller), 1 ether);

        // Sigs are over the digest with the *non-payable contract* as the nonce-bound caller? No —
        // the digest in this module does not bind msg.sender, only safe/token/recipient/destEid/options.
        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(token), recipient, ARB_EID);

        vm.expectRevert(IAssetRecoveryModule.RefundFailed.selector);
        caller.callRecover{value: 0.5 ether}(
            safeAddr, address(token), recipient, ARB_EID, "", signers, sigs
        );
    }

    function _signRecover(address token_, address recipient, uint32 destEid)
        internal
        view
        returns (address[] memory signers, bytes[] memory sigs)
    {
        return _signRecoverWithOptions(token_, recipient, destEid, "");
    }

    function _signRecoverWithOptions(
        address token_,
        address recipient,
        uint32 destEid,
        bytes memory lzOptions
    ) internal view returns (address[] memory signers, bytes[] memory sigs) {
        bytes32 digest = keccak256(abi.encode(
            block.chainid,
            address(module),
            module.getNonce(safeAddr),
            safeAddr,
            token_,
            recipient,
            destEid,
            keccak256(lzOptions)
        ));

        signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        sigs = new bytes[](2);
        sigs[0] = _signDigest(owner1Pk, digest);
        sigs[1] = _signDigest(owner2Pk, digest);
    }

    function _signDigest(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
