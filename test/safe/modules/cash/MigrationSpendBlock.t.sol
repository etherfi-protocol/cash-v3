// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { UUPSProxy } from "../../../../src/UUPSProxy.sol";
import { Mode, BinSponsor, Cashback } from "../../../../src/interfaces/ICashModule.sol";
import { TopUpDest } from "../../../../src/top-up/TopUpDest.sol";
import { TopUpDestWithMigration } from "../../../../src/top-up/TopUpDestWithMigration.sol";
import { DebtManagerCoreWithMigration } from "../../../../src/debt-manager/DebtManagerCoreWithMigration.sol";
import { CashLensWithMigration } from "../../../../src/modules/cash/CashLensWithMigration.sol";
import { CashModuleTestSetup } from "./CashModuleTestSetup.t.sol";

/**
 * @title MigrationSpendBlockTest
 * @notice Tests that migrated safes cannot borrow (credit mode spend) on Scroll
 */
contract MigrationSpendBlockTest is CashModuleTestSetup {
    TopUpDestWithMigration public topUpDest;
    address public migrationModule;
    address constant WETH = 0x5300000000000000000000000000000000000004;

    function setUp() public override {
        super.setUp();

        migrationModule = makeAddr("migrationModule");

        vm.startPrank(owner);

        // Deploy TopUpDestWithMigration
        address topUpDestImpl = address(new TopUpDest(address(dataProvider), WETH));
        address topUpDestV2Impl = address(new TopUpDestWithMigration(address(dataProvider), WETH, migrationModule));
        address topUpDestProxy = address(new UUPSProxy(topUpDestImpl, abi.encodeWithSelector(TopUpDest.initialize.selector, address(roleRegistry))));
        UUPSUpgradeable(topUpDestProxy).upgradeToAndCall(topUpDestV2Impl, "");
        topUpDest = TopUpDestWithMigration(payable(topUpDestProxy));

        // Upgrade DebtManager to DebtManagerCoreWithMigration
        address newDebtManagerImpl = address(new DebtManagerCoreWithMigration(address(dataProvider), address(topUpDest)));
        UUPSUpgradeable(address(debtManager)).upgradeToAndCall(newDebtManagerImpl, "");

        // Upgrade CashLens to CashLensWithMigration
        address newCashLensImpl = address(new CashLensWithMigration(address(cashModule), address(dataProvider), address(topUpDest)));
        UUPSUpgradeable(address(cashLens)).upgradeToAndCall(newCashLensImpl, "");

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //                          HELPERS
    // ═══════════════════════════════════════════════════════════════

    function _markSafeMigrated() internal {
        address[] memory safes = new address[](1);
        safes[0] = address(safe);
        vm.prank(migrationModule);
        topUpDest.setMigrated(safes);
    }

    function _setupCreditMode() internal {
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);
    }

    function _setupCreditModeWithCollateral() internal {
        _setupCreditMode();
        deal(address(weETHScroll), address(safe), 1 ether);
        deal(address(usdcScroll), address(debtManager), 1000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    spend — credit mode blocked
    // ═══════════════════════════════════════════════════════════════

    function test_spend_reverts_inCreditMode_whenMigrated() public {
        _setupCreditModeWithCollateral();
        _markSafeMigrated();

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;
        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        vm.expectRevert(DebtManagerCoreWithMigration.SafeMigrated.selector);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, tokens, amounts, cashbacks);
    }

    function test_spend_works_inCreditMode_whenNotMigrated() public {
        _setupCreditModeWithCollateral();

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;
        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, tokens, amounts, cashbacks);

        assertTrue(cashModule.transactionCleared(address(safe), txId));
    }

    function test_spend_works_inDebitMode_whenMigrated() public {
        _markSafeMigrated();

        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, tokens, amounts, cashbacks);

        assertTrue(cashModule.transactionCleared(address(safe), txId));
        assertEq(usdcScroll.balanceOf(address(safe)), 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                  canSpend — credit mode blocked
    // ═══════════════════════════════════════════════════════════════

    function test_canSpend_fails_inCreditMode_whenMigrated() public {
        _setupCreditModeWithCollateral();
        _markSafeMigrated();

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, false);
        assertEq(reason, "Safe is migrated");
    }

    function test_canSpend_succeeds_inCreditMode_whenNotMigrated() public {
        _setupCreditModeWithCollateral();

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, true);
        assertEq(reason, "");
    }

    function test_canSpend_succeeds_inDebitMode_whenMigrated() public {
        _markSafeMigrated();

        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, true);
        assertEq(reason, "");
    }

    // ═══════════════════════════════════════════════════════════════
    //               canSpendSingleToken — credit mode blocked
    // ═══════════════════════════════════════════════════════════════

    function test_canSpendSingleToken_fails_inCreditMode_whenMigrated() public {
        _setupCreditModeWithCollateral();
        _markSafeMigrated();

        address[] memory creditPrefs = new address[](1);
        creditPrefs[0] = address(usdcScroll);
        address[] memory debitPrefs = new address[](1);
        debitPrefs[0] = address(usdcScroll);

        (Mode mode,, bool canSpend, string memory reason) = cashLens.canSpendSingleToken(address(safe), txId, creditPrefs, debitPrefs, 10e6);
        assertEq(uint8(mode), uint8(Mode.Credit));
        assertEq(canSpend, false);
        assertEq(reason, "Safe is migrated");
    }

    // ═══════════════════════════════════════════════════════════════
    //               unsetMigrated re-enables borrowing
    // ═══════════════════════════════════════════════════════════════

    function test_spend_works_inCreditMode_afterUnsetMigrated() public {
        _setupCreditModeWithCollateral();
        _markSafeMigrated();

        // Unset migration
        address[] memory safes = new address[](1);
        safes[0] = address(safe);
        vm.prank(owner);
        topUpDest.unsetMigrated(safes);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;
        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, tokens, amounts, cashbacks);

        assertTrue(cashModule.transactionCleared(address(safe), txId));
    }

    function test_canSpend_succeeds_inCreditMode_afterUnsetMigrated() public {
        _setupCreditModeWithCollateral();
        _markSafeMigrated();

        // Verify blocked
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;
        (bool blocked,) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(blocked, false);

        // Unset migration
        address[] memory safes = new address[](1);
        safes[0] = address(safe);
        vm.prank(owner);
        topUpDest.unsetMigrated(safes);

        // Verify unblocked
        (bool canSpend, string memory reason) = cashLens.canSpend(address(safe), txId, tokens, amounts);
        assertEq(canSpend, true);
        assertEq(reason, "");
    }
}
