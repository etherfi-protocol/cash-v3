// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/Test.sol";

import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";
import { BinSponsor, Cashback, CashbackTokens, Mode } from "../../src/interfaces/ICashModule.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { LendDevTestBase } from "./LendDevTestBase.t.sol";

/**
 * @title LendDevFlowsTest
 * @notice Core engine and lifecycle flows of the Lend dev deployment, against the LIVE Optimism dev
 *         contracts on a fork: legacy-engine flows, migration, onboarding payloads, gateway spends and
 *         borrows, the opt-out lifecycle, and the extra deployed surfaces (cashback, top-up batch, hook).
 *         Module sandwiches live in LendDevModules.t.sol; withdrawal edges in LendDevWithdrawals.t.sol.
 */
contract LendDevFlowsTest is LendDevTestBase {
    // ----------------------------------------------------------------- deployed config

    /// The gateway must be a default module on every safe: its position-manager self-approval runs through
    /// execTransactionFromModule, and without this every gateway supply is silently left loose (best-effort)
    /// and every migration or credit spend reverts.
    function test_deployedConfig_gatewayIsDefaultModule() public view {
        assertTrue(gatewayWasDefaultModule, "LendGateway is not a default module on the live dataProvider");
    }

    // ----------------------------------------------------------------- 1. unmigrated safe keeps working

    /// An unmigrated safe still works as before: canSpend passes, a debit spend settles to the dispatcher,
    /// a borrow routes through the legacy DebtManager, and a withdrawal requests and processes.
    function test_legacySafe_spendBorrowAndWithdraw() public {
        address safe = _deploySafe("lend-dev-legacy", false);
        assertFalse(cashModule.usesLendGateway(safe), "safe onboarded legacy");

        // canSpend and a settling debit spend
        deal(address(usdc), safe, 1000e6);
        (bool ok, string memory reason) = cashLens.canSpend(safe, keccak256("legacy-spend"), _addr1(address(usdc)), _uint1(10e6));
        assertTrue(ok, reason);
        address dispatcher = cashModule.getSettlementDispatcher(BinSponsor.Reap);
        uint256 dispatcherBefore = usdc.balanceOf(dispatcher);
        vm.prank(devAdmin);
        cashModule.spend(safe, keccak256("legacy-spend"), BinSponsor.Reap, _addr1(address(usdc)), _uint1(10e6), _noCashback());
        assertEq(usdc.balanceOf(dispatcher), dispatcherBefore + 10e6, "debit spend settled to the dispatcher");

        // a legacy borrow still routes through DebtManager
        deal(address(weETH), safe, 1 ether);
        deal(address(usdc), address(debtManager), 100_000e6);
        uint256 borrowAmt = debtManager.getMaxBorrowAmount(safe, true) / 4;
        vm.prank(safe);
        debtManager.borrow(BinSponsor.Reap, address(usdc), borrowAmt);
        assertApproxEqAbs(debtManager.borrowingOf(safe, address(usdc)), borrowAmt, 1, "legacy debt on DebtManager");

        // a withdrawal requests and processes
        uint256 recipientBefore = usdc.balanceOf(recipient);
        _requestWithdrawal(safe, address(usdc), 50e6);
        vm.warp(block.timestamp + withdrawalDelay + 1);
        cashModule.processWithdrawal(safe);
        assertEq(usdc.balanceOf(recipient), recipientBefore + 50e6, "withdrawal paid out");
    }

    /// A credit spend on an unmigrated safe borrows through the legacy DebtManager: within the quoted
    /// capacity it settles to the dispatcher, and canSpend declines one above the capacity. Repay routes
    /// back through the DebtManager.
    function test_legacySafe_creditSpend() public {
        address safe = _deploySafe("lend-dev-legacy-credit", false);

        deal(address(weETH), safe, 1 ether);
        deal(address(usdc), address(debtManager), 100_000e6);
        _setMode(safe, Mode.Credit);
        vm.warp(block.timestamp + modeDelay + 1);

        uint256 capacity = cashLens.getMaxSpendCredit(safe);
        assertGt(capacity, 0, "legacy credit capacity quoted");
        (bool okAbove,) = cashLens.canSpend(safe, keccak256("legacy-credit-over"), _addr1(address(usdc)), _uint1(capacity + 10e6));
        assertFalse(okAbove, "a spend above capacity declines");

        (bool ok, string memory reason) = cashLens.canSpend(safe, keccak256("legacy-credit"), _addr1(address(usdc)), _uint1(capacity / 2));
        assertTrue(ok, reason);

        address dispatcher = cashModule.getSettlementDispatcher(BinSponsor.Reap);
        uint256 dispatcherBefore = usdc.balanceOf(dispatcher);
        vm.prank(devAdmin);
        cashModule.spend(safe, keccak256("legacy-credit"), BinSponsor.Reap, _addr1(address(usdc)), _uint1(capacity / 2), _noCashback());
        assertEq(usdc.balanceOf(dispatcher), dispatcherBefore + capacity / 2, "credit spend settled to the dispatcher");
        assertApproxEqAbs(debtManager.borrowingOf(safe, address(usdc)), capacity / 2, 1, "debt created on the legacy DebtManager");

        // repay routes back through the legacy DebtManager
        deal(address(usdc), safe, 20e6);
        uint256 debtBefore = debtManager.borrowingOf(safe, address(usdc));
        vm.prank(devAdmin);
        cashModule.repay(safe, address(usdc), 10e6);
        assertApproxEqAbs(debtManager.borrowingOf(safe, address(usdc)), debtBefore - 10e6, 1, "repay reduced the legacy debt");
    }

    /// A two-token debit spend on an unmigrated safe settles both tokens to the dispatcher.
    function test_legacySafe_multiTokenDebit() public {
        address safe = _deploySafe("lend-dev-legacy-multi", false);
        IERC20 usdt = IERC20(_reserveBySymbol("USDT"));
        deal(address(usdc), safe, 100e6);
        deal(address(usdt), safe, 100e6);

        address dispatcher = cashModule.getSettlementDispatcher(BinSponsor.Reap);
        uint256 dispatcherUsdcBefore = usdc.balanceOf(dispatcher);
        uint256 dispatcherUsdtBefore = usdt.balanceOf(dispatcher);

        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(usdt);
        uint256[] memory amountsInUsd = new uint256[](2);
        amountsInUsd[0] = 30e6;
        amountsInUsd[1] = 20e6;

        vm.prank(devAdmin);
        cashModule.spend(safe, keccak256("legacy-multi"), BinSponsor.Reap, tokens, amountsInUsd, _noCashback());
        assertEq(usdc.balanceOf(dispatcher), dispatcherUsdcBefore + 30e6, "USDC leg settled");
        assertGt(usdt.balanceOf(dispatcher), dispatcherUsdtBefore, "USDT leg settled");
    }

    /// The gateway-only entrypoints reject a legacy safe, so the engine gate holds on the deployed
    /// contracts: supplyToLend and the signed borrow page both revert.
    function test_legacySafe_gatewayEntrypointsRevert() public {
        address safe = _deploySafe("lend-dev-legacy-guard", false);
        deal(address(usdc), safe, 100e6);

        vm.prank(devAdmin);
        vm.expectRevert();
        cashModule.supplyToLend(safe, _addr1(address(usdc)));

        bytes[] memory sigs = _borrowSigs(safe, address(usdc), 10e6);
        vm.expectRevert();
        cashModule.borrow(safe, address(usdc), 10e6, _signers(), sigs);
    }

    // ----------------------------------------------------------------- 2. migration

    /// Migrating a legacy safe clears its DebtManager debt, recreates the position on Aave (same collateral,
    /// same debt), flips the routing flag, and permanently freezes legacy borrow/repay and re-migration.
    function test_migrateToLendGateway_movesPositionAndFreezesLegacy() public {
        _seedAaveUsdcLiquidity();
        address safe = _deploySafe("lend-dev-migrate", false);

        deal(address(weETH), safe, 1 ether);
        deal(address(usdc), address(debtManager), 100_000e6);
        uint256 borrowAmt = debtManager.getMaxBorrowAmount(safe, true) / 4;
        vm.prank(safe);
        debtManager.borrow(BinSponsor.Reap, address(usdc), borrowAmt);

        vm.prank(devAdmin);
        DebtManagerCore(address(debtManager)).migrateToLendGateway(safe);

        assertEq(debtManager.borrowingOf(safe, address(usdc)), 0, "legacy debt cleared");
        assertTrue(debtManager.hasMigratedToLendGateway(safe), "marked migrated");
        assertTrue(cashModule.usesLendGateway(safe), "routing flag flipped");
        assertTrue(cashModule.isLendActive(safe), "lend active");
        assertApproxEqAbs(gw.suppliedOf(safe, address(weETH)), 1 ether, 3, "collateral moved to Aave");
        assertApproxEqAbs(gw.debtOf(safe, address(usdc)), borrowAmt, 1e6, "debt recreated on Aave");

        // a second migrate reverts, and the legacy engine is frozen for this safe
        vm.prank(devAdmin);
        vm.expectRevert();
        DebtManagerCore(address(debtManager)).migrateToLendGateway(safe);
        vm.prank(safe);
        vm.expectRevert();
        debtManager.borrow(BinSponsor.Reap, address(usdc), 1e6);
        deal(address(usdc), address(this), 1e6);
        usdc.approve(address(debtManager), 1e6);
        vm.expectRevert();
        debtManager.repay(safe, address(usdc), 1e6);
    }

    /// Migrating an opted-out legacy safe marks it migrated without forcing its collateral into Aave:
    /// the balance stays loose in the safe.
    function test_migrate_optedOutSafe_marksWithoutSupplying() public {
        address safe = _deploySafe("lend-dev-migrate-optout", false);
        deal(address(weETH), safe, 1 ether);

        _toggleLend(safe, false);
        vm.warp(block.timestamp + modeDelay + 1);
        cashModule.processLendOptOut(safe);
        assertTrue(cashModule.isLendOptedOut(safe), "opt-out matured");

        vm.prank(devAdmin);
        DebtManagerCore(address(debtManager)).migrateToLendGateway(safe);

        assertTrue(debtManager.hasMigratedToLendGateway(safe), "marked migrated");
        assertEq(weETH.balanceOf(safe), 1 ether, "collateral stayed in the safe");
        assertEq(gw.suppliedOf(safe, address(weETH)), 0, "nothing supplied to Aave");
    }

    // ----------------------------------------------------------------- 3. onboarding payloads

    /// A fresh safe onboards onto the gateway with the four-field cash setup payload; the pre-upgrade
    /// three-field payload no longer decodes, so cash-be must send the new shape.
    function test_onboarding_fourFieldPayloadRequired() public {
        address safe = _deploySafe("lend-dev-onboard", true);
        assertTrue(cashModule.usesLendGateway(safe), "flagged safe lands on the gateway");

        // the pre-upgrade three-field payload no longer decodes
        bytes[] memory setupData = new bytes[](1);
        setupData[0] = abi.encode(DAILY_LIMIT_USD, MONTHLY_LIMIT_USD, TIMEZONE_OFFSET);
        vm.prank(devAdmin);
        vm.expectRevert();
        factory.deployEtherFiSafe("lend-dev-3field", _addr1(ownerA), _addr1(address(cashModule)), setupData, 1);
    }

    // ----------------------------------------------------------------- 4. gateway safe flows

    /// A top-up to a gateway safe is supplied straight to Aave instead of sitting loose in the safe.
    function test_topUp_landsAsAaveSupply() public {
        address safe = _deploySafe("lend-dev-topup", true);

        address keeper = makeAddr("lendDevTopUpKeeper");
        bytes32 topUpRole = topUpDest.TOP_UP_ROLE();
        vm.prank(devAdmin);
        registry.grantRole(topUpRole, keeper);

        deal(address(usdc), address(topUpDest), 100e6);
        vm.prank(keeper);
        topUpDest.topUpUserSafe(keccak256("lend-dev-topup-src"), safe, 1, address(usdc), 100e6);

        assertApproxEqAbs(gw.suppliedOf(safe, address(usdc)), 100e6, 2, "top-up supplied to Aave");
        assertEq(usdc.balanceOf(safe), 0, "nothing left loose");
    }

    /// A keeper batch mixing engines never bricks: the gateway safe's top-up supplies to Aave while the
    /// opted-out safe's stays loose, in the same transaction.
    function test_topUpBatch_mixedEngines() public {
        address gwSafe = _deploySafe("lend-dev-batch-gw", true);
        address optedOut = _deploySafe("lend-dev-batch-optout", true);
        _toggleLend(optedOut, false);
        vm.warp(block.timestamp + modeDelay + 1);
        cashModule.processLendOptOut(optedOut);

        address keeper = makeAddr("lendDevBatchKeeper");
        bytes32 topUpRole = topUpDest.TOP_UP_ROLE();
        vm.prank(devAdmin);
        registry.grantRole(topUpRole, keeper);
        deal(address(usdc), address(topUpDest), 100e6);

        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256("batch-src-1");
        hashes[1] = keccak256("batch-src-2");
        address[] memory users = new address[](2);
        users[0] = gwSafe;
        users[1] = optedOut;
        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = 1;
        chainIds[1] = 1;
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(usdc);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 50e6;

        vm.prank(keeper);
        topUpDest.topUpUserSafeBatch(hashes, users, chainIds, tokens, amounts);

        assertApproxEqAbs(gw.suppliedOf(gwSafe, address(usdc)), 50e6, 2, "gateway safe supplied");
        assertEq(usdc.balanceOf(optedOut), 50e6, "opted-out safe kept it loose");
    }

    /// A debit spend is funded from the safe's Aave supply, a credit spend within the quoted capacity
    /// borrows on Aave, and canSpend declines one above the capacity.
    function test_spend_debitAndCreditWithCapacityDecline() public {
        _seedAaveUsdcLiquidity();
        address safe = _deploySafe("lend-dev-spend", true);

        // debit: supplied USDC funds the spend
        deal(address(usdc), safe, 200e6);
        vm.prank(devAdmin);
        cashModule.supplyToLend(safe, _addr1(address(usdc)));
        address dispatcher = cashModule.getSettlementDispatcher(BinSponsor.Reap);
        uint256 dispatcherBefore = usdc.balanceOf(dispatcher);
        uint256 suppliedBefore = gw.suppliedOf(safe, address(usdc));
        vm.prank(devAdmin);
        cashModule.spend(safe, keccak256("gw-debit"), BinSponsor.Reap, _addr1(address(usdc)), _uint1(20e6), _noCashback());
        assertEq(usdc.balanceOf(dispatcher), dispatcherBefore + 20e6, "debit spend settled");
        assertApproxEqAbs(gw.suppliedOf(safe, address(usdc)), suppliedBefore - 20e6, 2, "funded from Aave supply");

        // credit: within the quoted capacity settles, one above it declines
        deal(address(weETH), safe, 1 ether);
        vm.prank(devAdmin);
        cashModule.supplyToLend(safe, _addr1(address(weETH)));
        _setMode(safe, Mode.Credit);
        vm.warp(block.timestamp + modeDelay + 1);

        uint256 capacity = cashLens.getMaxSpendCredit(safe);
        assertGt(capacity, 0, "credit capacity quoted");
        (bool okAbove,) = cashLens.canSpend(safe, keccak256("gw-credit-over"), _addr1(address(usdc)), _uint1(capacity + 10e6));
        assertFalse(okAbove, "a spend above capacity declines");

        uint256 debtBefore = gw.debtOf(safe, address(usdc));
        vm.prank(devAdmin);
        cashModule.spend(safe, keccak256("gw-credit"), BinSponsor.Reap, _addr1(address(usdc)), _uint1(capacity / 2), _noCashback());
        assertApproxEqAbs(gw.debtOf(safe, address(usdc)), debtBefore + capacity / 2, 2, "credit spend borrowed on Aave");
    }

    /// A spend carrying a cashback entry settles and routes the cashback through the CashbackDispatcher
    /// to the safe.
    function test_spend_withCashback() public {
        address safe = _deploySafe("lend-dev-cashback", true);
        deal(address(usdc), safe, 100e6);

        address cashbackToken = 0x4200000000000000000000000000000000000006; // WETH
        address cashbackDispatcher = stdJson.readAddress(baseJson, ".addresses.CashbackDispatcher");
        deal(cashbackToken, cashbackDispatcher, 1 ether);

        CashbackTokens[] memory safeTokens = new CashbackTokens[](1);
        safeTokens[0] = CashbackTokens({ token: cashbackToken, amountInUsd: 1e6, cashbackType: 0 });
        Cashback[] memory cashbacks = new Cashback[](1);
        cashbacks[0] = Cashback({ to: safe, cashbackTokens: safeTokens });

        uint256 safeCashbackBefore = IERC20(cashbackToken).balanceOf(safe);
        vm.prank(devAdmin);
        cashModule.spend(safe, keccak256("gw-cashback"), BinSponsor.Reap, _addr1(address(usdc)), _uint1(20e6), cashbacks);
        assertGt(IERC20(cashbackToken).balanceOf(safe), safeCashbackBefore, "cashback landed in the safe");
    }

    /// A signed borrow lands as Aave debt, repay reduces it, and once the position sits below the 1.05
    /// floor the next user-extraction op reverts (borrow if reachable, otherwise a sourcing withdrawal).
    function test_borrowRepay_andHealthFactorFloor() public {
        _seedAaveUsdcLiquidity();
        address safe = _deploySafe("lend-dev-borrow", true);

        deal(address(weETH), safe, 1 ether);
        vm.prank(devAdmin);
        cashModule.supplyToLend(safe, _addr1(address(weETH)));

        // a signed borrow lands as Aave debt (proceeds re-supplied by the borrow page)
        uint256 borrowUsd = gw.getAccountData(safe).availableBorrowsUsd / 4;
        cashModule.borrow(safe, address(usdc), borrowUsd, _signers(), _borrowSigs(safe, address(usdc), borrowUsd));
        assertApproxEqAbs(gw.debtOf(safe, address(usdc)), borrowUsd, 1e6, "signed borrow created Aave debt");

        // repay reduces the Aave debt
        deal(address(usdc), safe, 30e6);
        uint256 debtBefore = gw.debtOf(safe, address(usdc));
        vm.prank(devAdmin);
        cashModule.repay(safe, address(usdc), 20e6);
        assertApproxEqAbs(gw.debtOf(safe, address(usdc)), debtBefore - 20e6, 2, "repay reduced Aave debt");

        // the 1.05 floor: lever the position down via a driver borrow, then assert the floor blocks the
        // next user-extraction op. If the reserve's LT/LTV gap keeps a max-levered position above the
        // floor, the floor can only be crossed by a withdrawal, so assert it there instead.
        assertEq(gw.minHealthFactor(), FLOOR, "floor configured at 1.05");
        address driver = makeAddr("lendDevFloorDriver");
        vm.prank(devAdmin);
        gw.setDriver(driver, true);
        uint256 leverUsd = (gw.getAccountData(safe).availableBorrowsUsd * 99) / 100;
        vm.prank(driver);
        gw.borrow(safe, address(usdc), leverUsd, recipient);

        if (gw.getAccountData(safe).healthFactor < FLOOR) {
            bytes[] memory floorSigs = _borrowSigs(safe, address(usdc), 1e6);
            vm.expectRevert(LendGateway.HealthFactorBelowMinimum.selector);
            cashModule.borrow(safe, address(usdc), 1e6, _signers(), floorSigs);
        } else {
            console.log("max-levered HF sits above the floor; asserting the floor on the withdrawal path");
            uint256 max = cashLens.getMaxSourceable(safe, address(weETH));
            (address[] memory signers, bytes[] memory sigs) = _withdrawalSigs(safe, address(weETH), max);
            vm.expectRevert(LendGateway.HealthFactorBelowMinimum.selector);
            cashModule.requestWithdrawal(safe, _addr1(address(weETH)), _uint1(max), recipient, signers, sigs);
        }
    }

    /// A withdrawal larger than the loose balance pulls the shortfall from the safe's Aave supply,
    /// then pays out in full after the delay.
    function test_withdrawal_pullsShortfallFromAave() public {
        address safe = _deploySafe("lend-dev-withdraw", true);

        deal(address(usdc), safe, 100e6);
        vm.prank(devAdmin);
        cashModule.supplyToLend(safe, _addr1(address(usdc)));
        deal(address(usdc), safe, 10e6);

        uint256 suppliedBefore = gw.suppliedOf(safe, address(usdc));
        uint256 recipientBefore = usdc.balanceOf(recipient);
        _requestWithdrawal(safe, address(usdc), 50e6);
        assertApproxEqAbs(gw.suppliedOf(safe, address(usdc)), suppliedBefore - 40e6, 2, "shortfall pulled from Aave");

        vm.warp(block.timestamp + withdrawalDelay + 1);
        cashModule.processWithdrawal(safe);
        assertEq(usdc.balanceOf(recipient), recipientBefore + 50e6, "withdrawal paid out");
    }

    // ----------------------------------------------------------------- 5. opt-out lifecycle

    /// An opted-out safe never touches Aave: the opt-out matures after the delay, a top-up stays loose in
    /// the safe, supplyToLend is a no-op, and a debit spend still settles from the loose balance.
    function test_optOut_keepsFundsLooseAndSpendsStillWork() public {
        address safe = _deploySafe("lend-dev-optout", true);
        _toggleLend(safe, false);
        vm.warp(block.timestamp + modeDelay + 1);
        cashModule.processLendOptOut(safe);
        assertTrue(cashModule.isLendOptedOut(safe), "opt-out matured");

        bytes32 topUpRole = topUpDest.TOP_UP_ROLE();
        address keeper = makeAddr("lendDevOptOutKeeper");
        vm.prank(devAdmin);
        registry.grantRole(topUpRole, keeper);
        deal(address(usdc), address(topUpDest), 100e6);
        vm.prank(keeper);
        topUpDest.topUpUserSafe(keccak256("lend-dev-optout-src"), safe, 1, address(usdc), 100e6);
        assertEq(usdc.balanceOf(safe), 100e6, "top-up stayed loose");
        assertEq(gw.suppliedOf(safe, address(usdc)), 0, "nothing supplied to Aave");

        vm.prank(devAdmin);
        cashModule.supplyToLend(safe, _addr1(address(usdc)));
        assertEq(usdc.balanceOf(safe), 100e6, "sweep is a no-op while opted out");

        address dispatcher = cashModule.getSettlementDispatcher(BinSponsor.Reap);
        uint256 dispatcherBefore = usdc.balanceOf(dispatcher);
        vm.prank(devAdmin);
        cashModule.spend(safe, keccak256("optout-debit"), BinSponsor.Reap, _addr1(address(usdc)), _uint1(10e6), _noCashback());
        assertEq(usdc.balanceOf(dispatcher), dispatcherBefore + 10e6, "debit spend settled from the loose balance");
    }

    /// During the opt-out's pending window the safe is still opted in: sweeps keep supplying to Aave,
    /// and a mode change is blocked while the request is pending.
    function test_optOut_pendingWindowStaysOptedIn() public {
        vm.skip(modeDelay == 0);
        address safe = _deploySafe("lend-dev-optout-pending", true);
        deal(address(usdc), safe, 100e6);

        _toggleLend(safe, false);
        assertFalse(cashModule.isLendOptedOut(safe), "still opted in during the window");

        vm.prank(devAdmin);
        cashModule.supplyToLend(safe, _addr1(address(usdc)));
        assertApproxEqAbs(gw.suppliedOf(safe, address(usdc)), 100e6, 2, "sweep still supplies during the window");

        bytes memory modeSig = _setModeSig(safe, Mode.Credit);
        vm.expectRevert();
        cashModule.setMode(safe, Mode.Credit, ownerA, modeSig);
    }

    /// Opting back in is instant (no delay): the pending request clears and the next sweep supplies again.
    /// The matured opt-out first unwound the safe's Aave collateral back to the safe.
    function test_optOut_optBackInIsInstant() public {
        address safe = _deploySafe("lend-dev-optin", true);
        deal(address(usdc), safe, 100e6);
        vm.prank(devAdmin);
        cashModule.supplyToLend(safe, _addr1(address(usdc)));

        _toggleLend(safe, false);
        vm.warp(block.timestamp + modeDelay + 1);
        cashModule.processLendOptOut(safe);
        assertTrue(cashModule.isLendOptedOut(safe), "opt-out matured");
        assertApproxEqAbs(usdc.balanceOf(safe), 100e6, 2, "collateral unwound back to the safe");

        _toggleLend(safe, true);
        assertFalse(cashModule.isLendOptedOut(safe), "opted back in instantly");

        vm.prank(devAdmin);
        cashModule.supplyToLend(safe, _addr1(address(usdc)));
        assertApproxEqAbs(gw.suppliedOf(safe, address(usdc)), 100e6, 2, "sweep supplies again after opting back in");
    }

    /// An opt-out request is rejected while the safe has open Aave debt.
    function test_optOut_revertsWithOpenDebt() public {
        _seedAaveUsdcLiquidity();
        address safe = _deploySafe("lend-dev-optout-debt", true);
        deal(address(weETH), safe, 1 ether);
        vm.prank(devAdmin);
        cashModule.supplyToLend(safe, _addr1(address(weETH)));
        uint256 borrowUsd = gw.getAccountData(safe).availableBorrowsUsd / 4;
        cashModule.borrow(safe, address(usdc), borrowUsd, _signers(), _borrowSigs(safe, address(usdc), borrowUsd));
        assertGt(gw.debtOf(safe, address(usdc)), 0, "safe has Aave debt");

        bytes memory toggleSig = _toggleLendSig(safe, false);
        vm.expectRevert();
        cashModule.toggleLend(safe, false, ownerA, toggleSig);
    }

    // ----------------------------------------------------------------- 6. hook

    /// The deployed hook is wired and callable, and skips the DebtManager health check for gateway safes
    /// (their collateral lives inside Aave, which enforces health on every op).
    function test_hook_noopOnGatewaySafe() public {
        _seedAaveUsdcLiquidity();
        address safe = _deploySafe("lend-dev-hook", true);
        deal(address(weETH), safe, 1 ether);
        vm.prank(devAdmin);
        cashModule.supplyToLend(safe, _addr1(address(weETH)));
        uint256 borrowUsd = gw.getAccountData(safe).availableBorrowsUsd / 4;
        cashModule.borrow(safe, address(usdc), borrowUsd, _signers(), _borrowSigs(safe, address(usdc), borrowUsd));

        EtherFiHook hook = EtherFiHook(stdJson.readAddress(baseJson, ".addresses.EtherFiHook"));
        vm.prank(safe);
        hook.postOpHook(address(liquidModule));
    }
}
