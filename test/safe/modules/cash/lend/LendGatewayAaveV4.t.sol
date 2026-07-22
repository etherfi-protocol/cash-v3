// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAaveV4Hub } from "../../../../../src/interfaces/IAaveV4Hub.sol";
import { IAaveV4Spoke } from "../../../../../src/interfaces/IAaveV4Spoke.sol";
import { ILendGateway } from "../../../../../src/interfaces/ILendGateway.sol";
import { ModuleBase } from "../../../../../src/modules/ModuleBase.sol";
import { LendGateway } from "../../../../../src/modules/lend-gateway/LendGateway.sol";
import { UpgradeableProxy } from "../../../../../src/utils/UpgradeableProxy.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ISpoke } from "aave-v4/spoke/interfaces/ISpoke.sol";

/**
 * @title LendGatewayAaveV4Test
 * @notice End-to-end LendGateway tests against a REAL Aave v4 instance deployed inside the test on an Optimism
 *         fork, driven by the REAL ether.fi stack (EtherFiSafe, EtherFiDataProvider, RoleRegistry,
 *         PriceProvider) — no mocks. Aave reserves are priced by live Optimism Chainlink feeds.
 * @dev Run with: source .env && FOUNDRY_PROFILE=lend TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path test/safe/modules/cash/lend/LendGatewayAaveV4.t.sol
 */
contract LendGatewayAaveV4Test is CashGatewayTestSetup {
    /// rawBorrowCapacity ignores the configured floor: it matches borrowCapacity with no floor set, and exceeds
    /// it once a 1.05 floor buffers the auth quote below Aave's raw 1.00 bound.
    function test_rawBorrowCapacity_ignoresConfiguredFloor() public {
        _buildGatewayPosition(address(safe), address(weETH), 1 ether, address(usdc), 100e6);

        assertEq(gw.rawBorrowCapacity(address(safe), address(usdc)), gw.borrowCapacity(address(safe), address(usdc)), "equal with no floor");

        vm.prank(owner);
        gw.setMinHealthFactor(1.05e18);
        assertGt(gw.rawBorrowCapacity(address(safe), address(usdc)), gw.borrowCapacity(address(safe), address(usdc)), "floor buffers the auth quote below raw");
    }

    /// The premium-debt term in _borrowCapacity is live: with collateralRisk on the collateral reserve, the
    /// safe's accrued premium counts toward debt exactly as Aave counts it. Omitting the term would overquote
    /// (the exact-max borrow would revert); double-counting would underquote (the +1-unit borrow would succeed).
    function test_borrowCapacity_countsAccruedPremiumDebt() public {
        // weETH carries a 20% collateral risk; set before the borrow so it snapshots a non-zero riskPremium
        vm.prank(aaveAdmin);
        spoke.updateReserveConfig(weethReserveId, ISpoke.ReserveConfig({ paused: false, frozen: false, borrowable: false, receiveSharesEnabled: true, collateralRisk: 2000 }));

        _buildGatewayPosition(address(safe), address(weETH), 1 ether, address(usdc), 400e6);
        vm.warp(block.timestamp + 20 days); // accrue drawn interest and, through it, premium debt

        uint256 premiumDebtRay = IAaveV4Spoke(address(spoke)).getUserPremiumDebtRay(usdcReserveId, address(safe));
        assertGt(premiumDebtRay, 0, "premium debt accrued");

        uint256 quote = gw.rawBorrowCapacity(address(safe), address(usdc));
        assertEq(gw.borrowCapacity(address(safe), address(usdc)), quote, "no floor set: buffered == raw");

        _borrowOnGateway(address(safe), address(usdc), quote, recipient);
        assertGe(IAaveV4Spoke(address(spoke)).getUserAccountData(address(safe)).healthFactor, 1e18, "exact quote lands at/above 1.00");

        vm.expectRevert();
        _borrowOnGateway(address(safe), address(usdc), 1, recipient);
    }

    // ----------------------------------------------------------------- registration & reads

    function test_registration_validatedAgainstSpoke() public {
        assertTrue(gw.isRegistered(address(weETH)));
        assertTrue(gw.isRegistered(address(usdc)));
        assertEq(gw.reserveIdOf(address(usdc)), usdcReserveId);

        // A reserveId whose underlying != the asset is rejected
        vm.prank(owner);
        vm.expectRevert(LendGateway.ReserveAssetMismatch.selector);
        gw.setReserveId(address(weETH), usdcReserveId);
    }

    /// An asset can move to another matching reserve while its current reserve is empty.
    function test_setReserveId_repointsEmptyReserve() public {
        IAaveV4Spoke.Reserve memory replacement = IAaveV4Spoke(address(spoke)).getReserve(usdcReserveId);
        replacement.underlying = address(weETH);
        vm.mockCall(address(spoke), abi.encodeWithSelector(IAaveV4Spoke.getReserve.selector, usdcReserveId), abi.encode(replacement));

        vm.prank(owner);
        gw.setReserveId(address(weETH), usdcReserveId);
        assertEq(gw.reserveIdOf(address(weETH)), usdcReserveId);
    }

    /// Re-registering the same reserve is harmless, but a live position prevents moving the asset to another reserve.
    function test_setReserveId_repointRequiresOldReserveEmpty() public {
        deal(address(weETH), address(safe), 1 ether);
        vm.prank(driver);
        gw.supply(address(safe), address(weETH), 1 ether);

        vm.prank(owner);
        gw.setReserveId(address(weETH), weethReserveId);
        assertEq(gw.reserveIdOf(address(weETH)), weethReserveId, "same reserve remains registered");

        // Model another Spoke reserve for the same underlying without deploying a second Hub in this focused test.
        IAaveV4Spoke.Reserve memory replacement = IAaveV4Spoke(address(spoke)).getReserve(usdcReserveId);
        replacement.underlying = address(weETH);
        vm.mockCall(address(spoke), abi.encodeWithSelector(IAaveV4Spoke.getReserve.selector, usdcReserveId), abi.encode(replacement));

        vm.prank(owner);
        vm.expectRevert(LendGateway.ReserveStillInUse.selector);
        gw.setReserveId(address(weETH), usdcReserveId);
    }

    function test_reads_ltvAndLiquidity() public view {
        // 80_00 bps -> 80e18 in ILendGateway's 100e18 scale
        assertEq(gw.ltv(address(usdc)), 80e18);
        assertEq(gw.ltv(address(weETH)), 80e18);
        // Seeded liquidity is withdrawable/borrowable cash
        assertGe(gw.withdrawalLiquidity(address(usdc)), 1_000_000e6);
    }

    /// withdrawalLiquidity reads shared Hub liquidity and returns zero when this Spoke cannot withdraw it.
    function test_reads_withdrawalLiquidity_usesHubLiquidityAndExecutionState() public {
        IAaveV4Spoke.Reserve memory reserve = IAaveV4Spoke(address(spoke)).getReserve(usdcReserveId);
        uint256 expectedLiquidity = 123_456e6;
        vm.mockCall(reserve.hub, abi.encodeWithSelector(IAaveV4Hub.getAssetLiquidity.selector, reserve.assetId), abi.encode(expectedLiquidity));

        assertEq(gw.withdrawalLiquidity(address(usdc)), expectedLiquidity);

        _setAaveReserveFrozen(usdcReserveId, true);
        assertEq(gw.withdrawalLiquidity(address(usdc)), expectedLiquidity, "freeze leaves withdrawals open");
        _setAaveReserveFrozen(usdcReserveId, false);

        _setAaveReservePaused(usdcReserveId, true);
        assertEq(gw.withdrawalLiquidity(address(usdc)), 0, "paused reserve blocks withdrawals");
        _setAaveReservePaused(usdcReserveId, false);

        _setAaveSpokeHalted(usdcReserveId, true);
        assertEq(gw.withdrawalLiquidity(address(usdc)), 0, "halted Hub Spoke blocks withdrawals");
    }

    /// borrowLiquidity is the credit-side liquidity gate: uncapped it equals withdrawalLiquidity, a finite drawCap
    /// caps it at the spoke's remaining borrow headroom, and a halted Hub spoke drives it to zero.
    function test_reads_borrowLiquidity_boundedByDrawCap() public {
        // Uncapped (fixture default): equals the withdrawable liquidity
        assertEq(gw.borrowLiquidity(address(usdc)), gw.withdrawalLiquidity(address(usdc)));

        // With no borrows yet, a 400k-token drawCap is the whole borrowable amount (< the 1M seeded cash)
        _setAaveSpokeCaps(usdcReserveId, type(uint40).max, 400_000);
        assertEq(gw.borrowLiquidity(address(usdc)), 400_000e6, "capped at remaining drawCap");
        assertGe(gw.withdrawalLiquidity(address(usdc)), 1_000_000e6, "withdraw side is unchanged by the borrow cap");

        // Hub execution counts reported deficit against the cap and rounds sub-unit deficit up.
        // 400_000e6 - ceil((25_000e6 * 1e27 + 1) / 1e27) = 374_999_999_999.
        uint256 assetId = spoke.getReserve(usdcReserveId).assetId;
        uint256 deficitRay = 25_000e6 * 1e27 + 1;
        vm.mockCall(address(hub), abi.encodeWithSelector(IAaveV4Hub.getSpokeDeficitRay.selector, assetId, address(spoke)), abi.encode(deficitRay));
        assertEq(gw.borrowLiquidity(address(usdc)), 374_999_999_999, "deficit reduces draw-cap room with ceil rounding");

        // Halting the spoke stops new borrows entirely
        _setAaveSpokeHalted(usdcReserveId, true);
        assertEq(gw.borrowLiquidity(address(usdc)), 0, "halted spoke cannot borrow");
    }

    /// isBorrowable/borrowableAssets read the reserve's borrowable flag on the Spoke: USDC's reserve allows
    /// borrowing, weETH's is collateral-only, and unregistered assets are never borrowable.
    function test_reads_borrowable() public view {
        assertTrue(gw.isBorrowable(address(usdc)));
        assertFalse(gw.isBorrowable(address(weETH)));
        assertFalse(gw.isBorrowable(address(0xdead)));

        address[] memory borrowable = gw.borrowableAssets();
        assertEq(borrowable.length, 1);
        assertEq(borrowable[0], address(usdc));
    }

    /// isBorrowable mirrors Aave's borrow gate: freezing or pausing a reserve makes it non-borrowable (and drops
    /// it from borrowableAssets), even though its borrowable flag is still set — so auth cannot pass a token the
    /// Spoke would then reject at the borrow.
    function test_reads_borrowable_frozenOrPausedIsNotBorrowable() public {
        _setAaveReserveFrozen(usdcReserveId, true);
        assertFalse(gw.isBorrowable(address(usdc)), "frozen reserve not borrowable");
        assertEq(gw.borrowLiquidity(address(usdc)), 0, "frozen reserve has no executable borrow capacity");
        assertEq(gw.borrowableAssets().length, 0, "frozen reserve dropped from list");
        _setAaveReserveFrozen(usdcReserveId, false);
        assertTrue(gw.isBorrowable(address(usdc)), "borrowable again after unfreeze");

        _setAaveReservePaused(usdcReserveId, true);
        assertFalse(gw.isBorrowable(address(usdc)), "paused reserve not borrowable");
        assertEq(gw.borrowLiquidity(address(usdc)), 0, "paused reserve has no executable borrow capacity");
        _setAaveReservePaused(usdcReserveId, false);
        assertTrue(gw.isBorrowable(address(usdc)), "borrowable again after unpause");
    }

    /// isSpendAsset (the debit gate) reads the admin spend set, not Aave's borrowable flag: USDC is a declared
    /// spend asset, weETH is a registered reserve that was never declared spendable, and the set tolerates a
    /// freeze (a debit only transfers and withdraws) while a pause blocks it.
    function test_reads_spendAsset_readsAdminSetToleratesFreezeNotPause() public {
        assertTrue(gw.isSpendAsset(address(usdc)));
        assertFalse(gw.isSpendAsset(address(weETH)), "registered but not a declared spend asset");
        assertFalse(gw.isSpendAsset(address(0xdead)));

        _setAaveReserveFrozen(usdcReserveId, true);
        assertTrue(gw.isSpendAsset(address(usdc)), "frozen reserve still spendable");
        assertEq(gw.spendAssets().length, 1, "stays in spendAssets while frozen");
        _setAaveReserveFrozen(usdcReserveId, false);

        _setAaveReservePaused(usdcReserveId, true);
        assertFalse(gw.isSpendAsset(address(usdc)), "paused reserve not spendable");
        assertEq(gw.spendAssets().length, 0, "dropped from spendAssets while paused");
    }

    /// Membership is decoupled from Aave's borrowable flag: turning USDC's borrowable flag off (so it is no
    /// longer credit-borrowable) leaves it a debit-spend asset, which is the whole point of the admin set.
    function test_reads_spendAsset_survivesBorrowableFlagOff() public {
        _setAaveReserveBorrowable(usdcReserveId, false);
        assertFalse(gw.isBorrowable(address(usdc)), "no longer borrowable for credit");
        assertTrue(gw.isSpendAsset(address(usdc)), "still a debit-spend asset");
    }

    /// setSpendAsset is admin-gated, requires a registered reserve, and removeReserve drops spend membership.
    function test_setSpendAsset_guardsAndRemovalDropsMembership() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LendGateway.AssetNotRegistered.selector, address(0xdead)));
        gw.setSpendAsset(address(0xdead), true);

        vm.expectRevert(); // caller lacks LEND_GATEWAY_ADMIN_ROLE
        gw.setSpendAsset(address(usdc), false);

        // _addAaveReserve manages its own aaveAdmin prank, so list the idle USDT reserve before pranking owner
        uint256 usdtReserveId = _addAaveReserve(address(usdt), usdcUsdOracle, _usdcCollateralFactorBps(), true);

        vm.startPrank(owner);
        gw.setReserveId(address(usdt), usdtReserveId);
        gw.setSpendAsset(address(usdt), true);
        assertTrue(gw.isSpendAsset(address(usdt)));
        gw.removeReserve(address(usdt)); // idle reserve: no debt, no supplied balance
        vm.stopPrank();
        assertFalse(gw.isSpendAsset(address(usdt)), "removeReserve drops spend membership");
    }

    function test_getAccountData_freshSafeIsEmptyAndHealthy() public view {
        ILendGateway.AccountData memory data = gw.getAccountData(address(safe));
        assertEq(data.collateralUsd, 0);
        assertEq(data.debtUsd, 0);
        assertEq(data.availableBorrowsUsd, 0);
        assertEq(data.healthFactor, type(uint256).max);
    }

    // ----------------------------------------------------------------- approval (no user signature)

    function test_supply_autoApprovesPositionManagerOnFirstOp() public {
        assertFalse(spoke.isPositionManager(address(safe), address(gw)));

        deal(address(weETH), address(safe), 10 ether);
        vm.prank(driver);
        gw.supply(address(safe), address(weETH), 5 ether);

        // Approval was folded into the op, with no owner signature
        assertTrue(spoke.isPositionManager(address(safe), address(gw)));
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(weETH)), 5 ether, 2);
    }

    // ----------------------------------------------------------------- full lifecycle vs real Aave

    function test_fullLifecycle_supplyCollateralBorrowRepayWithdraw() public {
        deal(address(weETH), address(safe), 10 ether);

        // supply weETH and enable it as collateral
        vm.startPrank(driver);
        gw.supply(address(safe), address(weETH), 5 ether);

        // borrow USDC to a recipient
        gw.borrow(address(safe), address(usdc), 1000e6, recipient);
        vm.stopPrank();

        assertEq(usdc.balanceOf(recipient), 1000e6, "recipient receives borrow");
        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), 1000e6, 2, "debt recorded");

        ILendGateway.AccountData memory data = gw.getAccountData(address(safe));
        assertGt(data.collateralUsd, 0, "collateral valued");
        assertApproxEqAbs(data.debtUsd, 1000e6, 1e6, "debt in USD");
        assertGt(data.availableBorrowsUsd, 0, "headroom remains");
        assertGt(data.healthFactor, 1e18, "healthy");

        // repay the full debt
        deal(address(usdc), address(safe), 1010e6);
        vm.prank(driver);
        gw.repay(address(safe), address(usdc), type(uint256).max);
        assertLe(gw.debtOf(address(safe), address(usdc)), 1, "debt cleared");

        // withdraw part of the collateral to a recipient
        uint256 beforeBal = weETH.balanceOf(recipient);
        vm.prank(driver);
        gw.withdraw(address(safe), address(weETH), 2 ether, recipient);
        assertEq(weETH.balanceOf(recipient) - beforeBal, 2 ether, "withdraw forwarded");
    }

    // ----------------------------------------------------------------- users cannot disable the position manager

    function test_userCannotDisablePositionManager() public {
        deal(address(weETH), address(safe), 10 ether);
        vm.prank(driver);
        gw.supply(address(safe), address(weETH), 5 ether);
        assertTrue(spoke.isPositionManager(address(safe), address(gw)));

        // The safe tries to revoke the gateway directly on the spoke
        vm.prank(address(safe));
        spoke.setUserPositionManager(address(gw), false);
        assertFalse(spoke.isPositionManager(address(safe), address(gw)));

        // The next op re-establishes approval and succeeds — a user cannot durably turn the manager off
        deal(address(weETH), address(safe), 1 ether);
        vm.prank(driver);
        gw.supply(address(safe), address(weETH), 1 ether);
        assertTrue(spoke.isPositionManager(address(safe), address(gw)), "re-approved on next op");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(weETH)), 6 ether, 3);
    }

    // ----------------------------------------------------------------- access control

    function test_onlyDriverCanOperate() public {
        deal(address(weETH), address(safe), 1 ether);
        vm.prank(makeAddr("notADriver"));
        vm.expectRevert(LendGateway.OnlyDriver.selector);
        gw.supply(address(safe), address(weETH), 1 ether);
    }

    function test_cashModuleIsAlwaysADriver() public {
        assertTrue(gw.isDriver(address(cashModule)));
        assertTrue(gw.isDriver(driver));
        assertFalse(gw.isDriver(makeAddr("random")));
    }

    function test_setReserveId_requiresGatewayAdminRole() public {
        vm.prank(makeAddr("notAdmin"));
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        gw.setReserveId(address(weETH), weethReserveId);
    }

    // ----------------------------------------------------------------- registry management

    function test_setReserveId_rejectsZeroAsset() public {
        vm.prank(owner);
        vm.expectRevert(LendGateway.ZeroAddress.selector);
        gw.setReserveId(address(0), 0);
    }

    /// An empty reserve (no supply, no debt) removes cleanly and its reads zero out. weETH is used because the
    /// USDC reserve carries seeded liquidity, which the in-use guard (below) blocks.
    function test_removeReserve_unregistersAndZeroesReads() public {
        assertEq(spoke.getReserveSuppliedAssets(weethReserveId), 0, "weETH reserve empty at setup");

        vm.prank(owner);
        gw.removeReserve(address(weETH));

        assertFalse(gw.isRegistered(address(weETH)));
        assertEq(gw.ltv(address(weETH)), 0);
        assertEq(gw.withdrawalLiquidity(address(weETH)), 0);
        assertEq(gw.suppliedOf(address(safe), address(weETH)), 0);
        assertEq(gw.debtOf(address(safe), address(weETH)), 0);

        vm.expectRevert(abi.encodeWithSelector(LendGateway.AssetNotRegistered.selector, address(weETH)));
        gw.reserveIdOf(address(weETH));
    }

    function test_removeReserve_guards() public {
        address never = makeAddr("neverRegistered");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LendGateway.AssetNotRegistered.selector, never));
        gw.removeReserve(never);

        vm.prank(makeAddr("notAdmin"));
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        gw.removeReserve(address(weETH));
    }

    /// removeReserve refuses while the reserve still has supply or debt, so a delisting cannot strand positions
    /// or corrupt the USD views (mirrors the legacy DebtManager unsupportBorrowToken guard).
    function test_removeReserve_revertsWhileReserveInUse() public {
        // USDC carries seeded LP liquidity (supplied != 0), so it cannot be pulled
        vm.prank(owner);
        vm.expectRevert(LendGateway.ReserveStillInUse.selector);
        gw.removeReserve(address(usdc));

        // Supplying weETH puts its reserve in use too; a safe borrow then adds USDC debt on top
        deal(address(weETH), address(safe), 5 ether);
        vm.startPrank(driver);
        gw.supply(address(safe), address(weETH), 5 ether);
        gw.borrow(address(safe), address(usdc), 1000e6, recipient);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert(LendGateway.ReserveStillInUse.selector);
        gw.removeReserve(address(weETH));
        vm.expectRevert(LendGateway.ReserveStillInUse.selector);
        gw.removeReserve(address(usdc));
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- driver management

    function test_setDriver_guardsAndDeauthorization() public {
        // De-authorizing a driver stops it operating
        vm.prank(owner);
        gw.setDriver(driver, false);
        deal(address(weETH), address(safe), 1 ether);
        vm.prank(driver);
        vm.expectRevert(LendGateway.OnlyDriver.selector);
        gw.supply(address(safe), address(weETH), 1 ether);

        // Zero address and role gating
        vm.prank(owner);
        vm.expectRevert(LendGateway.ZeroAddress.selector);
        gw.setDriver(address(0), true);

        vm.prank(makeAddr("notAdmin"));
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        gw.setDriver(makeAddr("d"), true);
    }

    // ----------------------------------------------------------------- op guards (all mutating ops)

    function test_mutatingOps_onlyDriver() public {
        vm.startPrank(makeAddr("notADriver"));
        vm.expectRevert(LendGateway.OnlyDriver.selector);
        gw.withdraw(address(safe), address(weETH), 1, recipient);
        vm.expectRevert(LendGateway.OnlyDriver.selector);
        gw.borrow(address(safe), address(usdc), 1, recipient);
        vm.expectRevert(LendGateway.OnlyDriver.selector);
        gw.repay(address(safe), address(usdc), 1);
        vm.expectRevert(LendGateway.OnlyDriver.selector);
        gw.setUsingAsCollateral(address(safe), address(weETH), true);
        vm.stopPrank();
    }

    /// Every mutation rejects an address that is not a Safe deployed by EtherFiSafeFactory.
    function test_mutatingOps_rejectNonSafeTarget() public {
        address notSafe = makeAddr("notSafe");
        vm.startPrank(driver);
        vm.expectRevert(ModuleBase.OnlyEtherFiSafe.selector);
        gw.supply(notSafe, address(weETH), 1);
        vm.expectRevert(ModuleBase.OnlyEtherFiSafe.selector);
        gw.withdraw(notSafe, address(weETH), 1, notSafe);
        vm.expectRevert(ModuleBase.OnlyEtherFiSafe.selector);
        gw.borrow(notSafe, address(usdc), 1, notSafe);
        vm.expectRevert(ModuleBase.OnlyEtherFiSafe.selector);
        gw.repay(notSafe, address(usdc), 1);
        vm.expectRevert(ModuleBase.OnlyEtherFiSafe.selector);
        gw.setUsingAsCollateral(notSafe, address(weETH), true);
        vm.stopPrank();
    }

    function test_mutatingOps_revertOnUnregisteredAsset() public {
        address unreg = makeAddr("unregisteredAsset");
        bytes memory notRegistered = abi.encodeWithSelector(LendGateway.AssetNotRegistered.selector, unreg);
        vm.startPrank(driver);
        vm.expectRevert(notRegistered);
        gw.supply(address(safe), unreg, 1e18);
        vm.expectRevert(notRegistered);
        gw.withdraw(address(safe), unreg, 1e18, recipient);
        vm.expectRevert(notRegistered);
        gw.borrow(address(safe), unreg, 1e18, recipient);
        vm.expectRevert(notRegistered);
        gw.repay(address(safe), unreg, type(uint256).max);
        vm.expectRevert(notRegistered);
        gw.setUsingAsCollateral(address(safe), unreg, true);
        vm.stopPrank();
    }

    function test_ops_revertOnZeroAmountAndRecipient() public {
        vm.startPrank(driver);
        vm.expectRevert(LendGateway.ZeroAmount.selector);
        gw.supply(address(safe), address(weETH), 0);
        vm.expectRevert(LendGateway.ZeroAmount.selector);
        gw.withdraw(address(safe), address(weETH), 0, recipient);
        vm.expectRevert(LendGateway.ZeroAmount.selector);
        gw.borrow(address(safe), address(usdc), 0, recipient);
        vm.expectRevert(LendGateway.ZeroAddress.selector);
        gw.withdraw(address(safe), address(weETH), 1, address(0));
        vm.expectRevert(LendGateway.ZeroAddress.selector);
        gw.borrow(address(safe), address(usdc), 1, address(0));
        // repay(max) with no debt resolves to a zero pull amount
        vm.expectRevert(LendGateway.ZeroAmount.selector);
        gw.repay(address(safe), address(usdc), type(uint256).max);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- pause

    function test_pauseBlocksOpsThenUnpauseResumes() public {
        deal(address(weETH), address(safe), 2 ether);

        vm.prank(pauser);
        gw.pause();
        vm.prank(driver);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        gw.supply(address(safe), address(weETH), 1 ether);

        vm.prank(unpauser);
        gw.unpause();
        vm.prank(driver);
        gw.supply(address(safe), address(weETH), 1 ether);
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(weETH)), 1 ether, 2);
    }

    // ----------------------------------------------------------------- reads & misc

    function test_reads_unregisteredAssetReturnZero() public {
        address unreg = makeAddr("unregisteredRead");
        assertEq(gw.suppliedOf(address(safe), unreg), 0);
        assertEq(gw.debtOf(address(safe), unreg), 0);
        assertEq(gw.withdrawalLiquidity(unreg), 0);
        assertEq(gw.ltv(unreg), 0);
    }

    function test_repay_partialReducesDebt() public {
        deal(address(weETH), address(safe), 10 ether);
        vm.startPrank(driver);
        gw.supply(address(safe), address(weETH), 5 ether);
        gw.borrow(address(safe), address(usdc), 1000e6, recipient);
        vm.stopPrank();

        deal(address(usdc), address(safe), 400e6);
        vm.prank(driver);
        uint256 repaid = gw.repay(address(safe), address(usdc), 400e6);

        assertApproxEqAbs(repaid, 400e6, 2, "partial repay amount");
        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), 600e6, 2, "remaining debt");
    }

    /// A gateway supply always enables the supplied reserve as collateral in the same operation.
    function test_supply_enablesCollateral() public {
        deal(address(weETH), address(safe), 1 ether);

        vm.prank(driver);
        gw.supply(address(safe), address(weETH), 1 ether);

        (bool enabled,) = spoke.getUserReserveStatus(weethReserveId, address(safe));
        assertTrue(enabled, "supplied reserve enabled as collateral");
    }

    function test_setUsingAsCollateral_disableThenEnableThenDisable() public {
        deal(address(weETH), address(safe), 5 ether);
        vm.startPrank(driver);
        gw.supply(address(safe), address(weETH), 5 ether);

        gw.setUsingAsCollateral(address(safe), address(weETH), false);
        (bool initiallyDisabled,) = spoke.getUserReserveStatus(weethReserveId, address(safe));
        assertFalse(initiallyDisabled, "collateral initially disabled");

        gw.setUsingAsCollateral(address(safe), address(weETH), true);
        (bool enabled,) = spoke.getUserReserveStatus(weethReserveId, address(safe));
        assertTrue(enabled, "collateral enabled");

        gw.setUsingAsCollateral(address(safe), address(weETH), false);
        (bool disabled,) = spoke.getUserReserveStatus(weethReserveId, address(safe));
        assertFalse(disabled, "collateral disabled");
        vm.stopPrank();
    }

    function test_isApprovedBy_reflectsApprovalState() public {
        assertFalse(gw.isApprovedBy(address(safe)), "not approved before first op");
        deal(address(weETH), address(safe), 1 ether);
        vm.prank(driver);
        gw.supply(address(safe), address(weETH), 1 ether);
        assertTrue(gw.isApprovedBy(address(safe)), "approved after first op");
    }

    function test_constructor_revertsOnZeroSpoke() public {
        vm.expectRevert(LendGateway.ZeroAddress.selector);
        new LendGateway(address(dataProvider), address(0));
    }

    // ----------------------------------------------------------------- proof the deployed Aave pool is live

    /// @dev The real Aave risk engine must reject a borrow beyond the collateral's borrowing power.
    function test_borrow_beyondBorrowingPowerReverts() public {
        // ~1 weETH collateral at 80% LTV gives a few thousand USD of power; borrowing $50k must revert.
        deal(address(weETH), address(safe), 1 ether);
        vm.startPrank(driver);
        gw.supply(address(safe), address(weETH), 1 ether);
        // Pinned to the health gate (not a bare revert): with 1M USDC seeded, a $50k borrow can only fail
        // Aave's borrowing-power / health check, not liquidity.
        vm.expectRevert(ISpoke.HealthFactorBelowThreshold.selector);
        gw.borrow(address(safe), address(usdc), 50_000e6, recipient);
        vm.stopPrank();
    }

    /// @dev Withdrawing collateral that would break the position's health must trip Aave's liquidation-threshold gate.
    function test_withdraw_breakingHealthReverts() public {
        deal(address(weETH), address(safe), 5 ether);
        vm.startPrank(driver);
        gw.supply(address(safe), address(weETH), 5 ether);
        gw.borrow(address(safe), address(usdc), 1000e6, recipient);

        // Pulling all the collateral while $1000 of debt is open must trip Aave's liquidation-threshold gate.
        vm.expectRevert(ISpoke.HealthFactorBelowThreshold.selector);
        gw.withdraw(address(safe), address(weETH), 5 ether, recipient);
        vm.stopPrank();
    }

    /// @dev Supply and borrow must move the reserve's real hub-level accounting, not just per-user views.
    function test_reserveAccountingReflectsSupplyAndBorrow() public {
        uint256 cashBefore = gw.withdrawalLiquidity(address(usdc));
        assertApproxEqAbs(cashBefore, 1_000_000e6, 1, "seeded USDC liquidity present");

        deal(address(weETH), address(safe), 5 ether);
        vm.startPrank(driver);
        gw.supply(address(safe), address(weETH), 5 ether);
        gw.borrow(address(safe), address(usdc), 1000e6, recipient);
        vm.stopPrank();

        // Borrow drew from the USDC reserve's cash (hub liquidity accounting)
        assertApproxEqAbs(gw.withdrawalLiquidity(address(usdc)), cashBefore - 1000e6, 2, "borrow reduced reserve cash");
        // Supply landed in the weETH reserve (hub-side supplied assets)
        assertApproxEqAbs(spoke.getReserveSuppliedAssets(weethReserveId), 5 ether, 3, "supply increased reserve assets");
    }

    /// @dev The proxy is initialized in setUp; a second initialize must revert (no init-hijack)
    function test_initialize_cannotBeCalledTwice() public {
        vm.expectRevert(bytes4(keccak256("InvalidInitialization()")));
        gw.initialize(address(roleRegistry));
    }

    /// @dev If the gateway is not an enabled module on the safe, the auto-approval exec reverts (OnlyModules)
    function test_ops_revertWhenGatewayNotEnabledOnSafe() public {
        // Disable the gateway module on the safe (owner-signed), leaving it unable to drive the safe
        address[] memory modules = _addr1(address(gw));
        bool[] memory disable = _bool1(false);
        bytes[] memory setupData = new bytes[](1);
        setupData[0] = "";
        _configureModules(modules, disable, setupData);

        deal(address(weETH), address(safe), 1 ether);
        vm.prank(driver);
        vm.expectRevert(bytes4(keccak256("OnlyModules()")));
        gw.supply(address(safe), address(weETH), 1 ether);
    }

    /// @dev Supplied-but-not-collateral counts toward collateralUsd but grants no borrowing power
    function test_getAccountData_nonCollateralSupplyHasNoBorrowPower() public {
        deal(address(weETH), address(safe), 5 ether);
        vm.startPrank(driver);
        gw.supply(address(safe), address(weETH), 5 ether);
        gw.setUsingAsCollateral(address(safe), address(weETH), false);
        vm.stopPrank();

        ILendGateway.AccountData memory data = gw.getAccountData(address(safe));
        assertGt(data.collateralUsd, 0, "supplied value counted as collateralUsd");
        assertEq(data.availableBorrowsUsd, 0, "no borrow power without collateral enabled");
        assertEq(data.debtUsd, 0);
    }

    /// @dev Overpaying repay: the spoke caps at the debt and the gateway refunds the dust to the safe
    function test_repay_refundsDustWhenOverpaying() public {
        deal(address(weETH), address(safe), 10 ether);
        vm.startPrank(driver);
        gw.supply(address(safe), address(weETH), 5 ether);
        gw.borrow(address(safe), address(usdc), 1000e6, recipient);
        vm.stopPrank();

        // Fund the safe with more than the debt; repay the full over-amount
        deal(address(usdc), address(safe), 1500e6);
        vm.prank(driver);
        uint256 repaid = gw.repay(address(safe), address(usdc), 1500e6);

        assertApproxEqAbs(repaid, 1000e6, 2, "only the debt is repaid");
        assertLe(gw.debtOf(address(safe), address(usdc)), 1, "debt cleared");
        assertApproxEqAbs(usdc.balanceOf(address(safe)), 500e6, 2, "excess refunded to safe");
    }
}
