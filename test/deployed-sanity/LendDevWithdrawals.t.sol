// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";

import { CashLendDevModules } from "../../scripts/lend/CashLendDevModules.sol";
import { RetireOldModulesDev } from "../../scripts/lend/RetireOldModulesDev.s.sol";
import { BinSponsor } from "../../src/interfaces/ICashModule.sol";
import { LendDevTestBase } from "./LendDevTestBase.t.sol";

/// @dev Exposes the retire script's calls so the rehearsal can drive the exact script path on the fork.
contract RetireHarness is RetireOldModulesDev {
    function retire(address dataProvider, address cashModule, address[] memory oldModules) external {
        _retire(dataProvider, cashModule, oldModules);
    }
}

/**
 * @title LendDevWithdrawalsTest
 * @notice Withdrawal edges of the Lend dev deployment against the LIVE Optimism dev contracts on a fork:
 *         reservation accounting, cancellation, module-requested withdrawals, and a rehearsal of the
 *         future retire pass showing why the pending-withdrawal scan must run first.
 */
contract LendDevWithdrawalsTest is LendDevTestBase {
    /// A pending withdrawal reserves its amount: the sweep only supplies the unreserved remainder, and the
    /// withdrawal still pays out in full after the delay.
    function test_pendingWithdrawal_reservationSurvivesSweep() public {
        address safe = _deploySafe("lend-dev-reserve", true);
        deal(address(usdc), safe, 100e6);

        _requestWithdrawal(safe, address(usdc), 60e6);
        vm.prank(devAdmin);
        cashModule.supplyToLend(safe, _addr1(address(usdc)));
        assertEq(usdc.balanceOf(safe), 60e6, "reserved amount stayed loose");
        assertApproxEqAbs(gw.suppliedOf(safe, address(usdc)), 40e6, 2, "only the remainder was supplied");

        uint256 recipientBefore = usdc.balanceOf(recipient);
        vm.warp(block.timestamp + withdrawalDelay + 1);
        cashModule.processWithdrawal(safe);
        assertEq(usdc.balanceOf(recipient), recipientBefore + 60e6, "withdrawal paid out in full");
    }

    /// canSpend respects the reservation: a debit spend into the reserved amount declines, one within the
    /// unreserved remainder passes and settles.
    function test_canSpend_respectsReservation() public {
        address safe = _deploySafe("lend-dev-reserve-spend", true);
        deal(address(usdc), safe, 100e6);
        _requestWithdrawal(safe, address(usdc), 60e6);

        (bool okOver,) = cashLens.canSpend(safe, keccak256("reserve-over"), _addr1(address(usdc)), _uint1(50e6));
        assertFalse(okOver, "a spend into the reserved amount declines");

        (bool ok, string memory reason) = cashLens.canSpend(safe, keccak256("reserve-ok"), _addr1(address(usdc)), _uint1(30e6));
        assertTrue(ok, reason);
        address dispatcher = cashModule.getSettlementDispatcher(BinSponsor.Reap);
        uint256 dispatcherBefore = usdc.balanceOf(dispatcher);
        vm.prank(devAdmin);
        cashModule.spend(safe, keccak256("reserve-ok"), BinSponsor.Reap, _addr1(address(usdc)), _uint1(30e6), _noCashback());
        assertEq(usdc.balanceOf(dispatcher), dispatcherBefore + 30e6, "spend within the remainder settled");
    }

    /// Cancelling a withdrawal frees the reservation: the next sweep supplies the whole balance.
    function test_cancelWithdrawal_freesReservation() public {
        address safe = _deploySafe("lend-dev-cancel", true);
        deal(address(usdc), safe, 100e6);
        _requestWithdrawal(safe, address(usdc), 60e6);

        (address[] memory signers, bytes[] memory sigs) = _cancelWithdrawalSigs(safe);
        cashModule.cancelWithdrawal(safe, signers, sigs);

        vm.prank(devAdmin);
        cashModule.supplyToLend(safe, _addr1(address(usdc)));
        assertApproxEqAbs(gw.suppliedOf(safe, address(usdc)), 100e6, 2, "freed balance fully supplied");
        assertEq(usdc.balanceOf(safe), 0, "nothing left loose");
    }

    /// A module-requested withdrawal pays out to the requesting module, and the requester policy holds:
    /// the liquid module may request, the stake module may not.
    function test_moduleRequestedWithdrawal_paysTheModule() public {
        address safe = _deploySafe("lend-dev-module-wd", true);
        deal(address(usdc), safe, 50e6);

        address stakeModule = stdJson.readAddress(lendJson, ".newModules.stake");
        vm.prank(stakeModule);
        vm.expectRevert();
        cashModule.requestWithdrawalByModule(safe, address(usdc), 40e6);

        uint256 moduleBefore = usdc.balanceOf(address(liquidModule));
        vm.prank(address(liquidModule));
        cashModule.requestWithdrawalByModule(safe, address(usdc), 40e6);
        vm.warp(block.timestamp + withdrawalDelay + 1);
        // only the requesting module may process its own withdrawal
        vm.expectRevert();
        cashModule.processWithdrawal(safe);
        vm.prank(address(liquidModule));
        cashModule.processWithdrawal(safe);
        assertEq(usdc.balanceOf(address(liquidModule)), moduleBefore + 40e6, "withdrawal paid the requesting module");
    }

    /// REHEARSAL of the future retire pass, driving the RetireOldModulesDev script path: a pending
    /// withdrawal paying an old module survives retirement and pays out to the retired module, where the
    /// funds strand (nothing drives a retired module). This is why check-pending-withdrawals.sh must run
    /// (and come back clean) immediately before the retire broadcast.
    function test_retirePass_strandsPendingModuleWithdrawal() public {
        address oldLiquid = stdJson.readAddress(baseJson, ".addresses.EtherFiLiquidModule");
        address safe = _deploySafe("lend-dev-retire", true);
        deal(address(usdc), safe, 50e6);

        // an old-module withdrawal is pending when the retire pass runs
        vm.prank(oldLiquid);
        cashModule.requestWithdrawalByModule(safe, address(usdc), 40e6);

        // drive the exact script path, with the harness granted the roles the dev admin holds
        RetireHarness harness = new RetireHarness();
        address[] memory oldModules = CashLendDevModules.oldAddresses(CashLendDevModules.readOld(baseJson));
        bytes32 controllerRole = cashModule.CASH_MODULE_CONTROLLER_ROLE();
        vm.startPrank(devAdmin);
        registry.grantRole(controllerRole, address(harness));
        registry.grantRole(keccak256("DATA_PROVIDER_ADMIN_ROLE"), address(harness));
        vm.stopPrank();
        harness.retire(address(dataProvider), address(cashModule), oldModules);
        assertFalse(dataProvider.isWhitelistedModule(oldLiquid), "old module retired");

        // the pending withdrawal still processes, paying the retired module: the funds are stranded there
        uint256 moduleBefore = usdc.balanceOf(oldLiquid);
        vm.warp(block.timestamp + withdrawalDelay + 1);
        cashModule.processWithdrawal(safe);
        assertEq(usdc.balanceOf(oldLiquid), moduleBefore + 40e6, "payout landed on the retired module");
    }
}
