// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BinSponsor, Cashback } from "../../src/interfaces/ICashModule.sol";
import { PausableUntil } from "../../src/utils/PausableUntil.sol";
import { CashModuleTestSetup } from "../safe/modules/cash/CashModuleTestSetup.t.sol";

contract PausableUntilIntegrationTest is CashModuleTestSetup {
    function setUp() public override {
        super.setUp();
        // The cooldown check reads lastPauseTimestamp == 0 as "paused at unix 0", so the
        // timestamp must exceed duration + cooldown for a first pause to be allowed
        vm.warp(block.timestamp + 8 days);
    }

    function test_guardianPauseUntil_blocksSpend_untilExpiry() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdc);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;
        Cashback[] memory cashbacks;

        vm.prank(guardian);
        PausableUntil(address(cashModule)).pauseUntil();

        uint256 pausedUntil = PausableUntil(address(cashModule)).pausedUntil();
        vm.prank(etherFiWallet);
        vm.expectRevert(abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, pausedUntil));
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        // Pause auto-expires without any unpause transaction
        vm.warp(pausedUntil + 1);
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
    }

    function test_guardianPauseUntil_governanceCanLiftEarly() public {
        vm.prank(guardian);
        PausableUntil(address(cashModule)).pauseUntil();
        assertTrue(PausableUntil(address(cashModule)).isPaused());

        vm.prank(owner);
        PausableUntil(address(cashModule)).unpauseUntil();
        assertFalse(PausableUntil(address(cashModule)).isPaused());
    }
}
