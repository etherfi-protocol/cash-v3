// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { BinSponsor, ICashModule, Mode } from "../../src/interfaces/ICashModule.sol";
import { ILendGateway } from "../../src/interfaces/ILendGateway.sol";
import { CashVerificationLib } from "../../src/libraries/CashVerificationLib.sol";
import { SignatureUtils } from "../../src/libraries/SignatureUtils.sol";
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { ChainlinkCompositePriceFeed } from "../../src/oracle/ChainlinkCompositePriceFeed.sol";
import { UpgradeableProxy } from "../../src/utils/UpgradeableProxy.sol";
import { CashModuleTestSetup } from "../safe/modules/cash/CashModuleTestSetup.t.sol";
import { AaveV4Fixture } from "./helpers/AaveV4Fixture.sol";

/**
 * @title CashLendDisableTest
 * @notice Fork tests for the lend opt-out toggle: a safe with no open borrows can request to leave the Aave
 *         market via toggleLend(false), and after the mode-change delay execute it via processLendDisable —
 *         pulling ALL its collateral out of Aave back into the safe, forcing Debit mode, and blocking every
 *         further lend op (auto-supply / borrow) until it opts back in with toggleLend(true). Runs against a
 *         REAL Aave v4 instance deployed in-test on an Optimism fork, driven by the real ether.fi stack
 *         (CashModule, LendGateway, EtherFiSafe) — no mocks.
 * @dev Run with: source .env && FOUNDRY_PROFILE=aave TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path test/lend-gateway/CashLendDisable.t.sol
 */
contract CashLendDisableTest is CashModuleTestSetup, AaveV4Fixture {
    using MessageHashUtils for bytes32;

    LendGateway internal gw;
    address internal driver = makeAddr("gwDriver"); // arranges Aave positions directly in tests

    uint256 internal usdcReserveId;
    uint256 internal weethReserveId;

    uint64 internal constant MODE_DELAY = 10; // mirrors the "takes ~10 seconds" opt-out spec

    function setUp() public override {
        super.setUp();

        // Real Aave v4 instance on the fork, weETH + USDC reserves priced by live Chainlink feeds
        _deployAaveV4();
        address weethSource = address(new ChainlinkCompositePriceFeed(IAggregatorV3(weEthWethOracle), IAggregatorV3(ethUsdcOracle), 8, 30 days, 30 days, "weETH / USD"));
        weethReserveId = _addAaveReserve(address(weETH), weethSource, 8000, false);
        usdcReserveId = _addAaveReserve(address(usdc), usdcUsdOracle, 8000, true);
        _seedAaveLiquidity(usdcReserveId, address(usdc), 1_000_000e6);

        // LendGateway proxy + wiring
        address gwImpl = address(new LendGateway(address(dataProvider), address(spoke)));
        gw = LendGateway(address(new UUPSProxy(gwImpl, abi.encodeWithSelector(LendGateway.initialize.selector, address(roleRegistry)))));

        vm.startPrank(owner);
        roleRegistry.grantRole(gw.LEND_GATEWAY_ADMIN_ROLE(), owner);
        dataProvider.configureModules(_addr1(address(gw)), _bool1(true));
        gw.setReserveId(address(weETH), weethReserveId);
        gw.setReserveId(address(usdc), usdcReserveId);
        gw.setDriver(driver, true);
        // Wire the CashModule to the real gateway (source of the collateral-withdraw path) and give a real mode delay
        cashModule.setLendGateway(address(gw));
        cashModule.setDelays(1, 3600, MODE_DELAY);
        vm.stopPrank();

        _enableModule(address(gw));
        _activateAavePositionManager(address(gw));
    }

    /// @dev Empty on purpose: skips the base mock-gateway wiring so this suite's one-time setLendGateway(gw) above is
    ///      the first and only set. Without this, that call would revert GatewayAlreadySet.
    function _wireDefaultGateway() internal override { }

    // ----------------------------------------------------------------- wiring & defaults

    /// @notice The gateway is wired once during setup and cannot be repointed (role/zero/codeless guards live in SetLendGateway.t.sol).
    function test_lendGateway_wiredOnceAndImmutable() public {
        assertEq(address(cashModule.getLendGateway()), address(gw));

        vm.prank(owner);
        vm.expectRevert(ICashModule.GatewayAlreadySet.selector);
        cashModule.setLendGateway(address(gw));
    }

    /// A fresh safe starts with lend enabled and no pending disable.
    function test_lendEnabledByDefault() public view {
        assertTrue(cashModule.isLendEnabled(address(safe)), "lend on by default (cash module)");
        assertTrue(gw.isLendEnabled(address(safe)), "lend on by default (gateway view)");
        assertEq(cashModule.lendDisableFinalizeTime(address(safe)), 0, "no pending disable");
    }

    // ----------------------------------------------------------------- happy path

    /// Executing the opt-out pulls all Aave collateral into the safe, forces Debit, and blocks every later lend op.
    function test_disableLend_withdrawsCollateralForcesDebitAndBlocksLend() public {
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
        emit CashEventEmitter.LendDisableRequested(address(safe), expectedFinalize);
        _requestDisable();
        assertEq(cashModule.lendDisableFinalizeTime(address(safe)), expectedFinalize, "finalize time recorded");
        assertTrue(cashModule.isLendEnabled(address(safe)), "still enabled until executed");

        // Execute after the delay: permissionless
        vm.warp(block.timestamp + MODE_DELAY);
        vm.expectEmit(true, false, false, false, address(cashEventEmitter));
        emit CashEventEmitter.LendDisableExecuted(address(safe));
        cashModule.processLendDisable(address(safe));

        // Collateral pulled back into the safe; Aave position emptied
        assertApproxEqAbs(weETH.balanceOf(address(safe)), 5 ether, 2, "collateral back in safe");
        assertLe(gw.suppliedOf(address(safe), address(weETH)), 2, "nothing left on Aave");
        // Lend now off everywhere, mode forced to Debit, pending cleared
        assertFalse(cashModule.isLendEnabled(address(safe)), "lend disabled (cash module)");
        assertFalse(gw.isLendEnabled(address(safe)), "lend disabled (gateway view)");
        assertEq(uint8(cashModule.getMode(address(safe))), uint8(Mode.Debit), "forced to Debit");
        assertEq(cashModule.lendDisableFinalizeTime(address(safe)), 0, "pending cleared");

        // Every lend op through the gateway is now rejected
        deal(address(weETH), address(safe), 1 ether);
        vm.startPrank(driver);
        vm.expectRevert(LendGateway.LendDisabled.selector);
        gw.supply(address(safe), address(weETH), 1 ether);
        vm.expectRevert(LendGateway.LendDisabled.selector);
        gw.borrow(address(safe), address(usdc), 1e6, driver);
        vm.expectRevert(LendGateway.LendDisabled.selector);
        gw.setUsingAsCollateral(address(safe), address(weETH), true);
        vm.stopPrank();
    }

    /// Opting out from Credit mode drops the safe back to Debit.
    function test_disableLend_forcesDebitFromCreditMode() public {
        // Move the safe into Credit mode first (no borrows), then opt out
        _setModeCredit();
        assertEq(uint8(cashModule.getMode(address(safe))), uint8(Mode.Credit), "in credit mode");

        _requestDisable();
        vm.warp(block.timestamp + MODE_DELAY);
        cashModule.processLendDisable(address(safe));

        assertEq(uint8(cashModule.getMode(address(safe))), uint8(Mode.Debit), "credit dropped to debit");
    }

    /// Opting out with no Aave position just flips the flag and forces Debit.
    function test_disableLend_noCollateral_marksDisabled() public {
        // No Aave position at all: opting out is still valid and just flips the flag
        _requestDisable();
        vm.warp(block.timestamp + MODE_DELAY);
        cashModule.processLendDisable(address(safe));

        assertFalse(cashModule.isLendEnabled(address(safe)), "disabled with no collateral");
        assertEq(uint8(cashModule.getMode(address(safe))), uint8(Mode.Debit));
    }

    /// @dev A legacy-engine safe's opt-out is just the flag plus forced Debit: its funds are already loose,
    ///      so nothing is unwound from Aave. This is the pre-migration opt-out lever.
    function test_disableLend_legacySafe_disablesWithoutTouchingGateway() public {
        _forceLegacyEngine(address(safe));
        deal(address(weETH), address(safe), 5 ether);

        _requestDisable();
        vm.warp(block.timestamp + MODE_DELAY);
        cashModule.processLendDisable(address(safe));

        assertFalse(cashModule.isLendEnabled(address(safe)), "legacy safe disabled");
        assertEq(uint8(cashModule.getMode(address(safe))), uint8(Mode.Debit), "forced to debit");
        assertEq(weETH.balanceOf(address(safe)), 5 ether, "funds stayed loose in the safe");
    }

    /// @dev A legacy safe with open DebtManager debt cannot opt out: the borrow check counts both engines.
    function test_toggleLendDisable_legacySafe_revertsWithOpenDebtManagerBorrow() public {
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
    function test_toggleLendDisable_revertsWithOpenAaveBorrow() public {
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
    function test_toggleLendDisable_revertsWhenAlreadyPending() public {
        _requestDisable();

        (address signer, bytes memory sig) = _toggleLendSig(false);
        vm.expectRevert(ICashModule.LendAlreadyDisabled.selector);
        cashModule.toggleLend(address(safe), false, signer, sig);
    }

    /// Requesting the opt-out reverts when lend is already disabled.
    function test_toggleLendDisable_revertsWhenAlreadyDisabled() public {
        _requestDisable();
        vm.warp(block.timestamp + MODE_DELAY);
        cashModule.processLendDisable(address(safe));

        (address signer, bytes memory sig) = _toggleLendSig(false);
        vm.expectRevert(ICashModule.LendAlreadyDisabled.selector);
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

    // ----------------------------------------------------------------- execute (processLendDisable) guards

    /// processLendDisable reverts when there is no pending request.
    function test_processLendDisable_revertsWhenNoPending() public {
        vm.expectRevert(ICashModule.NoPendingLendDisable.selector);
        cashModule.processLendDisable(address(safe));
    }

    /// processLendDisable reverts while still inside the mode-change delay.
    function test_processLendDisable_revertsWhenNotReady() public {
        _requestDisable();
        // Still inside the delay window
        vm.expectRevert(ICashModule.LendDisableNotReady.selector);
        cashModule.processLendDisable(address(safe));
    }

    /// processLendDisable reverts if a borrow was opened during the delay window.
    function test_processLendDisable_revertsWhenBorrowTakenDuringDelay() public {
        // Request with no debt, then take an Aave borrow during the delay window
        _requestDisable();

        deal(address(weETH), address(safe), 5 ether);
        vm.startPrank(driver);
        gw.supply(address(safe), address(weETH), 5 ether);
        gw.setUsingAsCollateral(address(safe), address(weETH), true);
        gw.borrow(address(safe), address(usdc), 1000e6, driver);
        vm.stopPrank();

        vm.warp(block.timestamp + MODE_DELAY);
        vm.expectRevert(ICashModule.HasOpenBorrows.selector);
        cashModule.processLendDisable(address(safe));
    }

    /// @dev Dust debt (sub-$0.000001) floors to zero in getAccountData's 6-decimal debtUsd, so the open-borrows
    ///      check must look at the raw per-asset debtOf instead, else disable would proceed and later revert
    ///      deep in Aave when withdrawing the collateral. Injects 1 wei of raw debt via a mocked debtOf on the
    ///      wired gateway; there is no real Aave position, so the USD aggregate still floors to zero.
    function test_toggleLendDisable_revertsOnDustDebtBelowUsdFloor() public {
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
    function test_setUsingAsCollateralFalse_allowedWhenLendDisabled() public {
        _requestDisable();
        vm.warp(block.timestamp + MODE_DELAY);
        cashModule.processLendDisable(address(safe));
        assertFalse(cashModule.isLendEnabled(address(safe)));

        vm.startPrank(driver);
        gw.setUsingAsCollateral(address(safe), address(weETH), false); // must not revert
        vm.expectRevert(LendGateway.LendDisabled.selector);
        gw.setUsingAsCollateral(address(safe), address(weETH), true);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- credit mode interaction

    /// A lend-disabled safe cannot switch into Credit mode.
    function test_afterDisable_cannotEnterCreditMode() public {
        _requestDisable();
        vm.warp(block.timestamp + MODE_DELAY);
        cashModule.processLendDisable(address(safe));

        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.SET_MODE_METHOD, block.chainid, address(safe), nonce, abi.encode(Mode.Credit))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(ICashModule.LendDisabled.selector);
        cashModule.setMode(address(safe), Mode.Credit, owner1, sig);
    }

    // ----------------------------------------------------------------- re-enable (toggleLend true)

    /// Re-enabling lend flips the flag back on and resumes auto-supply.
    function test_enableLend_reenablesAndResumesSupply() public {
        _requestDisable();
        vm.warp(block.timestamp + MODE_DELAY);
        cashModule.processLendDisable(address(safe));
        assertFalse(cashModule.isLendEnabled(address(safe)));

        vm.expectEmit(true, false, false, false, address(cashEventEmitter));
        emit CashEventEmitter.LendEnabled(address(safe));
        _enable();

        assertTrue(cashModule.isLendEnabled(address(safe)), "lend re-enabled (cash module)");
        assertTrue(gw.isLendEnabled(address(safe)), "lend re-enabled (gateway view)");

        // Auto-supply works again
        deal(address(weETH), address(safe), 2 ether);
        vm.prank(driver);
        gw.supply(address(safe), address(weETH), 2 ether);
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(weETH)), 2 ether, 2, "supply resumed");
    }

    /// Re-enabling reverts when lend was never disabled.
    function test_enableLend_revertsWhenNotDisabled() public {
        (address signer, bytes memory sig) = _toggleLendSig(true);
        vm.expectRevert(ICashModule.LendNotDisabled.selector);
        cashModule.toggleLend(address(safe), true, signer, sig);
    }

    /// Re-enabling cancels a pending disable so it can no longer be executed.
    function test_enableLend_cancelsPendingRequest() public {
        // A pending (not-yet-executed) request can be cancelled by re-enabling
        _requestDisable();
        assertTrue(cashModule.lendDisableFinalizeTime(address(safe)) != 0, "pending recorded");

        _enable();
        assertEq(cashModule.lendDisableFinalizeTime(address(safe)), 0, "pending cancelled");
        assertTrue(cashModule.isLendEnabled(address(safe)), "still enabled");

        // With the request cancelled, executing must revert
        vm.warp(block.timestamp + MODE_DELAY);
        vm.expectRevert(ICashModule.NoPendingLendDisable.selector);
        cashModule.processLendDisable(address(safe));
    }

    // ----------------------------------------------------------------- signing helpers

    function _requestDisable() internal {
        (address signer, bytes memory sig) = _toggleLendSig(false);
        cashModule.toggleLend(address(safe), false, signer, sig);
    }

    function _enable() internal {
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

    // ----------------------------------------------------------------- module helpers

    function _enableModule(address module) internal {
        address[] memory modules = _addr1(module);
        bool[] memory shouldWhitelist = _bool1(true);
        bytes[] memory setupData = new bytes[](1);
        setupData[0] = "";
        _configureModules(modules, shouldWhitelist, setupData);
    }

    function _addr1(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _bool1(bool b) internal pure returns (bool[] memory arr) {
        arr = new bool[](1);
        arr[0] = b;
    }
}
