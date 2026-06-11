// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { IOFT, SendParam } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { ConfigurableOFTBase } from "../../src/oft/ConfigurableOFTBase.sol";
import { EtherFiOFTAdapter } from "../../src/oft/EtherFiOFTAdapter.sol";
import { EtherFiShadowOFT } from "../../src/oft/EtherFiShadowOFT.sol";

import { OFTAdapterHarness } from "./EtherFiOFTAdapter.t.sol";
import { OFTCrossChainSetup } from "./OFTCrossChainSetup.t.sol";
import { OFTTestSetup } from "./OFTTestSetup.t.sol";

/// Shadow harness exposing the internal mint/burn hooks so pause enforcement can be driven directly.
contract ShadowPauseHarness is EtherFiShadowOFT {
    constructor(address ep, address reg) EtherFiShadowOFT(ep, reg) { }

    function exposedDebit(address from, uint256 amt, uint256 minAmt, uint32 dstEid) external returns (uint256, uint256) {
        return _debit(from, amt, minAmt, dstEid);
    }

    function exposedCredit(address to, uint256 amt, uint32 srcEid) external returns (uint256) {
        return _credit(to, amt, srcEid);
    }
}

/**
 * @title OFTPauseTest
 * @notice Per-bridge pause: {pauseBridge}/{unpauseBridge} live ON the bridge, gated by the shared
 *         RoleRegistry PAUSER/UNPAUSER roles (resolved off the config registry), with NO registry in
 *         the control path. One flag halts BOTH directions ({whenNotPaused} on `_debit`/`_credit`).
 *         Enforcement is driven via harnesses that expose the hooks; the live LZ round-trip
 *         (including inbound retry) is in {OFTPauseE2ETest}.
 */
contract OFTPauseTest is OFTTestSetup {
    function _adapterHarness(address tok) internal returns (OFTAdapterHarness h) {
        address impl = address(new OFTAdapterHarness(address(endpoint), address(configRegistry)));
        UpgradeableBeacon beacon = new UpgradeableBeacon(impl, owner);
        bytes memory initData = abi.encodeWithSelector(EtherFiOFTAdapter.initialize.selector, tok, delegate);
        h = OFTAdapterHarness(address(new BeaconProxy(address(beacon), initData)));
        _liftRateLimits(address(h), DST_EID_OP);
    }

    function _shadowHarness() internal returns (ShadowPauseHarness h) {
        address impl = address(new ShadowPauseHarness(address(endpoint), address(configRegistry)));
        UpgradeableBeacon beacon = new UpgradeableBeacon(impl, owner);
        bytes memory initData = abi.encodeWithSelector(EtherFiShadowOFT.initialize.selector, "EtherFi UND", "iUND", uint8(18), delegate);
        h = ShadowPauseHarness(address(new BeaconProxy(address(beacon), initData)));
        _liftRateLimits(address(h), DST_EID_OP);
    }

    // ----------------------------------------------------------------- toggle + events

    function test_pauseBridge_pausesAndEmits() public {
        ShadowPauseHarness h = _shadowHarness();
        assertFalse(h.paused());

        vm.expectEmit(true, true, true, true, address(h));
        emit PausableUpgradeable.Paused(pauser);
        vm.prank(pauser);
        h.pauseBridge();

        assertTrue(h.paused());
    }

    function test_unpauseBridge_unpauses() public {
        ShadowPauseHarness h = _shadowHarness();
        vm.prank(pauser);
        h.pauseBridge();
        assertTrue(h.paused());

        vm.prank(unpauser);
        h.unpauseBridge();
        assertFalse(h.paused());
    }

    // Redundant pause/unpause is a no-op (so a Safe-batch "pause everything" can't revert on a
    // bridge that's already individually paused).
    function test_pauseBridge_idempotent() public {
        ShadowPauseHarness h = _shadowHarness();
        vm.startPrank(pauser);
        h.pauseBridge();
        h.pauseBridge(); // no revert
        vm.stopPrank();
        assertTrue(h.paused());

        vm.prank(unpauser);
        h.unpauseBridge();
        vm.prank(unpauser);
        h.unpauseBridge(); // no revert
        assertFalse(h.paused());
    }

    // ----------------------------------------------------------------- role gating

    function test_pauseBridge_onlyPauser() public {
        ShadowPauseHarness h = _shadowHarness();
        vm.prank(alice);
        vm.expectRevert(); // RoleRegistry onlyPauser reverts for a non-pauser
        h.pauseBridge();
    }

    function test_unpauseBridge_onlyUnpauser() public {
        ShadowPauseHarness h = _shadowHarness();
        vm.prank(pauser);
        h.pauseBridge();

        vm.prank(alice);
        vm.expectRevert();
        h.unpauseBridge();
    }

    // "Fast pause, careful unpause": the roles are distinct — a pauser cannot unpause, and vice-versa.
    function test_pauserCannotUnpause_andUnpauserCannotPause() public {
        ShadowPauseHarness h = _shadowHarness();

        vm.prank(unpauser);
        vm.expectRevert();
        h.pauseBridge();

        vm.prank(pauser);
        h.pauseBridge();

        vm.prank(pauser);
        vm.expectRevert();
        h.unpauseBridge();
    }

    // ----------------------------------------------------------------- enforcement: adapter

    function test_adapter_debit_revertsWhenPaused() public {
        OFTAdapterHarness h = _adapterHarness(address(token6));
        token6.mint(alice, 1000e6);
        vm.prank(alice);
        token6.approve(address(h), 1000e6);

        vm.prank(pauser);
        h.pauseBridge();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        h.exposedDebit(alice, 1000e6, 0, DST_EID_OP);

        // unpause -> the same send now succeeds
        vm.prank(unpauser);
        h.unpauseBridge();
        (uint256 sent,) = h.exposedDebit(alice, 1000e6, 0, DST_EID_OP);
        assertEq(sent, 1000e6);
    }

    function test_adapter_credit_revertsWhenPaused() public {
        OFTAdapterHarness h = _adapterHarness(address(token6));
        token6.mint(address(h), 500e6); // simulate a locked balance to unlock on credit

        vm.prank(pauser);
        h.pauseBridge();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        h.exposedCredit(alice, 500e6, DST_EID_OP);

        vm.prank(unpauser);
        h.unpauseBridge();
        assertEq(h.exposedCredit(alice, 500e6, DST_EID_OP), 500e6);
    }

    // ----------------------------------------------------------------- enforcement: shadow

    function test_shadow_debit_revertsWhenPaused() public {
        ShadowPauseHarness h = _shadowHarness();
        vm.prank(pauser);
        h.pauseBridge();

        // whenNotPaused fires before any burn, so this reverts on pause (not on missing balance).
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        h.exposedDebit(alice, 1000e18, 0, DST_EID_OP);
    }

    function test_shadow_credit_revertsWhenPaused_thenMintsAfterUnpause() public {
        ShadowPauseHarness h = _shadowHarness();
        vm.prank(pauser);
        h.pauseBridge();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        h.exposedCredit(alice, 1000e18, DST_EID_OP);

        vm.prank(unpauser);
        h.unpauseBridge();
        assertEq(h.exposedCredit(alice, 1000e18, DST_EID_OP), 1000e18);
        assertEq(h.balanceOf(alice), 1000e18); // minted on the inbound path
    }
}

/**
 * @title OFTPauseE2ETest
 * @notice End-to-end pause over the live LZ harness: an outbound send reverts up front while paused,
 *         and an inbound delivery blocked by pause leaves the message RETRYABLE — after unpause the
 *         same packet delivers and the user is made whole (funds held, not lost).
 */
contract OFTPauseE2ETest is OFTCrossChainSetup {
    using OptionsBuilder for bytes;

    address internal pauser = makeAddr("pauser");
    address internal unpauser = makeAddr("unpauser");

    function setUp() public override {
        super.setUp();
        vm.startPrank(owner);
        roleRegistry.grantRole(roleRegistry.PAUSER(), pauser);
        roleRegistry.grantRole(roleRegistry.UNPAUSER(), unpauser);
        vm.stopPrank();
    }

    function _send(address bridge, uint32 dstEid, address to, uint256 amt) internal view returns (MessagingFee memory fee, SendParam memory sp) {
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        sp = SendParam(dstEid, _b32(to), amt, 0, options, "", "");
        fee = IOFT(bridge).quoteSend(sp, false);
    }

    // Outbound: a paused source bridge reverts the user's send() before any value moves.
    function test_e2e_outboundPause_revertsSend_thenUnpauseSucceeds() public {
        _deployPair(18);
        uint256 amount = 100e18;
        underlying.mint(alice, amount);

        vm.prank(pauser);
        adapter.pauseBridge();

        (MessagingFee memory fee, SendParam memory sp) = _send(address(adapter), B_EID, alice, amount);
        vm.startPrank(alice);
        underlying.approve(address(adapter), amount);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        adapter.send{ value: fee.nativeFee }(sp, fee, payable(alice));
        vm.stopPrank();

        // nothing locked, nothing minted
        assertEq(_locked(), 0);
        assertEq(shadow.totalSupply(), 0);

        // unpause -> the normal flow goes through
        vm.prank(unpauser);
        adapter.unpauseBridge();
        _bridgeOut(alice, amount);
        assertEq(_locked(), amount);
        assertEq(shadow.balanceOf(alice), amount);
    }

    // Inbound: bridge out, then pause the RECEIVING side before bridging back. The burn on the
    // source still happens, but delivery on the destination reverts while paused — the packet stays
    // retryable. After unpause, re-delivering the same packet makes the user whole.
    function test_e2e_inboundPause_messageRetryable_afterUnpause() public {
        _deployPair(18);
        uint256 amount = 100e18;
        underlying.mint(alice, amount);
        _bridgeOut(alice, amount); // alice now holds iTOKEN on OP; `amount` locked on mainnet

        // Bridge back: burn iTOKEN on OP (source), deliver unlock on mainnet adapter (receive).
        // Pause the adapter (the receiving side) first.
        vm.prank(pauser);
        adapter.pauseBridge();

        (MessagingFee memory fee, SendParam memory sp) = _send(address(shadow), A_EID, alice, amount);
        vm.prank(alice);
        shadow.send{ value: fee.nativeFee }(sp, fee, payable(alice));

        // Burn happened on the source; supply dropped. Funds are mid-flight, not yet unlocked.
        assertEq(shadow.totalSupply(), 0, "iTOKEN burned on source");
        assertEq(underlying.balanceOf(alice), 0, "not unlocked yet");

        // Delivery to the paused adapter fails — the message is held (retryable), funds not lost.
        vm.expectRevert();
        this.deliver(A_EID, address(adapter));

        // Unpause and retry the SAME packet -> alice is made whole.
        vm.prank(unpauser);
        adapter.unpauseBridge();
        this.deliver(A_EID, address(adapter));

        assertEq(underlying.balanceOf(alice), amount, "user made whole after retry");
        assertEq(_locked(), 0, "adapter unlocked");
    }

    /// @dev External wrapper so {test_e2e_inboundPause} can expectRevert on packet delivery.
    function deliver(uint32 dstEid, address oapp) external {
        verifyPackets(dstEid, _b32(oapp));
    }
}
