// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { IWETH } from "../../src/interfaces/IWETH.sol";
import { ModuleBase } from "../../src/modules/ModuleBase.sol";
import { EtherFiSafe, EtherFiSafeErrors, SafeTestSetup } from "./SafeTestSetup.t.sol";

contract SafeWethAndErc1271Test is SafeTestSetup {
    bytes4 constant MAGIC = 0x1626ba7e;
    bytes4 constant INVALID = 0xffffffff;

    address weth;

    function setUp() public override {
        super.setUp();
        weth = safe.WETH();
    }

    // ── native ETH ──────────────────────────────────────────────────────────

    function test_receive_wrapsIncomingEth() public {
        (bool ok,) = address(safe).call{ value: 1 ether }("");

        assertTrue(ok);
        assertEq(address(safe).balance, 0);
        assertEq(IERC20(weth).balanceOf(address(safe)), 1 ether);
    }

    function test_wrapEth_sweepsBalanceThatBypassedReceive() public {
        deal(address(safe), 3 ether);

        safe.wrapEth();

        assertEq(address(safe).balance, 0);
        assertEq(IERC20(weth).balanceOf(address(safe)), 3 ether);
    }

    function test_wrapEth_isNoOpOnZeroBalance() public {
        safe.wrapEth();
        assertEq(IERC20(weth).balanceOf(address(safe)), 0);
    }

    /// @dev A callee reached mid-batch must not be able to wrap the native ETH the batch still needs.
    function test_wrapEth_isNoOpMidBatch() public {
        WrapCaller caller = new WrapCaller();
        deal(address(safe), 1 ether);

        address[] memory to = new address[](1);
        bytes[] memory data = new bytes[](1);
        to[0] = address(caller);
        data[0] = abi.encodeCall(WrapCaller.wrap, (address(safe)));

        vm.prank(address(cashModule));
        safe.execTransactionFromModule(to, new uint256[](1), data);

        assertEq(address(safe).balance, 1 ether);
        assertEq(IERC20(weth).balanceOf(address(safe)), 0);
    }

    /// @dev WETH9 unwraps on a 2300-gas stipend, far too little to re-wrap — AaveV3Module's ETH paths would revert.
    function test_receive_skipsWethSoUnwrapDoesNotRevert() public {
        deal(weth, address(safe), 2 ether);

        address[] memory to = new address[](1);
        bytes[] memory data = new bytes[](1);
        to[0] = weth;
        data[0] = abi.encodeWithSelector(IWETH.withdraw.selector, 2 ether);

        vm.prank(address(cashModule));
        safe.execTransactionFromModule(to, new uint256[](1), data);

        assertEq(address(safe).balance, 2 ether);
        assertEq(IERC20(weth).balanceOf(address(safe)), 0);

        safe.wrapEth();
        assertEq(IERC20(weth).balanceOf(address(safe)), 2 ether);
    }

    /// @dev EnsoSwapModule pre-funds its native fee, then spends it as call value in the batch that follows.
    function test_receive_passesThroughModulePreFunding() public {
        vm.deal(address(cashModule), 1 ether);

        vm.prank(address(cashModule));
        (bool ok,) = address(safe).call{ value: 1 ether }("");

        assertTrue(ok);
        assertEq(address(safe).balance, 1 ether);
        assertEq(IERC20(weth).balanceOf(address(safe)), 0);
    }

    /// @dev OpenOceanSwapModule reads its ETH output as a native balance delta across the batch.
    function test_receive_passesThroughEthArrivingMidBatch() public {
        EthBouncer bouncer = new EthBouncer();
        deal(address(safe), 1 ether);

        address[] memory to = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        to[0] = address(bouncer);
        values[0] = 1 ether;
        data[0] = abi.encodeCall(EthBouncer.bounce, ());

        assertFalse(safe.inModuleBatch());

        vm.prank(address(cashModule));
        safe.execTransactionFromModule(to, values, data);

        assertFalse(safe.inModuleBatch());
        assertEq(address(safe).balance, 1 ether);
        assertEq(IERC20(weth).balanceOf(address(safe)), 0);
    }

    /// @dev Known ceiling: nothing here stipend-sends to a safe, and `wrapEth` recovers it if anything does.
    function test_receive_revertsOnStipendSendFromNonWeth() public {
        StipendSender sender = new StipendSender();
        vm.deal(address(sender), 1 ether);

        vm.expectRevert();
        sender.send(payable(address(safe)), 1 ether);
    }

    // ── ERC-1271 ────────────────────────────────────────────────────────────

    function test_isValidSignature_acceptsOwnerSignedMessage() public view {
        bytes memory message = "ether.fi safe ownership proof";
        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(message);

        assertEq(safe.isValidSignature(hash, _blob(message, hash)), MAGIC);
    }

    function test_isValidSignature_rejectsMismatchedPreimage() public view {
        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(bytes("the real message"));

        assertEq(safe.isValidSignature(hash, _blob(bytes("a different message"), hash)), INVALID);
    }

    /// @dev The LendGateway invariant. Even holding threshold keys and supplying the digest's genuine keccak
    ///      preimage, the EIP-191 prefix makes it unreachable. Same argument covers Permit2 and Seaport.
    function test_isValidSignature_rejectsForeignEip712Digest() public view {
        bytes32 foreignDomain = keccak256("AaveV4Spoke");
        bytes32 structHash = keccak256("SetUserPositionManagers(address user,...)");
        bytes32 foreignDigest = keccak256(abi.encodePacked(hex"1901", foreignDomain, structHash));

        bytes memory preimage = abi.encodePacked(hex"1901", foreignDomain, structHash);
        assertEq(keccak256(preimage), foreignDigest, "preimage is genuine under plain keccak");

        assertEq(safe.isValidSignature(foreignDigest, _blob(preimage, foreignDigest)), INVALID);
    }

    // ── pause ───────────────────────────────────────────────────────────────

    /// @dev A pause turns wrapping off, it does not reject the transfer. Reverting here would brick
    ///      incoming ETH on every safe at once; passing through restores the exact pre-upgrade behaviour.
    function test_receive_passesThroughWhenPaused() public {
        vm.prank(pauser);
        dataProvider.pause();

        (bool ok,) = address(safe).call{ value: 1 ether }("");

        assertTrue(ok, "a paused wrapper must still accept ETH");
        assertEq(address(safe).balance, 1 ether);
        assertEq(IERC20(weth).balanceOf(address(safe)), 0);
    }

    /// @dev Unlike the mid-batch no-op, a pause is an operator action, so an explicit caller is told.
    function test_wrapEth_revertsWhenPaused() public {
        deal(address(safe), 1 ether);

        vm.prank(pauser);
        dataProvider.pause();

        vm.expectRevert(EtherFiSafeErrors.EthWrapPaused.selector);
        safe.wrapEth();
    }

    function test_wrapEth_sweepsWhatThePauseLetByAfterUnpause() public {
        vm.prank(pauser);
        dataProvider.pause();

        (bool ok,) = address(safe).call{ value: 1 ether }("");
        assertTrue(ok);
        assertEq(address(safe).balance, 1 ether);

        vm.prank(unpauser);
        dataProvider.unpause();

        safe.wrapEth();

        assertEq(address(safe).balance, 0);
        assertEq(IERC20(weth).balanceOf(address(safe)), 1 ether);
    }

    // ── events ──────────────────────────────────────────────────────────────

    function test_receive_emitsEthWrappedWhenWrapping() public {
        vm.expectEmit(true, true, true, true);
        emit EtherFiSafe.EthWrapped(address(this), 1 ether);

        (bool ok,) = address(safe).call{ value: 1 ether }("");
        assertTrue(ok);
    }

    /// @dev A pass-through changes nothing, so it logs nothing. The `wrapEth` that later sweeps it
    ///      is what carries the amount into the log.
    function test_receive_emitsNothingWhenPassingThrough() public {
        vm.deal(address(cashModule), 1 ether);

        vm.recordLogs();
        vm.prank(address(cashModule));
        (bool ok,) = address(safe).call{ value: 1 ether }("");

        assertTrue(ok);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_wrapEth_emitsEthWrapped() public {
        deal(address(safe), 2 ether);

        vm.expectEmit(true, true, true, true);
        emit EtherFiSafe.EthWrapped(address(this), 2 ether);

        safe.wrapEth();
    }

    /// @dev No event on the zero-balance path — nothing happened, so nothing is logged.
    function test_wrapEth_emitsNothingOnZeroBalance() public {
        vm.recordLogs();
        safe.wrapEth();
        assertEq(vm.getRecordedLogs().length, 0);
    }

    // ── nested batches ──────────────────────────────────────────────────────

    /// @dev The flag is restored, not cleared. If a nested batch closing had unset it, step 2 of the
    ///      outer batch would see false, and ETH arriving there would be wrapped out from under a
    ///      module measuring a native balance delta across the whole batch.
    function test_inModuleBatch_survivesNestedBatch() public {
        BatchFlagProbe probe = new BatchFlagProbe();
        NestedBatcher batcher = new NestedBatcher(address(dataProvider));
        _enableModule(address(batcher));

        address[] memory to = new address[](2);
        bytes[] memory data = new bytes[](2);
        to[0] = address(batcher);
        data[0] = abi.encodeCall(NestedBatcher.nest, (address(safe), address(probe)));
        to[1] = address(probe);
        data[1] = abi.encodeCall(BatchFlagProbe.record, (address(safe)));

        assertFalse(safe.inModuleBatch());

        vm.prank(address(cashModule));
        safe.execTransactionFromModule(to, new uint256[](2), data);

        assertEq(probe.count(), 2, "probe ran once inside the nested batch and once after it closed");
        assertTrue(probe.flagAt(0), "flag not set inside the nested batch");
        assertTrue(probe.flagAt(1), "nested batch cleared the outer flag");
        assertFalse(safe.inModuleBatch(), "outer batch did not clear the flag on exit");
    }

    /// @dev ETH arriving after a nested batch has closed is still mid-batch, so it stays native.
    function test_receive_passesThroughEthArrivingAfterANestedBatch() public {
        BatchFlagProbe probe = new BatchFlagProbe();
        EthBouncer bouncer = new EthBouncer();
        NestedBatcher batcher = new NestedBatcher(address(dataProvider));
        _enableModule(address(batcher));

        deal(address(safe), 1 ether);

        address[] memory to = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory data = new bytes[](2);
        to[0] = address(batcher);
        data[0] = abi.encodeCall(NestedBatcher.nest, (address(safe), address(probe)));
        to[1] = address(bouncer);
        values[1] = 1 ether;
        data[1] = abi.encodeCall(EthBouncer.bounce, ());

        vm.prank(address(cashModule));
        safe.execTransactionFromModule(to, values, data);

        assertEq(address(safe).balance, 1 ether, "ETH bounced back after the nested batch was wrapped");
        assertEq(IERC20(weth).balanceOf(address(safe)), 0);
    }

    // ── module status is read live ───────────────────────────────────────────

    /// @dev The pass-through is keyed on live module status, so ETH from a module the safe has since
    ///      dropped is an ordinary third-party transfer and must be wrapped.
    function test_receive_wrapsEthFromRemovedModule() public {
        vm.deal(module1, 1 ether);

        vm.prank(module1);
        (bool okBefore,) = address(safe).call{ value: 0.5 ether }("");
        assertTrue(okBefore);
        assertEq(address(safe).balance, 0.5 ether, "an enabled module should pass through");

        address[] memory modules = new address[](1);
        modules[0] = module1;
        _configureModules(modules, new bool[](1), new bytes[](1));
        assertFalse(safe.isModuleEnabled(module1));

        vm.prank(module1);
        (bool okAfter,) = address(safe).call{ value: 0.5 ether }("");

        assertTrue(okAfter);
        assertEq(IERC20(weth).balanceOf(address(safe)), 0.5 ether, "a removed module should be wrapped");
        assertEq(address(safe).balance, 0.5 ether, "the earlier pass-through should be untouched");
    }

    // ── ERC-1271 rejections answer rather than revert ────────────────────────

    /// @dev Every case below makes `checkSignatures` or the decode revert. ERC-1271 consumers
    ///      staticcall without a try/catch, so `isValidSignature` has to answer INVALID instead.
    function test_isValidSignature_returnsInvalidForNonOwnerSigner() public view {
        (address[] memory signers, uint256[] memory pks) = _pair(notOwner, notOwnerPk, owner2, owner2Pk);
        assertEq(_validate(signers, pks), INVALID);
    }

    function test_isValidSignature_returnsInvalidBelowThreshold() public view {
        (address[] memory signers, uint256[] memory pks) = _single(owner1, owner1Pk);
        assertEq(_validate(signers, pks), INVALID);
    }

    function test_isValidSignature_returnsInvalidForDuplicateSigners() public view {
        (address[] memory signers, uint256[] memory pks) = _pair(owner1, owner1Pk, owner1, owner1Pk);
        assertEq(_validate(signers, pks), INVALID);
    }

    function test_isValidSignature_returnsInvalidOnEmptySigners() public view {
        assertEq(_validate(new address[](0), new uint256[](0)), INVALID);
    }

    function test_isValidSignature_returnsInvalidOnArrayLengthMismatch() public view {
        bytes memory message = "ether.fi safe ownership proof";
        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(message);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        assertEq(safe.isValidSignature(hash, abi.encode(message, signers, new bytes[](1))), INVALID);
    }

    function test_isValidSignature_returnsInvalidOnMalformedSignatureBytes() public view {
        bytes memory message = "ether.fi safe ownership proof";
        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(message);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = hex"dead";
        signatures[1] = hex"beef";

        assertEq(safe.isValidSignature(hash, abi.encode(message, signers, signatures)), INVALID);
    }

    /// @dev A blob that is not this safe's signature format at all. The decode sits inside the library's
    ///      call boundary, so this is answered rather than propagated as a revert.
    function test_isValidSignature_returnsInvalidOnUndecodableBlob() public view {
        assertEq(safe.isValidSignature(keccak256("anything"), hex"deadbeef"), INVALID);
        assertEq(safe.isValidSignature(keccak256("anything"), ""), INVALID);
    }

    // ── ERC-1271 tracks the live owner set ──────────────────────────────────

    /// @dev Once the recovery timelock matures, `checkSignatures` switches to the single incoming
    ///      owner. ERC-1271 inherits that, so it must stop honouring the displaced owners too.
    function test_isValidSignature_followsRecoveryToTheIncomingOwner() public {
        (address newOwner, uint256 newOwnerPk) = makeAddrAndKey("recoveredOwner");

        bytes32 structHash = keccak256(abi.encode(safe.RECOVER_SAFE_TYPEHASH(), newOwner, safe.nonce()));
        bytes32 recoveryDigest = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = etherFiRecoverySigner;
        recoverySigners[1] = thirdPartyRecoverySigner;

        bytes[] memory recoverySignatures = new bytes[](2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(etherFiRecoverySignerPk, recoveryDigest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(thirdPartyRecoverySignerPk, recoveryDigest);
        recoverySignatures[0] = abi.encodePacked(r1, s1, v1);
        recoverySignatures[1] = abi.encodePacked(r2, s2, v2);

        safe.recoverSafe(newOwner, recoverySigners, recoverySignatures);
        vm.warp(block.timestamp + dataProvider.getRecoveryDelayPeriod() + 1);

        (address[] memory incoming, uint256[] memory incomingPks) = _single(newOwner, newOwnerPk);
        assertEq(_validate(incoming, incomingPks), MAGIC, "the incoming owner should be honoured");

        bytes memory message = "ether.fi safe ownership proof";
        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(message);
        assertEq(safe.isValidSignature(hash, _blob(message, hash)), INVALID, "displaced owners should not be");
    }

    // ── constants ───────────────────────────────────────────────────────────

    /// @dev The other tests read the typehash off the contract, so a wrong literal would pass them all.
    function test_safeMessageTypehash_matchesItsDefinition() public view {
        assertEq(safe.SAFE_MESSAGE_TYPEHASH(), keccak256("EtherFiSafeMessage(bytes32 message)"));
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    /// @dev Builds a blob carrying `message` plus two owner signatures over `hash` wrapped in the safe's domain.
    function _blob(bytes memory message, bytes32 hash) internal view returns (bytes memory) {
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        uint256[] memory pks = new uint256[](2);
        pks[0] = owner1Pk;
        pks[1] = owner2Pk;

        return _blobFor(message, hash, signers, pks);
    }

    /// @dev As `_blob`, but with a caller-chosen signer set so the rejection cases can vary it.
    function _blobFor(bytes memory message, bytes32 hash, address[] memory signers, uint256[] memory pks) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), keccak256(abi.encode(safe.SAFE_MESSAGE_TYPEHASH(), hash))));

        uint256 len = pks.length;
        bytes[] memory signatures = new bytes[](len);
        for (uint256 i = 0; i < len; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(pks[i], digest);
            signatures[i] = abi.encodePacked(r, s, v);
        }

        return abi.encode(message, signers, signatures);
    }

    /// @dev Runs the standard message through `isValidSignature` with the given signer set.
    function _validate(address[] memory signers, uint256[] memory pks) internal view returns (bytes4) {
        bytes memory message = "ether.fi safe ownership proof";
        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(message);

        return safe.isValidSignature(hash, _blobFor(message, hash, signers, pks));
    }

    function _single(address signer, uint256 pk) internal pure returns (address[] memory signers, uint256[] memory pks) {
        signers = new address[](1);
        signers[0] = signer;
        pks = new uint256[](1);
        pks[0] = pk;
    }

    function _pair(address a, uint256 aPk, address b, uint256 bPk) internal pure returns (address[] memory signers, uint256[] memory pks) {
        signers = new address[](2);
        signers[0] = a;
        signers[1] = b;
        pks = new uint256[](2);
        pks[0] = aPk;
        pks[1] = bPk;
    }

    /// @dev Whitelists `module` on the data provider and adds it to the safe with empty setup data.
    function _enableModule(address module) internal {
        address[] memory modules = new address[](1);
        modules[0] = module;

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.prank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);
        _configureModules(modules, shouldWhitelist, new bytes[](1));

        assertTrue(safe.isModuleEnabled(module));
    }
}

/// @dev Records `inModuleBatch()` each time the safe reaches it, so a batch can be observed step by step.
contract BatchFlagProbe {
    bool[] internal flags;

    function record(address safe) external {
        flags.push(EtherFiSafe(payable(safe)).inModuleBatch());
    }

    function count() external view returns (uint256) {
        return flags.length;
    }

    function flagAt(uint256 index) external view returns (bool) {
        return flags[index];
    }
}

/// @dev An enabled module that the safe calls as a batch step, which then re-enters the safe to open a
///      nested batch — the only way a second `execTransactionFromModule` frame can exist.
contract NestedBatcher is ModuleBase {
    constructor(address _dataProvider) ModuleBase(_dataProvider) { }

    function nest(address safe, address probe) external {
        address[] memory to = new address[](1);
        bytes[] memory data = new bytes[](1);
        to[0] = probe;
        data[0] = abi.encodeCall(BatchFlagProbe.record, (safe));

        EtherFiSafe(payable(safe)).execTransactionFromModule(to, new uint256[](1), data);
    }
}

contract StipendSender {
    function send(address payable to, uint256 amount) external {
        to.transfer(amount);
    }
}

contract WrapCaller {
    function wrap(address safe) external {
        EtherFiSafe(payable(safe)).wrapEth();
    }
}

contract EthBouncer {
    function bounce() external payable {
        (bool ok,) = msg.sender.call{ value: msg.value }("");
        require(ok, "bounce failed");
    }
}
