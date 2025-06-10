// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { SafeTiers } from "../../../../src/interfaces/ICashModule.sol";

import { SignatureUtils } from "../../../../src/libraries/SignatureUtils.sol";
import { ModuleBase } from "../../../../src/modules/ModuleBase.sol";
import { CashEventEmitter } from "../../../../src/modules/cash/CashEventEmitter.sol";
import { CashModuleTestSetup, DebtManagerCore, DebtManagerAdmin, CashVerificationLib, ICashModule, IERC20, MessageHashUtils } from "./CashModuleTestSetup.t.sol";
import { BinSponsor, Cashback, CashbackTokens, CashbackTypes } from "../../../../src/interfaces/ICashModule.sol";

contract CashModuleCashbackTest is CashModuleTestSetup {
    using Math for uint256;
    using MessageHashUtils for bytes32;

    address spender = makeAddr("spender");
    IERC20 cashbackToken = scrToken;

    function test_spend_receivesCashback_forSafeAndSpender() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);

        uint256 cashbackBalSafeBefore = cashbackToken.balanceOf(address(safe));
        uint256 cashbackBalSpenderBefore = cashbackToken.balanceOf(address(spender));

        Cashback[] memory cashbacks = new Cashback[](2);
        
        CashbackTokens[] memory safeTokens = new CashbackTokens[](1);
        safeTokens[0] = CashbackTokens({
            token: address(scrToken),
            amountInUsd: 1e6,
            cashbackType: CashbackTypes.Regular
        });
        cashbacks[0] = Cashback({
            to: address(safe),
            cashbackTokens: safeTokens
        });

        CashbackTokens[] memory spenderTokens = new CashbackTokens[](1);
        spenderTokens[0] = CashbackTokens({
            token: address(scrToken),
            amountInUsd: 2e6,
            cashbackType: CashbackTypes.Spender
        });
        cashbacks[1] = Cashback({
            to: address(spender),
            cashbackTokens: spenderTokens
        });

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        uint256 expectedCashbackToSafe = cashbackDispatcher.convertUsdToCashbackToken(address(scrToken), 1e6);
        uint256 expectedCashbackToSpender = cashbackDispatcher.convertUsdToCashbackToken(address(scrToken), 2e6);

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), amount, address(safe), address(scrToken), expectedCashbackToSafe, 1e6, CashbackTypes.Regular, true);
        emit CashEventEmitter.Cashback(address(spender), amount, address(spender), address(scrToken), expectedCashbackToSpender, 2e6, CashbackTypes.Spender, true);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        assertEq(cashbackToken.balanceOf(address(safe)) - cashbackBalSafeBefore, expectedCashbackToSafe);
        assertEq(cashbackToken.balanceOf(address(spender)) - cashbackBalSpenderBefore, expectedCashbackToSpender);
    }

    function test_spend_doesNotReceiveCashback_ifNoCashbackIsPassed() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);

        uint256 cashbackBalSafeBefore = cashbackToken.balanceOf(address(safe));
        uint256 cashbackBalSpenderBefore = cashbackToken.balanceOf(address(spender));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        uint256 cashbackBalSafeAfter = cashbackToken.balanceOf(address(safe));
        uint256 cashbackBalSpenderAfter = cashbackToken.balanceOf(address(spender));

        assertEq(cashbackBalSafeAfter, cashbackBalSafeBefore);
        assertEq(cashbackBalSpenderAfter, cashbackBalSpenderBefore);
    }

    function test_spend_storesPendingCashback_ifNotEnoughBalanceOnCashbackDispatcher() public {        
        vm.startPrank(owner);
        address[] memory collateralTokens = new address[](1);
        collateralTokens[0] = address(scrToken);

        DebtManagerCore.CollateralTokenConfig[] memory collateralTokenConfig = new DebtManagerCore.CollateralTokenConfig[](1);
        collateralTokenConfig[0].ltv = ltv;
        collateralTokenConfig[0].liquidationThreshold = liquidationThreshold;
        collateralTokenConfig[0].liquidationBonus = liquidationBonus;

        DebtManagerAdmin(address(debtManager)).supportCollateralToken(address(scrToken), collateralTokenConfig[0]);

        vm.stopPrank();

        CashbackTokens[] memory cashbackTokens = new CashbackTokens[](1);
        CashbackTokens memory scrSafe = CashbackTokens({
            token: address(scrToken),
            amountInUsd: 1e6,
            cashbackType: CashbackTypes.Regular
        });
        cashbackTokens[0] = scrSafe;
        Cashback memory scrCashbackSafe = Cashback({
            to: address(safe),
            cashbackTokens: cashbackTokens
        });

        Cashback[] memory cashbacks = new Cashback[](1);
        cashbacks[0] = scrCashbackSafe;

        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);
        deal(address(scrToken), address(cashbackDispatcher), 0);

        uint256 expectedCashbackToSafe = cashbackDispatcher.convertUsdToCashbackToken(scrSafe.token, scrSafe.amountInUsd);
        
        uint256 cashbackBalSafeBefore = cashbackToken.balanceOf(address(safe));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), amount, address(safe), address(scrToken), expectedCashbackToSafe, scrSafe.amountInUsd, scrSafe.cashbackType, false);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        uint256 cashbackBalSafeAfter = cashbackToken.balanceOf(address(safe));

        assertEq(cashbackBalSafeAfter - cashbackBalSafeBefore, 0);

        assertEq(cashModule.getPendingCashbackForToken(address(safe), scrSafe.token), scrSafe.amountInUsd);
    }

    // Test for setSafeTier function
    function test_setSafeTier_succeeds_whenCalledByEtherFiWallet() public {
        address[] memory safes = new address[](1);
        safes[0] = address(safe);

        SafeTiers[] memory safeTiers = new SafeTiers[](1);
        safeTiers[0] = SafeTiers.Chad;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.SafeTiersSet(safes, safeTiers);
        cashModule.setSafeTier(safes, safeTiers);
    }

    function test_setSafeTier_fails_whenCalledByNonEtherFiWallet() public {
        address[] memory safes = new address[](1);
        safes[0] = address(safe);

        SafeTiers[] memory safeTiers = new SafeTiers[](1);
        safeTiers[0] = SafeTiers.Chad;

        vm.prank(makeAddr("nonEtherFiWallet"));
        vm.expectRevert(ICashModule.OnlyEtherFiWallet.selector);
        cashModule.setSafeTier(safes, safeTiers);
    }

    function test_setSafeTier_fails_whenSafeIsAlreadyInSameTier() public {
        address[] memory safes = new address[](1);
        safes[0] = address(safe);

        SafeTiers[] memory safeTiers = new SafeTiers[](1);
        safeTiers[0] = SafeTiers.Wojak;

        vm.prank(etherFiWallet);
        cashModule.setSafeTier(safes, safeTiers);

        vm.prank(etherFiWallet);
        vm.expectRevert(abi.encodeWithSelector(ICashModule.AlreadyInSameTier.selector, 0));
        cashModule.setSafeTier(safes, safeTiers);
    }

    function test_setSafeTier_fails_whenArrayLengthMismatch() public {
        address[] memory safes = new address[](2);
        safes[0] = address(safe);
        safes[1] = makeAddr("anotherSafe");

        SafeTiers[] memory safeTiers = new SafeTiers[](1);
        safeTiers[0] = SafeTiers.Chad;

        vm.prank(etherFiWallet);
        vm.expectRevert(ICashModule.ArrayLengthMismatch.selector);
        cashModule.setSafeTier(safes, safeTiers);
    }

    function test_setSafeTier_fails_whenAddressIsNotEtherFiSafe() public {
        address[] memory safes = new address[](1);
        safes[0] = makeAddr("notASafe");

        SafeTiers[] memory safeTiers = new SafeTiers[](1);
        safeTiers[0] = SafeTiers.Chad;

        vm.prank(etherFiWallet);
        vm.expectRevert(ModuleBase.OnlyEtherFiSafe.selector);
        cashModule.setSafeTier(safes, safeTiers);
    }

    function test_clearsPendingCashback_whenFundsAreAvailable() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), 2 * amount);
        deal(address(scrToken), address(cashbackDispatcher), 0); // Ensure no funds for initial cashback

        CashbackTokens[] memory cashbackTokens = new CashbackTokens[](1);
        CashbackTokens memory scrSafe = CashbackTokens({
            token: address(scrToken),
            amountInUsd: 1e6,
            cashbackType: CashbackTypes.Regular
        });
        cashbackTokens[0] = scrSafe;
        Cashback memory scrCashbackSafe = Cashback({
            to: address(safe),
            cashbackTokens: cashbackTokens
        });
        
        Cashback[] memory cashbacks = new Cashback[](1);
        cashbacks[0] = scrCashbackSafe;
        
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
        // Verify pending cashback is stored
        uint256 safePendingCashback = cashModule.getPendingCashbackForToken(address(safe), scrSafe.token);
        assertGt(safePendingCashback, 0);

        // Now add funds to the cashback dispatcher
        deal(address(scrToken), address(cashbackDispatcher), 1000 ether);

        // Make another spend which should trigger clearing pending cashback
        bytes32 newTxId = keccak256("newTxId");

        uint256 cashbackInToken = cashbackDispatcher.convertUsdToCashbackToken(scrSafe.token, scrSafe.amountInUsd);
        uint256 cashbackTokenSafeBalBefore = cashbackToken.balanceOf(address(safe));

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.PendingCashbackCleared(address(safe), address(scrToken), cashbackInToken, scrSafe.amountInUsd);
        cashModule.spend(address(safe), newTxId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        // Verify pending cashback is cleared
        assertEq(cashModule.getPendingCashbackForToken(address(safe), scrSafe.token), 0);

        assertGt(cashbackToken.balanceOf(address(safe)), cashbackTokenSafeBalBefore);
    }

    function test_doesNotClearPendingCashback_whenFundsAreStillUnavailable() public {
        // Setup pending cashback
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount * 2); // Ensure enough balance for two spends
        deal(address(scrToken), address(cashbackDispatcher), 0); // Ensure no funds for cashbac

        CashbackTokens[] memory cashbackTokens = new CashbackTokens[](1);
        CashbackTokens memory scrSafe = CashbackTokens({
            token: address(scrToken),
            amountInUsd: 1e6,
            cashbackType: CashbackTypes.Regular
        });
        cashbackTokens[0] = scrSafe;
        Cashback memory scrCashbackSafe = Cashback({
            to: address(safe),
            cashbackTokens: cashbackTokens
        });

        Cashback[] memory cashbacks = new Cashback[](1);
        cashbacks[0] = scrCashbackSafe;

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        // Verify pending cashback is stored
        uint256 safePendingCashback = cashModule.getPendingCashbackForToken(address(safe), scrSafe.token);
        
        assertGt(safePendingCashback, 0);

        // Make another spend without adding funds to cashback dispatcher
        bytes32 newTxId = keccak256("newTxId");

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), newTxId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        // Verify pending cashback is accumulated
        assertGt(cashModule.getPendingCashbackForToken(address(safe), scrSafe.token), safePendingCashback);
    }
}
