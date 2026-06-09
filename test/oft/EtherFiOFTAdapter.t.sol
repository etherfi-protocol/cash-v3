// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IOFT } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { EtherFiOFTAdapter } from "../../src/oft/EtherFiOFTAdapter.sol";
import { MockERC20, MockFeeOnTransferERC20, OFTTestSetup } from "./OFTTestSetup.t.sol";

/* Test-only subclass that exposes the internal lock/unlock hooks (_debit/_credit) as external
   functions, so the lossless guard + lock/unlock can be tested directly without driving a full
   cross-chain send() (which our recording mock endpoint can't route). */
contract OFTAdapterHarness is EtherFiOFTAdapter {
    constructor(address ep, address reg) EtherFiOFTAdapter(ep, reg) { }

    function exposedDebit(address from, uint256 amt, uint256 minAmt, uint32 dstEid) external returns (uint256, uint256) {
        return _debit(from, amt, minAmt, dstEid);
    }

    function exposedCredit(address to, uint256 amt, uint32 srcEid) external returns (uint256) {
        return _credit(to, amt, srcEid);
    }
}

contract EtherFiOFTAdapterTest is OFTTestSetup {
    uint8 internal constant SHARED_DECIMALS = 6;

    // helper: deploy a real adapter via the factory (also exercises auto-sync).
    function _deployAdapterViaFactory(address token) internal returns (EtherFiOFTAdapter) {
        vm.prank(factoryAdmin);
        // salt convention = keccak256(underlying); factory dedupes one adapter per token
        address adapter = adapterFactory.deployAdapter(keccak256(abi.encode(token)), token, delegate);
        return EtherFiOFTAdapter(adapter);
    }

    // helper: an UNinitialized adapter proxy so we can call initialize() directly and catch its reverts.
    function _uninitializedAdapter() internal returns (EtherFiOFTAdapter) {
        return EtherFiOFTAdapter(address(new BeaconProxy(adapterFactory.beacon(), "")));
    }

    /* helper: deploy a harness-backed adapter (its own beacon) initialized for `token`, so we can
       reach the internal _debit/_credit hooks. */
    function _deployHarness(address token) internal returns (OFTAdapterHarness h) {
        address impl = address(new OFTAdapterHarness(address(endpoint), address(configRegistry)));
        UpgradeableBeacon beacon = new UpgradeableBeacon(impl, owner);
        bytes memory initData = abi.encodeWithSelector(EtherFiOFTAdapter.initialize.selector, token, delegate);
        h = OFTAdapterHarness(address(new BeaconProxy(address(beacon), initData)));
    }

    // ----------------------------------------------------------------- decimal math

    // The per-proxy conversion rate is 10**(tokenDecimals - 6): USDC(6)->1, WBTC(8)->100, PAXG(18)->1e12.
    function test_conversionRate_perDecimals() public {
        assertEq(_deployAdapterViaFactory(address(token6)).conversionRate(), 1);
        assertEq(_deployAdapterViaFactory(address(token8)).conversionRate(), 100);
        assertEq(_deployAdapterViaFactory(address(token18)).conversionRate(), 1e12);
    }

    // token() returns the underlying ERC-20 this adapter locks.
    function test_token_returnsUnderlying() public {
        EtherFiOFTAdapter a = _deployAdapterViaFactory(address(token6));
        assertEq(a.token(), address(token6));
    }

    // approvalRequired() is true — it's a lock adapter, so the user must approve it to pull the token.
    function test_approvalRequired_isTrue() public {
        assertTrue(_deployAdapterViaFactory(address(token6)).approvalRequired());
    }

    // Documents the known wart: the inherited auto-getter returns the dead placeholder rate
    // (10**(18-6)=1e12), while conversionRate() is the real per-proxy rate. External readers
    // must use conversionRate(); internal math is correct (it reads storage via the overrides).
    function test_inheritedDecimalConversionRateGetter_isPlaceholderWart() public {
        EtherFiOFTAdapter a = _deployAdapterViaFactory(address(token6));
        assertEq(a.conversionRate(), 1); // correct, per-proxy
        assertEq(a.decimalConversionRate(), 1e12); // placeholder (18 decimals) — the wart
    }

    // ----------------------------------------------------------------- init guards

    // initialize rejects a zero underlying token.
    function test_initialize_reverts_onZeroToken() public {
        EtherFiOFTAdapter a = _uninitializedAdapter();
        vm.expectRevert(EtherFiOFTAdapter.InvalidAddress.selector);
        a.initialize(address(0), delegate);
    }

    // initialize rejects a zero delegate.
    function test_initialize_reverts_onZeroDelegate() public {
        EtherFiOFTAdapter a = _uninitializedAdapter();
        vm.expectRevert(EtherFiOFTAdapter.InvalidAddress.selector);
        a.initialize(address(token6), address(0));
    }

    // initialize rejects an underlying with fewer than 6 decimals (e.g. GUSD=2) — out of scope.
    function test_initialize_reverts_belowSharedDecimals() public {
        MockERC20 token2 = new MockERC20("Gemini Dollar", "GUSD", 2);
        EtherFiOFTAdapter a = _uninitializedAdapter();
        vm.expectRevert(IOFT.InvalidLocalDecimals.selector);
        a.initialize(address(token2), delegate);
    }

    // ----------------------------------------------------------------- lock (debit) / unlock (credit)

    // _debit locks a normal (lossless) token: pulls exactly `amt` from the user into the adapter.
    function test_debit_locksLosslessToken() public {
        OFTAdapterHarness h = _deployHarness(address(token6));
        uint256 amt = 1000e6;
        token6.mint(alice, amt);

        vm.prank(alice);
        token6.approve(address(h), amt); // adapter pulls via transferFrom, so user approves it

        (uint256 sent, uint256 received) = h.exposedDebit(alice, amt, 0, DST_EID_OP);
        assertEq(sent, amt); // no fee in our adapter -> sent == received
        assertEq(received, amt);
        assertEq(token6.balanceOf(address(h)), amt); // tokens now locked in the adapter
        assertEq(token6.balanceOf(alice), 0);
    }

    // _debit reverts on a fee-on-transfer token: the adapter receives less than it pulled, which
    // would under-collateralize the mirror, so the lossless guard reverts instead.
    function test_debit_reverts_onFeeOnTransfer() public {
        MockFeeOnTransferERC20 feeToken = new MockFeeOnTransferERC20(6, 10); // 0.10% fee
        OFTAdapterHarness h = _deployHarness(address(feeToken));
        uint256 amt = 1000e6;
        feeToken.mint(alice, amt);

        vm.prank(alice);
        feeToken.approve(address(h), amt);

        uint256 fee = (amt * 10) / 10_000; // what the token skims on transfer
        // guard reverts with (expected=amt, received=amt-fee)
        vm.expectRevert(abi.encodeWithSelector(EtherFiOFTAdapter.NonLosslessTransfer.selector, amt, amt - fee));
        h.exposedDebit(alice, amt, 0, DST_EID_OP);
    }

    // _credit unlocks: transfers the adapter's held underlying out to the recipient.
    function test_credit_unlocksToRecipient() public {
        OFTAdapterHarness h = _deployHarness(address(token6));
        uint256 amt = 500e6;
        token6.mint(address(h), amt); // simulate a previously locked balance

        uint256 got = h.exposedCredit(alice, amt, DST_EID_OP);
        assertEq(got, amt);
        assertEq(token6.balanceOf(alice), amt); // recipient received the unlocked tokens
        assertEq(token6.balanceOf(address(h)), 0);
    }
}
