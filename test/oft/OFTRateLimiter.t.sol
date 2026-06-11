// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { EtherFiOFTAdapter } from "../../src/oft/EtherFiOFTAdapter.sol";
import { EtherFiShadowOFT } from "../../src/oft/EtherFiShadowOFT.sol";
import { PairwiseRateLimiter } from "../../src/oft/PairwiseRateLimiter.sol";
import { OFTAdapterHarness } from "./EtherFiOFTAdapter.t.sol";
import { MockERC20, OFTTestSetup } from "./OFTTestSetup.t.sol";

/**
 * Test harness exposing the internal rate-limit hooks so the decay/checkpoint math can be driven
 * directly, without routing a full cross-chain send. Built on the shadow impl, but the limiter is
 * shared so the logic is identical on the adapter.
 */
contract ShadowRateHarness is EtherFiShadowOFT {
    constructor(address ep, address reg) EtherFiShadowOFT(ep, reg) { }

    function checkOutbound(uint32 eid, uint256 amount) external {
        _checkAndUpdateOutboundRateLimit(eid, amount);
    }

    function checkInbound(uint32 eid, uint256 amount) external {
        _checkAndUpdateInboundRateLimit(eid, amount);
    }
}

/**
 * @title OFTRateLimiterTest
 * @notice Unit coverage for the ported {PairwiseRateLimiter}: fail-closed unset pathways, per-window
 *         linear decay, limit changes mid-window, outbound/inbound independence, owner-gating, and
 *         that the adapter meters the dust-removed sent amount (not the raw request).
 */
contract OFTRateLimiterTest is OFTTestSetup {
    ShadowRateHarness internal rl;

    uint256 internal constant LIMIT = 1000 ether;
    uint256 internal constant WINDOW = 1 hours;

    function setUp() public override {
        super.setUp();
        rl = _rateHarness();
    }

    function _rateHarness() internal returns (ShadowRateHarness h) {
        address impl = address(new ShadowRateHarness(address(endpoint), address(configRegistry)));
        UpgradeableBeacon beacon = new UpgradeableBeacon(impl, owner);
        bytes memory initData = abi.encodeWithSelector(EtherFiShadowOFT.initialize.selector, "EtherFi UND", "iUND", uint8(18), delegate);
        h = ShadowRateHarness(address(new BeaconProxy(address(beacon), initData)));
    }

    function _cfg(uint32 eid, uint256 limit, uint256 window) internal pure returns (PairwiseRateLimiter.RateLimitConfig[] memory c) {
        c = new PairwiseRateLimiter.RateLimitConfig[](1);
        c[0] = PairwiseRateLimiter.RateLimitConfig({ peerEid: eid, limit: limit, window: window });
    }

    function _setOutbound(uint32 eid, uint256 limit, uint256 window) internal {
        vm.prank(delegate);
        rl.setOutboundRateLimits(_cfg(eid, limit, window));
    }

    function _setInbound(uint32 eid, uint256 limit, uint256 window) internal {
        vm.prank(delegate);
        rl.setInboundRateLimits(_cfg(eid, limit, window));
    }

    // --------------------------------------------------------------- fail-closed (unset pathway)

    // An unconfigured pathway allows zero throughput in both directions.
    function test_unsetPathway_blocksOutbound() public {
        vm.expectRevert(PairwiseRateLimiter.OutboundRateLimitExceeded.selector);
        rl.checkOutbound(DST_EID_OP, 1);
    }

    function test_unsetPathway_blocksInbound() public {
        vm.expectRevert(PairwiseRateLimiter.InboundRateLimitExceeded.selector);
        rl.checkInbound(DST_EID_OP, 1);
    }

    // A zero-amount call passes even when unset (used internally to checkpoint decay).
    function test_unsetPathway_zeroAmountPasses() public {
        rl.checkOutbound(DST_EID_OP, 0);
    }

    // --------------------------------------------------------------- basic cap

    function test_outbound_allowsUpToLimit_thenBlocks() public {
        _setOutbound(DST_EID_OP, LIMIT, WINDOW);

        rl.checkOutbound(DST_EID_OP, 600 ether); // ok
        (, uint256 canSend) = rl.getAmountCanBeSent(DST_EID_OP);
        assertEq(canSend, 400 ether, "remaining capacity wrong");

        vm.expectRevert(PairwiseRateLimiter.OutboundRateLimitExceeded.selector);
        rl.checkOutbound(DST_EID_OP, 600 ether); // would exceed within the same window

        rl.checkOutbound(DST_EID_OP, 400 ether); // exactly the remainder is allowed
        (, canSend) = rl.getAmountCanBeSent(DST_EID_OP);
        assertEq(canSend, 0, "should be fully consumed");
    }

    function test_inbound_allowsUpToLimit_thenBlocks() public {
        _setInbound(DST_EID_OP, LIMIT, WINDOW);

        rl.checkInbound(DST_EID_OP, LIMIT); // ok, fully consumed
        vm.expectRevert(PairwiseRateLimiter.InboundRateLimitExceeded.selector);
        rl.checkInbound(DST_EID_OP, 1);
    }

    function test_exactlyAtLimit_passes() public {
        _setOutbound(DST_EID_OP, LIMIT, WINDOW);
        rl.checkOutbound(DST_EID_OP, LIMIT);
    }

    // --------------------------------------------------------------- linear decay

    // After half the window, half the consumed capacity has decayed back.
    function test_decayOverWindow_replenishesLinearly() public {
        _setOutbound(DST_EID_OP, LIMIT, WINDOW);
        rl.checkOutbound(DST_EID_OP, LIMIT); // fully consumed

        skip(WINDOW / 2);
        (uint256 inFlight, uint256 canSend) = rl.getAmountCanBeSent(DST_EID_OP);
        assertEq(inFlight, LIMIT / 2, "half should remain in flight");
        assertEq(canSend, LIMIT / 2, "half capacity should have returned");
    }

    // Once a full window elapses, capacity is fully restored.
    function test_fullWindowElapsed_fullCapacity() public {
        _setOutbound(DST_EID_OP, LIMIT, WINDOW);
        rl.checkOutbound(DST_EID_OP, LIMIT);

        skip(WINDOW);
        (uint256 inFlight, uint256 canSend) = rl.getAmountCanBeSent(DST_EID_OP);
        assertEq(inFlight, 0, "in flight should fully decay");
        assertEq(canSend, LIMIT, "full capacity restored");

        rl.checkOutbound(DST_EID_OP, LIMIT); // can send the full limit again
    }

    // --------------------------------------------------------------- limit changes mid-window

    // Lowering the limit below the current in-flight amount leaves zero remaining capacity, and
    // a checkpoint of the existing in-flight amount is preserved (not retroactively decayed).
    function test_limitLoweredMidWindow_clampsCapacityToZero() public {
        _setOutbound(DST_EID_OP, LIMIT, WINDOW);
        rl.checkOutbound(DST_EID_OP, 800 ether);

        _setOutbound(DST_EID_OP, 500 ether, WINDOW); // new limit below in-flight (800)
        (uint256 inFlight, uint256 canSend) = rl.getAmountCanBeSent(DST_EID_OP);
        assertEq(inFlight, 800 ether, "in-flight checkpoint should be preserved across the limit change");
        assertEq(canSend, 0, "no capacity when in-flight exceeds the lowered limit");

        vm.expectRevert(PairwiseRateLimiter.OutboundRateLimitExceeded.selector);
        rl.checkOutbound(DST_EID_OP, 1);
    }

    // Raising the limit mid-window immediately grants the extra capacity.
    function test_limitRaisedMidWindow_grantsExtraCapacity() public {
        _setOutbound(DST_EID_OP, LIMIT, WINDOW);
        rl.checkOutbound(DST_EID_OP, LIMIT); // consumed

        _setOutbound(DST_EID_OP, LIMIT * 2, WINDOW);
        (, uint256 canSend) = rl.getAmountCanBeSent(DST_EID_OP);
        assertEq(canSend, LIMIT, "raised headroom should be immediately available");
    }

    // --------------------------------------------------------------- direction independence

    // Outbound and inbound use separate ledgers, even on the same eid.
    function test_outboundAndInbound_areIndependent() public {
        _setOutbound(DST_EID_OP, LIMIT, WINDOW);
        _setInbound(DST_EID_OP, LIMIT, WINDOW);

        rl.checkOutbound(DST_EID_OP, LIMIT); // exhaust outbound

        (, uint256 canReceive) = rl.getAmountCanBeReceived(DST_EID_OP);
        assertEq(canReceive, LIMIT, "inbound capacity unaffected by outbound usage");
        rl.checkInbound(DST_EID_OP, LIMIT); // inbound still fully available
    }

    // Limits on different eids are independent.
    function test_perEid_independent() public {
        _setOutbound(DST_EID_OP, LIMIT, WINDOW);
        _setOutbound(DST_EID_ETH, LIMIT, WINDOW);

        rl.checkOutbound(DST_EID_OP, LIMIT);
        (, uint256 canSendEth) = rl.getAmountCanBeSent(DST_EID_ETH);
        assertEq(canSendEth, LIMIT, "other eid capacity unaffected");
    }

    // --------------------------------------------------------------- access control

    function test_setOutboundRateLimits_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rl.setOutboundRateLimits(_cfg(DST_EID_OP, LIMIT, WINDOW));
    }

    function test_setInboundRateLimits_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rl.setInboundRateLimits(_cfg(DST_EID_OP, LIMIT, WINDOW));
    }

    // --------------------------------------------------------------- metering integration (adapter)

    // The adapter meters the dust-removed sent amount, not the raw request: a sub-rate dust tail
    // does not inflate the in-flight counter.
    function test_adapter_metersAmountSentLD_notRaw() public {
        // PAXG-like 18-decimal underlying => conversion rate 1e12; sub-1e12 wei is dust.
        OFTAdapterHarness h = _adapterHarness(address(token18));
        uint256 clean = 1000 * 1e18;
        uint256 dusty = clean + 500; // 500 wei < rate (1e12) => dropped on the wire

        _setOutboundOn(address(h), DST_EID_OP, type(uint256).max, WINDOW);

        token18.mint(alice, dusty);
        vm.prank(alice);
        token18.approve(address(h), dusty);

        (uint256 sent,) = h.exposedDebit(alice, dusty, 0, DST_EID_OP);
        assertEq(sent, clean, "dust should be removed from the sent amount");

        PairwiseRateLimiter.RateLimit memory state = h.outboundRateLimit(DST_EID_OP);
        assertEq(state.amountInFlight, clean, "in-flight should track the dust-removed sent amount");
    }

    // ----------------------------------------------------------------- fuzz

    // For any window-internal split, the cumulative checked amount can never exceed the limit.
    function testFuzz_cumulativeWithinWindowCappedByLimit(uint256 limit, uint256 a, uint256 b) public {
        limit = bound(limit, 1, type(uint128).max);
        a = bound(a, 0, limit);
        b = bound(b, 0, limit);
        _setOutbound(DST_EID_OP, limit, WINDOW);

        rl.checkOutbound(DST_EID_OP, a); // a <= limit always ok at window start
        if (a + b <= limit) {
            rl.checkOutbound(DST_EID_OP, b);
        } else {
            vm.expectRevert(PairwiseRateLimiter.OutboundRateLimitExceeded.selector);
            rl.checkOutbound(DST_EID_OP, b);
        }
    }

    // The cap holds in the asset's local decimals across the supported precision range.
    function testFuzz_metersInLocalDecimals(uint8 decimalsSeed, uint256 amount) public {
        MockERC20[3] memory toks = [token6, token8, token18];
        MockERC20 tok = toks[decimalsSeed % 3];
        OFTAdapterHarness h = _adapterHarness(address(tok));

        uint256 rate = h.conversionRate();
        amount = bound(amount, rate, 1_000_000 * (10 ** uint256(tok.decimals())));
        uint256 expectedSent = (amount / rate) * rate;

        _setOutboundOn(address(h), DST_EID_OP, expectedSent, WINDOW); // limit == exactly the sent amount

        tok.mint(alice, amount);
        vm.prank(alice);
        tok.approve(address(h), amount);

        h.exposedDebit(alice, amount, 0, DST_EID_OP); // exactly at the limit -> passes
        PairwiseRateLimiter.RateLimit memory state = h.outboundRateLimit(DST_EID_OP);
        assertEq(state.amountInFlight, expectedSent);
        (, uint256 canSend) = h.getAmountCanBeSent(DST_EID_OP);
        assertEq(canSend, 0, "limit set to the sent amount should be exactly exhausted");
    }

    // --------------------------------------------------------------- helpers

    function _adapterHarness(address tok) internal returns (OFTAdapterHarness h) {
        address impl = address(new OFTAdapterHarness(address(endpoint), address(configRegistry)));
        UpgradeableBeacon beacon = new UpgradeableBeacon(impl, owner);
        bytes memory initData = abi.encodeWithSelector(EtherFiOFTAdapter.initialize.selector, tok, delegate);
        h = OFTAdapterHarness(address(new BeaconProxy(address(beacon), initData)));
    }

    function _setOutboundOn(address bridge, uint32 eid, uint256 limit, uint256 window) internal {
        vm.prank(delegate);
        PairwiseRateLimiter(bridge).setOutboundRateLimits(_cfg(eid, limit, window));
    }
}
