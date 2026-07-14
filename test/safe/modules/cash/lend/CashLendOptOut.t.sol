// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { BinSponsor, Cashback, ICashModule, Mode } from "../../../../../src/interfaces/ICashModule.sol";
import { ILendGateway } from "../../../../../src/interfaces/ILendGateway.sol";
import { CashVerificationLib } from "../../../../../src/libraries/CashVerificationLib.sol";
import { SignatureUtils } from "../../../../../src/libraries/SignatureUtils.sol";
import { CashEventEmitter } from "../../../../../src/modules/cash/CashEventEmitter.sol";
import { LendGateway } from "../../../../../src/modules/lend-gateway/LendGateway.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title CashLendOptOutTest
 * @notice Fork tests for the lend opt-out toggle: a safe with no open borrows can request to leave the Aave
 *         market via toggleLend(false), and after the mode-change delay execute it via processLendOptOut —
 *         pulling ALL its collateral out of Aave back into the safe, forcing Debit mode, and blocking every
 *         further lend op (auto-supply / borrow) until it opts back in with toggleLend(true). Runs against a
 *         REAL Aave v4 instance deployed in-test on an Optimism fork, driven by the real ether.fi stack
 *         (CashModule, LendGateway, EtherFiSafe) — no mocks.
 * @dev Run with: source .env && FOUNDRY_PROFILE=lend TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path test/safe/modules/cash/lend/CashLendOptOut.t.sol
 */
contract CashLendOptOutTest is CashGatewayTestSetup {
    using MessageHashUtils for bytes32;

    uint64 internal constant MODE_DELAY = 10; // mirrors the "takes ~10 seconds" opt-out spec

    function setUp() public override {
        super.setUp();

        // A real mode delay, so the opt-out request and its execution are separated in time
        vm.prank(owner);
        cashModule.setDelays(1, 3600, MODE_DELAY);
    }

    // ----------------------------------------------------------------- wiring & defaults

    /// @notice The gateway is wired once during setup and cannot be repointed (role/zero/codeless guards live in SetLendGateway.t.sol).
    function test_lendGateway_wiredOnceAndImmutable() public {
        assertEq(address(cashModule.getLendGateway()), address(gw));

        vm.prank(owner);
        vm.expectRevert(ICashModule.GatewayAlreadySet.selector);
        cashModule.setLendGateway(address(gw));
    }

    /// A fresh safe starts with lend enabled and no pending disable.
    function test_lendActiveByDefault() public view {
        assertTrue(cashModule.isLendActive(address(safe)), "lend active by default");
        assertFalse(cashModule.isLendOptedOut(address(safe)), "not opted out by default");
        assertEq(cashModule.lendOptOutFinalizeTime(address(safe)), 0, "no pending disable");
    }

    // ----------------------------------------------------------------- happy path

    /// Executing the opt-out pulls all Aave collateral into the safe, forces Debit, and blocks every later lend op.
    function test_processLendOptOut_withdrawsCollateralForcesDebitAndBlocksLend() public {
        // Position: 5 weETH supplied as collateral on Aave, no debt
        deal(address(weETH), address(safe), 5 ether);
        vm.startPrank(driver);
        gw.supply(address(safe), address(weETH), 5 ether);
        gw.setUsingAsCollateral(address(safe), address(weETH), true);
        vm.stopPrank();
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(weETH)), 5 ether, 2, "collateral on Aave");

        // Request the opt-out (owner-signed); it becomes executable after MODE_DELAY
        uint256 expectedFinalize = block.timestamp + MODE_DELAY;
        vm.expectEmit(true, false, false, true, address(cashEventEmitter));
        emit CashEventEmitter.LendOptOutRequested(address(safe), expectedFinalize);
        _requestOptOut();
        assertEq(cashModule.lendOptOutFinalizeTime(address(safe)), expectedFinalize, "finalize time recorded");
        assertTrue(cashModule.isLendActive(address(safe)), "still active until executed");

        // Execute after the delay: permissionless
        vm.warp(block.timestamp + MODE_DELAY);
        vm.expectEmit(true, false, false, false, address(cashEventEmitter));
        emit CashEventEmitter.LendOptOutExecuted(address(safe));
        cashModule.processLendOptOut(address(safe));

        // Collateral pulled back into the safe; Aave position emptied
        assertApproxEqAbs(weETH.balanceOf(address(safe)), 5 ether, 2, "collateral back in safe");
        assertLe(gw.suppliedOf(address(safe), address(weETH)), 2, "nothing left on Aave");
        // Lend now off everywhere, mode forced to Debit, pending cleared
        assertFalse(cashModule.isLendActive(address(safe)), "lend no longer active");
        assertTrue(cashModule.isLendOptedOut(address(safe)), "safe opted out");
        assertEq(uint8(cashModule.getMode(address(safe))), uint8(Mode.Debit), "forced to Debit");
        assertEq(cashModule.lendOptOutFinalizeTime(address(safe)), 0, "pending cleared");

        // Every lend op through the gateway is now rejected
        deal(address(weETH), address(safe), 1 ether);
        vm.startPrank(driver);
        vm.expectRevert(LendGateway.LendOptedOut.selector);
        gw.supply(address(safe), address(weETH), 1 ether);
        vm.expectRevert(LendGateway.LendOptedOut.selector);
        gw.borrow(address(safe), address(usdc), 1e6, driver);
        vm.expectRevert(LendGateway.LendOptedOut.selector);
        gw.setUsingAsCollateral(address(safe), address(weETH), true);
        vm.stopPrank();
    }

    /// Opting out from Credit mode drops the safe back to Debit.
    function test_processLendOptOut_forcesDebitFromCreditMode() public {
        // Move the safe into Credit mode first (no borrows), then opt out
        _setModeCredit();
        assertEq(uint8(cashModule.getMode(address(safe))), uint8(Mode.Credit), "in credit mode");

        _requestOptOut();
        vm.warp(block.timestamp + MODE_DELAY);
        cashModule.processLendOptOut(address(safe));

        assertEq(uint8(cashModule.getMode(address(safe))), uint8(Mode.Debit), "credit dropped to debit");
    }

    /// Opting out with no Aave position just flips the flag and forces Debit.
    function test_processLendOptOut_noCollateral_marksOptedOut() public {
        // No Aave position at all: opting out is still valid and just flips the flag
        _requestOptOut();
        vm.warp(block.timestamp + MODE_DELAY);
        cashModule.processLendOptOut(address(safe));

        assertTrue(cashModule.isLendOptedOut(address(safe)), "opted out with no collateral");
        assertEq(uint8(cashModule.getMode(address(safe))), uint8(Mode.Debit));
    }

    /// @dev A legacy-engine safe's opt-out is just the flag plus forced Debit: its funds are already loose,
    ///      so nothing is unwound from Aave. This is the pre-migration opt-out lever.
    function test_processLendOptOut_legacySafe_optsOutWithoutTouchingGateway() public {
        _forceLegacyEngine(address(safe));
        deal(address(weETH), address(safe), 5 ether);

        _requestOptOut();
        vm.warp(block.timestamp + MODE_DELAY);
        cashModule.processLendOptOut(address(safe));

        assertTrue(cashModule.isLendOptedOut(address(safe)), "legacy safe opted out");
        assertEq(uint8(cashModule.getMode(address(safe))), uint8(Mode.Debit), "forced to debit");
        assertEq(weETH.balanceOf(address(safe)), 5 ether, "funds stayed loose in the safe");
    }

    /// @dev A legacy safe with open DebtManager debt cannot opt out: the borrow check counts both engines.
    function test_requestLendOptOut_legacySafe_revertsWithOpenDebtManagerBorrow() public {
        _forceLegacyEngine(address(safe));
        deal(address(weETH), address(safe), 5 ether);
        deal(address(usdc), address(debtManager), 100_000e6);
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), 100e6);

        (address signer, bytes memory sig) = _toggleLendSig(false);
        vm.expectRevert(ICashModule.HasOpenBorrows.selector);
        cashModule.toggleLend(address(safe), false, signer, sig);
    }

    // ----------------------------------------------------------------- disable-request guards

    /// Requesting the opt-out reverts when the safe has an open Aave borrow.
    function test_requestLendOptOut_revertsWithOpenAaveBorrow() public {
        // Open an Aave borrow so the safe has debt
        deal(address(weETH), address(safe), 5 ether);
        vm.startPrank(driver);
        gw.supply(address(safe), address(weETH), 5 ether);
        gw.setUsingAsCollateral(address(safe), address(weETH), true);
        gw.borrow(address(safe), address(usdc), 1000e6, driver);
        vm.stopPrank();

        (address signer, bytes memory sig) = _toggleLendSig(false);
        vm.expectRevert(ICashModule.HasOpenBorrows.selector);
        cashModule.toggleLend(address(safe), false, signer, sig);
    }

    /// A second opt-out request reverts while one is already pending.
    function test_requestLendOptOut_revertsWhenAlreadyPending() public {
        _requestOptOut();

        (address signer, bytes memory sig) = _toggleLendSig(false);
        vm.expectRevert(ICashModule.LendAlreadyOptedOut.selector);
        cashModule.toggleLend(address(safe), false, signer, sig);
    }

    /// Requesting the opt-out reverts when lend is already disabled.
    function test_requestLendOptOut_revertsWhenAlreadyOptedOut() public {
        _requestOptOut();
        vm.warp(block.timestamp + MODE_DELAY);
        cashModule.processLendOptOut(address(safe));

        (address signer, bytes memory sig) = _toggleLendSig(false);
        vm.expectRevert(ICashModule.LendAlreadyOptedOut.selector);
        cashModule.toggleLend(address(safe), false, signer, sig);
    }

    /// toggleLend reverts when the named signer is not a safe admin.
    function test_toggleLend_rejectsNonAdminSigner() public {
        (, bytes memory sig) = _toggleLendSig(false);
        vm.expectRevert(ICashModule.OnlySafeAdmin.selector);
        cashModule.toggleLend(address(safe), false, makeAddr("notAdmin"), sig);
    }

    /// toggleLend reverts when an admin is named but the signature is from the wrong key.
    function test_toggleLend_rejectsBadSignature() public {
        // Correct signer (an admin) but signed by the wrong key
        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.TOGGLE_LEND_METHOD, block.chainid, address(safe), nonce, abi.encode(false))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner2Pk, digest); // owner2 signs, but we claim owner1
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(SignatureUtils.InvalidSigner.selector);
        cashModule.toggleLend(address(safe), false, owner1, sig);
    }

    /// A signature for disable cannot be replayed to enable (the flag is bound into the digest).
    function test_toggleLend_signatureBindsEnableFlag() public {
        // A signature authorizing disable (enable=false) must not be accepted for enable (enable=true)
        (address signer, bytes memory sig) = _toggleLendSig(false);
        vm.expectRevert(SignatureUtils.InvalidSigner.selector);
        cashModule.toggleLend(address(safe), true, signer, sig);
    }

    // ----------------------------------------------------------------- execute (processLendOptOut) guards

    /// processLendOptOut reverts when there is no pending request.
    function test_processLendOptOut_revertsWhenNoPending() public {
        vm.expectRevert(ICashModule.NoPendingLendOptOut.selector);
        cashModule.processLendOptOut(address(safe));
    }

    /// processLendOptOut reverts while still inside the mode-change delay.
    function test_processLendOptOut_revertsWhenNotReady() public {
        _requestOptOut();
        // Still inside the delay window
        vm.expectRevert(ICashModule.LendOptOutNotReady.selector);
        cashModule.processLendOptOut(address(safe));
    }

    /// processLendOptOut reverts if a borrow was opened during the delay window.
    function test_processLendOptOut_revertsWhenBorrowTakenDuringDelay() public {
        // Request with no debt, then take an Aave borrow during the delay window
        _requestOptOut();

        deal(address(weETH), address(safe), 5 ether);
        vm.startPrank(driver);
        gw.supply(address(safe), address(weETH), 5 ether);
        gw.setUsingAsCollateral(address(safe), address(weETH), true);
        gw.borrow(address(safe), address(usdc), 1000e6, driver);
        vm.stopPrank();

        vm.warp(block.timestamp + MODE_DELAY);
        vm.expectRevert(ICashModule.HasOpenBorrows.selector);
        cashModule.processLendOptOut(address(safe));
    }

    /// @dev Dust debt (sub-$0.000001) floors to zero in getAccountData's 6-decimal debtUsd, so the open-borrows
    ///      check must look at the raw per-asset debtOf instead, else disable would proceed and later revert
    ///      deep in Aave when withdrawing the collateral. Injects 1 wei of raw debt via a mocked debtOf on the
    ///      wired gateway; there is no real Aave position, so the USD aggregate still floors to zero.
    function test_requestLendOptOut_revertsOnDustDebtBelowUsdFloor() public {
        vm.mockCall(address(gw), abi.encodeWithSelector(ILendGateway.debtOf.selector, address(safe), address(weETH)), abi.encode(uint256(1)));

        // Premise of the test: the USD aggregate floors this dust to zero, so only the raw debtOf check catches it
        assertEq(gw.getAccountData(address(safe)).debtUsd, 0, "dust floors to zero USD");

        (address signer, bytes memory sig) = _toggleLendSig(false);
        vm.expectRevert(ICashModule.HasOpenBorrows.selector);
        cashModule.toggleLend(address(safe), false, signer, sig);
    }

    // ----------------------------------------------------------------- collateral-flag exit

    /// @dev Turning the collateral flag OFF is an exit action (like withdraw/repay), so it stays open to a
    ///      lend-disabled safe; only turning it ON is a lend op that a disabled safe is blocked from.
    function test_setUsingAsCollateralFalse_allowedWhenLendOptedOut() public {
        _requestOptOut();
        vm.warp(block.timestamp + MODE_DELAY);
        cashModule.processLendOptOut(address(safe));
        assertTrue(cashModule.isLendOptedOut(address(safe)));

        vm.startPrank(driver);
        gw.setUsingAsCollateral(address(safe), address(weETH), false); // must not revert
        vm.expectRevert(LendGateway.LendOptedOut.selector);
        gw.setUsingAsCollateral(address(safe), address(weETH), true);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- credit mode interaction

    /// A lend-disabled safe cannot switch into Credit mode.
    function test_afterOptOut_cannotEnterCreditMode() public {
        _requestOptOut();
        vm.warp(block.timestamp + MODE_DELAY);
        cashModule.processLendOptOut(address(safe));

        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.SET_MODE_METHOD, block.chainid, address(safe), nonce, abi.encode(Mode.Credit))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(ICashModule.LendOptedOut.selector);
        cashModule.setMode(address(safe), Mode.Credit, owner1, sig);
    }

    // ----------------------------------------------------------------- re-enable (toggleLend true)

    /// Re-enabling lend flips the flag back on and resumes auto-supply.
    function test_optInToLend_reenablesAndResumesSupply() public {
        _requestOptOut();
        vm.warp(block.timestamp + MODE_DELAY);
        cashModule.processLendOptOut(address(safe));
        assertTrue(cashModule.isLendOptedOut(address(safe)));

        vm.expectEmit(true, false, false, false, address(cashEventEmitter));
        emit CashEventEmitter.LendOptedIn(address(safe));
        _optIn();

        assertTrue(cashModule.isLendActive(address(safe)), "lend re-active (cash module)");
        assertFalse(cashModule.isLendOptedOut(address(safe)), "no longer opted out");

        // Auto-supply works again
        deal(address(weETH), address(safe), 2 ether);
        vm.prank(driver);
        gw.supply(address(safe), address(weETH), 2 ether);
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(weETH)), 2 ether, 2, "supply resumed");
    }

    /// Re-enabling reverts when lend was never disabled.
    function test_optInToLend_revertsWhenNotOptedOut() public {
        (address signer, bytes memory sig) = _toggleLendSig(true);
        vm.expectRevert(ICashModule.LendNotOptedOut.selector);
        cashModule.toggleLend(address(safe), true, signer, sig);
    }

    /// Re-enabling cancels a pending disable so it can no longer be executed.
    function test_optInToLend_cancelsPendingRequest() public {
        // A pending (not-yet-executed) request can be cancelled by re-enabling
        _requestOptOut();
        assertTrue(cashModule.lendOptOutFinalizeTime(address(safe)) != 0, "pending recorded");

        _optIn();
        assertEq(cashModule.lendOptOutFinalizeTime(address(safe)), 0, "pending cancelled");
        assertTrue(cashModule.isLendActive(address(safe)), "still active");

        // With the request cancelled, executing must revert
        vm.warp(block.timestamp + MODE_DELAY);
        vm.expectRevert(ICashModule.NoPendingLendOptOut.selector);
        cashModule.processLendOptOut(address(safe));
    }

    // ----------------------------------------------------------------- effective state & lazy processing

    /// isLendOptedOut / isLendActive report the opt-out as soon as the finalize time passes — before
    /// processLendOptOut runs — mirroring how getMode honors a matured incoming mode.
    function test_isLendOptedOut_effectiveOnceDelayElapses() public {
        _requestOptOut();
        assertFalse(cashModule.isLendOptedOut(address(safe)), "not opted out during the delay");
        assertTrue(cashModule.isLendActive(address(safe)), "still active during the delay");

        vm.warp(block.timestamp + MODE_DELAY);
        assertTrue(cashModule.isLendOptedOut(address(safe)), "effectively opted out at the finalize time");
        assertFalse(cashModule.isLendActive(address(safe)), "lend inactive at the finalize time");
        assertTrue(cashModule.lendOptOutFinalizeTime(address(safe)) != 0, "not yet processed");
    }

    /// A spend lazily executes a matured opt-out before routing: the collateral comes home, the flag is
    /// set, and the spend runs as a debit from the loose balance.
    function test_spend_processesMaturedOptOut() public {
        _supplyToGateway(address(safe), address(weETH), 5 ether);
        _requestOptOut();
        vm.warp(block.timestamp + MODE_DELAY);

        deal(address(usdc), address(safe), 100e6);

        vm.expectEmit(true, false, false, false, address(cashEventEmitter));
        emit CashEventEmitter.LendOptOutExecuted(address(safe));
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _tokens(address(usdc)), _amounts(50e6), _noCashback());

        assertTrue(cashModule.isLendOptedOut(address(safe)), "opted out");
        assertEq(cashModule.lendOptOutFinalizeTime(address(safe)), 0, "processed, not just matured");
        assertApproxEqAbs(weETH.balanceOf(address(safe)), 5 ether, 2, "collateral back in the safe");
        assertTrue(cashModule.transactionCleared(address(safe), txId), "spend went through");
    }

    /// A credit-mode safe with a matured opt-out spends as Debit: the lazy processing forces the mode
    /// before spend reads it, so no new Aave debt is ever taken.
    function test_spend_creditMode_maturedOptOut_routesDebit() public {
        _setModeCredit();
        _requestOptOut();
        vm.warp(block.timestamp + MODE_DELAY);

        deal(address(usdc), address(safe), 100e6);
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, _tokens(address(usdc)), _amounts(50e6), _noCashback());

        assertEq(uint8(cashModule.getMode(address(safe))), uint8(Mode.Debit), "forced to Debit");
        assertEq(gw.debtOf(address(safe), address(usdc)), 0, "no Aave debt taken");
        assertApproxEqAbs(usdc.balanceOf(address(safe)), 50e6, 1e5, "spent from the loose balance");
    }

    /// The auto-supply sweep lazily executes a matured opt-out and then skips supplying.
    function test_supplyToLend_processesMaturedOptOutAndSkips() public {
        _supplyToGateway(address(safe), address(weETH), 5 ether);
        _requestOptOut();
        vm.warp(block.timestamp + MODE_DELAY);

        deal(address(weETH), address(safe), 1 ether); // loose funds the sweep would otherwise supply

        vm.expectEmit(true, false, false, false, address(cashEventEmitter));
        emit CashEventEmitter.LendOptOutExecuted(address(safe));
        vm.prank(etherFiWallet);
        cashModule.supplyToLend(address(safe), _tokens(address(weETH)));

        assertLe(gw.suppliedOf(address(safe), address(weETH)), 2, "nothing supplied");
        assertApproxEqAbs(weETH.balanceOf(address(safe)), 6 ether, 2, "loose + returned collateral stay in the safe");
        assertTrue(cashModule.isLendOptedOut(address(safe)), "opted out");
        assertEq(cashModule.lendOptOutFinalizeTime(address(safe)), 0, "processed");
    }

    /// A borrow taken during the delay window blocks processing but not the effective state: the views
    /// report opted out, credit is blocked, and the repay that clears the debt completes the opt-out.
    function test_repay_completesOptOutBlockedByOpenBorrows() public {
        _requestOptOut();
        // Borrow during the delay window (allowed: the opt-out has not matured yet)
        _buildGatewayPosition(address(safe), address(weETH), 5 ether, address(usdc), 1000e6);

        vm.warp(block.timestamp + MODE_DELAY);
        assertTrue(cashModule.isLendOptedOut(address(safe)), "effectively opted out while debt blocks processing");

        // The explicit processor still reverts on open borrows
        vm.expectRevert(ICashModule.HasOpenBorrows.selector);
        cashModule.processLendOptOut(address(safe));

        // Repaying the debt completes the opt-out in the same call
        deal(address(usdc), address(safe), 2000e6);
        vm.expectEmit(true, false, false, false, address(cashEventEmitter));
        emit CashEventEmitter.LendOptOutExecuted(address(safe));
        vm.prank(etherFiWallet);
        cashModule.repay(address(safe), address(usdc), 1100e6); // over-quote; capped at the live debt

        assertEq(gw.debtOf(address(safe), address(usdc)), 0, "debt cleared");
        assertEq(cashModule.lendOptOutFinalizeTime(address(safe)), 0, "opt-out completed by the repay");
        assertApproxEqAbs(weETH.balanceOf(address(safe)), 5 ether, 2, "collateral unwound to the safe");
    }

    /// CashModule.borrow rejects a matured-but-unprocessed opt-out (the effective check).
    function test_borrow_revertsOnMaturedUnprocessedOptOut() public {
        _supplyToGateway(address(safe), address(weETH), 5 ether);
        _requestOptOut();
        vm.warp(block.timestamp + MODE_DELAY);

        (address[] memory signers, bytes[] memory sigs) = _borrowSig(address(usdc), 100e6);
        vm.expectRevert(ICashModule.LendOptedOut.selector);
        cashModule.borrow(address(safe), address(usdc), 100e6, signers, sigs);
    }

    /// setMode(Credit) is blocked while a matured opt-out awaits processing (the effective check).
    function test_setMode_maturedOptOut_blocksCredit() public {
        _requestOptOut();
        vm.warp(block.timestamp + MODE_DELAY);

        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.SET_MODE_METHOD, block.chainid, address(safe), nonce, abi.encode(Mode.Credit))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digest);

        vm.expectRevert(ICashModule.LendOptedOut.selector);
        cashModule.setMode(address(safe), Mode.Credit, owner1, abi.encodePacked(r, s, v));
    }

    /// The lens routes a credit-mode safe with a pending opt-out as Debit, matching the spend path's
    /// lazy processing (and the incoming-mode convention: pending counts, since the spend can settle
    /// after the request matures).
    function test_canSpendSingleToken_pendingOptOutForcesDebit() public {
        _supplyToGateway(address(safe), address(weETH), 5 ether);
        _setModeCredit();
        _requestOptOut();

        deal(address(usdc), address(safe), 100e6);
        (Mode mode,,,) = cashLens.canSpendSingleToken(address(safe), txId, _tokens(address(usdc)), _tokens(address(usdc)), 50e6);
        assertEq(uint8(mode), uint8(Mode.Debit), "pending opt-out routes as Debit");
    }

    /// Opting back in after the request matured (but before processing) cancels it — the collateral
    /// never left Aave and lend is immediately active again.
    function test_optInToLend_cancelsMaturedUnprocessedRequest() public {
        _supplyToGateway(address(safe), address(weETH), 5 ether);
        _requestOptOut();
        vm.warp(block.timestamp + MODE_DELAY);
        assertTrue(cashModule.isLendOptedOut(address(safe)), "effectively opted out");

        _optIn();
        assertFalse(cashModule.isLendOptedOut(address(safe)), "opt-out cancelled");
        assertTrue(cashModule.isLendActive(address(safe)), "lend active again");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(weETH)), 5 ether, 2, "collateral never left Aave");
    }

    // ----------------------------------------------------------------- signing helpers

    function _requestOptOut() internal {
        (address signer, bytes memory sig) = _toggleLendSig(false);
        cashModule.toggleLend(address(safe), false, signer, sig);
    }

    function _optIn() internal {
        (address signer, bytes memory sig) = _toggleLendSig(true);
        cashModule.toggleLend(address(safe), true, signer, sig);
    }

    function _toggleLendSig(bool enable) internal view returns (address signer, bytes memory sig) {
        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.TOGGLE_LEND_METHOD, block.chainid, address(safe), nonce, abi.encode(enable))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digest);
        return (owner1, abi.encodePacked(r, s, v));
    }

    function _setModeCredit() internal {
        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.SET_MODE_METHOD, block.chainid, address(safe), nonce, abi.encode(Mode.Credit))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digest);
        cashModule.setMode(address(safe), Mode.Credit, owner1, abi.encodePacked(r, s, v));
        // Credit takes effect after the mode delay
        vm.warp(block.timestamp + MODE_DELAY + 1);
    }

    /// @dev Builds the owner quorum (owner1 + owner2, the safe's threshold) signing a borrow intent.
    function _borrowSig(address token, uint256 amountInUsd) internal view returns (address[] memory, bytes[] memory) {
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.BORROW_METHOD, block.chainid, address(safe), safe.nonce(), abi.encode(token, amountInUsd))).toEthSignedMessageHash();
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digest);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        return (signers, signatures);
    }

    function _tokens(address token) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = token;
        return arr;
    }

    function _amounts(uint256 amount) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](1);
        arr[0] = amount;
        return arr;
    }

    function _noCashback() internal pure returns (Cashback[] memory) {
        return new Cashback[](0);
    }
}
