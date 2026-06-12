// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IOFT } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { EtherFiOFTAdapter } from "../../src/oft/EtherFiOFTAdapter.sol";
import { OFTAdapterHarness } from "./EtherFiOFTAdapter.t.sol";
import { OFTTestSetup } from "./OFTTestSetup.t.sol";

/**
 * @title OFTWeirdTokensTest
 * @notice Behavior of the lock adapter against non-standard ERC-20s. The lossless guard
 *         rejects any token that delivers less than was pulled (fee-on-transfer / shrink-on-lock),
 *         SafeERC20 tolerates missing/false return values, and the credit (unlock) path inherits
 *         the underlying's pausable/blacklist failure modes — documented here so the per-asset
 *         vetting requirement is explicit.
 */
contract OFTWeirdTokensTest is OFTTestSetup {
    using SafeERC20 for *;

    address internal recipient = makeAddr("recipient");

    // Deploy a harness-backed adapter initialized for `tok` so we can reach _debit/_credit.
    function _harness(address tok) internal returns (OFTAdapterHarness h) {
        address impl = address(new OFTAdapterHarness(address(endpoint), address(configRegistry)));
        UpgradeableBeacon beacon = new UpgradeableBeacon(impl, owner);
        bytes memory initData = abi.encodeWithSelector(EtherFiOFTAdapter.initialize.selector, tok, delegate);
        h = OFTAdapterHarness(address(new BeaconProxy(address(beacon), initData)));
        // Lift the fail-closed rate limit so the lossless/transfer guards are what these tests observe.
        _liftRateLimits(address(h), DST_EID_OP);
    }

    // ----------------------------------------------------------------- lossless guard on lock

    // Asymmetric fee (skims only on transferFrom, i.e. exactly the lock direction) -> lock reverts.
    function test_lock_reverts_onAsymmetricFeeToken() public {
        AsymmetricFeeToken t = new AsymmetricFeeToken(6, 25); // 0.25% on transferFrom only
        OFTAdapterHarness h = _harness(address(t));
        uint256 amt = 1000e6;
        t.mint(alice, amt);
        vm.prank(alice);
        t.approve(address(h), amt);

        uint256 fee = (amt * 25) / 10_000;
        vm.expectRevert(abi.encodeWithSelector(EtherFiOFTAdapter.NonLosslessTransfer.selector, amt, amt - fee));
        h.exposedDebit(alice, amt, 0, DST_EID_OP);
    }

    // A token that negatively rebases the recipient on receipt delivers < amount -> lock reverts.
    function test_lock_reverts_onShrinkingRebaseToken() public {
        ShrinkOnReceiveToken t = new ShrinkOnReceiveToken(); // burns 1 wei from receiver post-credit
        OFTAdapterHarness h = _harness(address(t));
        uint256 amt = 1000e6;
        t.mint(alice, amt);
        vm.prank(alice);
        t.approve(address(h), amt);

        vm.expectRevert(abi.encodeWithSelector(EtherFiOFTAdapter.NonLosslessTransfer.selector, amt, amt - 1));
        h.exposedDebit(alice, amt, 0, DST_EID_OP);
    }

    // Same guard, fuzzed: for ANY amount and fee, an asymmetric-fee token delivers `amt - fee` < amt,
    // so the lock reverts NonLosslessTransfer(amt, amt - fee). 6-decimal token -> rate 1, no dust.
    function testFuzz_lock_reverts_onAsymmetricFeeToken(uint256 amt, uint256 feeBps) public {
        feeBps = bound(feeBps, 1, 1000); // 0.01%..10%
        amt = bound(amt, 10_000, 1e30); // >= 10_000 so a >=1-bps fee always skims at least 1 wei
        AsymmetricFeeToken t = new AsymmetricFeeToken(6, feeBps);
        OFTAdapterHarness h = _harness(address(t));
        t.mint(alice, amt);
        vm.prank(alice);
        t.approve(address(h), amt);

        uint256 fee = (amt * feeBps) / 10_000;
        vm.expectRevert(abi.encodeWithSelector(EtherFiOFTAdapter.NonLosslessTransfer.selector, amt, amt - fee));
        h.exposedDebit(alice, amt, 0, DST_EID_OP);
    }

    // Same guard, fuzzed against a 1-wei negative rebase across magnitudes: received = amt - 1.
    function testFuzz_lock_reverts_onShrinkingRebaseToken(uint256 amt) public {
        amt = bound(amt, 1, 1e30);
        ShrinkOnReceiveToken t = new ShrinkOnReceiveToken();
        OFTAdapterHarness h = _harness(address(t));
        t.mint(alice, amt);
        vm.prank(alice);
        t.approve(address(h), amt);

        vm.expectRevert(abi.encodeWithSelector(EtherFiOFTAdapter.NonLosslessTransfer.selector, amt, amt - 1));
        h.exposedDebit(alice, amt, 0, DST_EID_OP);
    }

    // ----------------------------------------------------------------- SafeERC20 tolerance

    // USDT-style token whose transferFrom returns no bool: SafeERC20 accepts it, lock succeeds.
    function test_lock_succeeds_onMissingReturnToken() public {
        MissingReturnToken t = new MissingReturnToken();
        OFTAdapterHarness h = _harness(address(t));
        uint256 amt = 1000e6;
        t.mint(alice, amt);
        vm.prank(alice);
        t.approve(address(h), amt);

        (uint256 sent, uint256 received) = h.exposedDebit(alice, amt, 0, DST_EID_OP);
        assertEq(sent, amt);
        assertEq(received, amt);
        assertEq(t.balanceOf(address(h)), amt);
    }

    // A token whose transferFrom returns false: SafeERC20 reverts (no silent failure).
    function test_lock_reverts_onReturnsFalseToken() public {
        ReturnsFalseToken t = new ReturnsFalseToken();
        OFTAdapterHarness h = _harness(address(t));
        uint256 amt = 1000e6;
        t.mint(alice, amt);
        vm.prank(alice);
        t.approve(address(h), amt);

        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(t)));
        h.exposedDebit(alice, amt, 0, DST_EID_OP);
    }

    // ----------------------------------------------------------------- unlock (credit) failure modes

    /**
     * A pausable underlying: while paused, unlock reverts and the locked funds are stuck until the
     * token unpauses. Documents that the adapter has no override — pausable assets need vetting.
     */
    function test_unlock_reverts_whenUnderlyingPaused() public {
        PausableToken t = new PausableToken();
        OFTAdapterHarness h = _harness(address(t));
        t.mint(address(h), 500e6); // simulate previously locked balance

        t.pause();
        vm.expectRevert(PausableToken.TokenPaused.selector);
        h.exposedCredit(recipient, 500e6, DST_EID_OP);

        // unpausing restores the unlock
        t.unpause();
        uint256 got = h.exposedCredit(recipient, 500e6, DST_EID_OP);
        assertEq(got, 500e6);
        assertEq(t.balanceOf(recipient), 500e6);
    }

    /**
     * A blacklisting underlying: unlocking to a blacklisted recipient reverts. The funds remain
     * locked; resolution is a per-asset operational concern, not something the adapter masks.
     */
    function test_unlock_reverts_toBlacklistedRecipient() public {
        BlacklistToken t = new BlacklistToken();
        OFTAdapterHarness h = _harness(address(t));
        t.mint(address(h), 500e6);

        t.blacklist(recipient);
        vm.expectRevert(BlacklistToken.Blacklisted.selector);
        h.exposedCredit(recipient, 500e6, DST_EID_OP);

        // positive control: lifting the blacklist lets the same unlock through, so the block was
        // the sole cause (not some unrelated failure).
        t.unblacklist(recipient);
        uint256 got = h.exposedCredit(recipient, 500e6, DST_EID_OP);
        assertEq(got, 500e6);
        assertEq(t.balanceOf(recipient), 500e6);
    }

    // ----------------------------------------------------------------- init-time decimals probe

    // An underlying whose decimals() reverts cannot be initialized (the probe propagates).
    function test_initialize_reverts_whenDecimalsReverts() public {
        DecimalsRevertToken t = new DecimalsRevertToken();
        address impl = address(new OFTAdapterHarness(address(endpoint), address(configRegistry)));
        UpgradeableBeacon beacon = new UpgradeableBeacon(impl, owner);
        EtherFiOFTAdapter a = EtherFiOFTAdapter(address(new BeaconProxy(address(beacon), "")));
        vm.expectRevert(DecimalsRevertToken.NoDecimals.selector);
        a.initialize(address(t), delegate);
    }
}

// --------------------------------------------------------------------------
// Weird-ERC20 mocks (minimal; only the surface the adapter touches)
// --------------------------------------------------------------------------

abstract contract BaseToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 internal _dec;

    function decimals() external view virtual returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }
}

// Skims a fee ONLY on transferFrom (the lock direction); plain transfer is untaxed.
contract AsymmetricFeeToken is BaseToken {
    uint256 public feeBps;

    constructor(uint8 d, uint256 f) {
        _dec = d;
        feeBps = f;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        uint256 fee = (a * feeBps) / 10_000;
        balanceOf[f] -= a;
        balanceOf[t] += a - fee; // recipient (adapter) gets less
        return true;
    }
}

// Delivers the full amount on transferFrom but immediately burns 1 wei from the receiver,
// modelling a negative rebase that lands the adapter short.
contract ShrinkOnReceiveToken is BaseToken {
    constructor() {
        _dec = 6;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        balanceOf[t] -= 1; // rebase down on the receiver
        return true;
    }
}

// transferFrom / transfer return NOTHING (USDT-style). SafeERC20 must still accept it.
contract MissingReturnToken is BaseToken {
    constructor() {
        _dec = 6;
    }

    function transfer(address to, uint256 a) external {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
    }

    function transferFrom(address f, address t, uint256 a) external {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
    }
}

// transferFrom returns false instead of reverting; SafeERC20 must convert that to a revert.
contract ReturnsFalseToken is BaseToken {
    constructor() {
        _dec = 6;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

contract PausableToken is BaseToken {
    bool public paused;

    error TokenPaused();

    constructor() {
        _dec = 6;
    }

    function pause() external {
        paused = true;
    }

    function unpause() external {
        paused = false;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        if (paused) revert TokenPaused();
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (paused) revert TokenPaused();
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

contract BlacklistToken is BaseToken {
    mapping(address => bool) public blocked;

    error Blacklisted();

    constructor() {
        _dec = 6;
    }

    function blacklist(address a) external {
        blocked[a] = true;
    }

    function unblacklist(address a) external {
        blocked[a] = false;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        if (blocked[to] || blocked[msg.sender]) revert Blacklisted();
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (blocked[t] || blocked[f]) revert Blacklisted();
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

contract DecimalsRevertToken is BaseToken {
    error NoDecimals();

    function decimals() external pure override returns (uint8) {
        revert NoDecimals();
    }
}
