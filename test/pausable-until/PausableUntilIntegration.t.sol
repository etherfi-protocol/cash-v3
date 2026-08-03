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

    function test_guardianPauseUntil_onHook_blocksSafeModuleExecution() public {
        address[] memory to = new address[](1);
        to[0] = makeAddr("target");
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);

        // Works before the pause
        vm.prank(address(cashModule));
        safe.execTransactionFromModule(to, values, data);

        vm.prank(guardian);
        PausableUntil(address(hook)).pauseUntil();

        uint256 pausedUntil = PausableUntil(address(hook)).pausedUntil();
        vm.prank(address(cashModule));
        vm.expectRevert(abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, pausedUntil));
        safe.execTransactionFromModule(to, values, data);

        // Governance lifts the pause early and execution resumes
        vm.prank(owner);
        PausableUntil(address(hook)).unpauseUntil();

        vm.prank(address(cashModule));
        safe.execTransactionFromModule(to, values, data);
    }
}
