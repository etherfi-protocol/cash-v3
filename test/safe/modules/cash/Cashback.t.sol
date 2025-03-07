// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { SafeTiers } from "../../../../src/interfaces/ICashModule.sol";

import { SignatureUtils } from "../../../../src/libraries/SignatureUtils.sol";
import { ModuleBase } from "../../../../src/modules/ModuleBase.sol";
import { CashEventEmitter } from "../../../../src/modules/cash/CashEventEmitter.sol";
import { CashModuleTestSetup, CashVerificationLib, ICashModule, IERC20, MessageHashUtils } from "./CashModuleTestSetup.t.sol";

contract CashModuleCashbackTest is CashModuleTestSetup {
    using Math for uint256;
    using MessageHashUtils for bytes32;

    address spender = makeAddr("spender");
    uint256 initialSplitToSafeBps;
    uint256 initialCashbackPercentage;
    uint256 HUNDRED_PERCENT_IN_BPS = 10_000;
    IERC20 cashbackToken = scrToken;

    function setUp() public override {
        super.setUp();
        (initialCashbackPercentage, initialSplitToSafeBps) = cashModule.getSafeCashbackPercentageAndSplit(address(safe));
    }

    function test_spend_receivesCashback_forSafeAndSpender() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);

        uint256 totalSpendInCashbackToken = cashbackDispatcher.convertUsdToCashbackToken(amount);
        uint256 totalCashback = totalSpendInCashbackToken.mulDiv(initialCashbackPercentage, HUNDRED_PERCENT_IN_BPS);
        uint256 expectedCashbackToSafe = totalCashback.mulDiv(initialSplitToSafeBps, HUNDRED_PERCENT_IN_BPS);
        uint256 expectedCashbackToSpender = totalCashback - expectedCashbackToSafe;

        uint256 totalCashbackInUsd = amount.mulDiv(initialCashbackPercentage, HUNDRED_PERCENT_IN_BPS);
        uint256 expectedCashbackToSafeInUsd = totalCashbackInUsd.mulDiv(initialSplitToSafeBps, HUNDRED_PERCENT_IN_BPS);
        uint256 expectedCashbackToSpenderInUsd = totalCashbackInUsd - expectedCashbackToSafeInUsd;

        uint256 cashbackBalSafeBefore = cashbackToken.balanceOf(address(safe));
        uint256 cashbackBalSpenderBefore = cashbackToken.balanceOf(address(spender));

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), spender, amount, address(scrToken), expectedCashbackToSafe, expectedCashbackToSafeInUsd, expectedCashbackToSpender, expectedCashbackToSpenderInUsd, true);
        cashModule.spend(address(safe), spender, txId, address(usdcScroll), amount, true);

        uint256 cashbackBalSafeAfter = cashbackToken.balanceOf(address(safe));
        uint256 cashbackBalSpenderAfter = cashbackToken.balanceOf(address(spender));

        assertEq(cashbackBalSafeAfter - cashbackBalSafeBefore, expectedCashbackToSafe);
        assertEq(cashbackBalSpenderAfter - cashbackBalSpenderBefore, expectedCashbackToSpender);
    }

    function test_spend_doesNotReceiveCashback_ifShouldReceiveCashbackFlagIsFalse() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);

        uint256 cashbackBalSafeBefore = cashbackToken.balanceOf(address(safe));
        uint256 cashbackBalSpenderBefore = cashbackToken.balanceOf(address(spender));

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), spender, txId, address(usdcScroll), amount, false);

        uint256 cashbackBalSafeAfter = cashbackToken.balanceOf(address(safe));
        uint256 cashbackBalSpenderAfter = cashbackToken.balanceOf(address(spender));

        assertEq(cashbackBalSafeAfter, cashbackBalSafeBefore);
        assertEq(cashbackBalSpenderAfter, cashbackBalSpenderBefore);
    }

    function test_spend_storesPendingCashback_ifNotEnoughBalanceOnCashbackDispatcher() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);
        deal(address(scrToken), address(cashbackDispatcher), 0);

        uint256 totalSpendInCashbackToken = cashbackDispatcher.convertUsdToCashbackToken(amount);
        uint256 totalCashback = totalSpendInCashbackToken.mulDiv(initialCashbackPercentage, HUNDRED_PERCENT_IN_BPS);
        uint256 expectedCashbackToSafe = totalCashback.mulDiv(initialSplitToSafeBps, HUNDRED_PERCENT_IN_BPS);
        uint256 expectedCashbackToSpender = totalCashback - expectedCashbackToSafe;

        uint256 totalCashbackInUsd = amount.mulDiv(initialCashbackPercentage, HUNDRED_PERCENT_IN_BPS);
        uint256 expectedCashbackToSafeInUsd = totalCashbackInUsd.mulDiv(initialSplitToSafeBps, HUNDRED_PERCENT_IN_BPS);
        uint256 expectedCashbackToSpenderInUsd = totalCashbackInUsd - expectedCashbackToSafeInUsd;
        uint256 cashbackBalSafeBefore = cashbackToken.balanceOf(address(safe));
        uint256 cashbackBalSpenderBefore = cashbackToken.balanceOf(address(spender));

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), spender, amount, address(scrToken), expectedCashbackToSafe, expectedCashbackToSafeInUsd, expectedCashbackToSpender, expectedCashbackToSpenderInUsd, false);
        cashModule.spend(address(safe), spender, txId, address(usdcScroll), amount, true);

        uint256 cashbackBalSafeAfter = cashbackToken.balanceOf(address(safe));
        uint256 cashbackBalSpenderAfter = cashbackToken.balanceOf(address(spender));

        assertEq(cashbackBalSafeAfter - cashbackBalSafeBefore, 0);
        assertEq(cashbackBalSpenderAfter - cashbackBalSpenderBefore, 0);

        assertApproxEqAbs(cashModule.getPendingCashback(address(safe)), debtManager.convertCollateralTokenToUsd(address(cashbackToken), expectedCashbackToSafe), 1);
        assertApproxEqAbs(cashModule.getPendingCashback(address(spender)), debtManager.convertCollateralTokenToUsd(address(cashbackToken), expectedCashbackToSpender), 1);
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

        (uint256 cashbackPercentage,) = cashModule.getSafeCashbackPercentageAndSplit(address(safe));
        assertEq(cashbackPercentage, 400); // Chad is 4%
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

    // Test for setTierCashbackPercentage function
    function test_setTierCashbackPercentage_succeeds_whenCalledByController() public {
        SafeTiers[] memory tiers = new SafeTiers[](3);
        tiers[0] = SafeTiers.Pepe;
        tiers[1] = SafeTiers.Wojak;
        tiers[2] = SafeTiers.Chad;

        uint256[] memory percentages = new uint256[](3);
        percentages[0] = 100; // 1%
        percentages[1] = 300; // 3%
        percentages[2] = 500; // 5%

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.TierCashbackPercentageSet(tiers, percentages);
        cashModule.setTierCashbackPercentage(tiers, percentages);

        // Set safe to chad tier
        address[] memory safes = new address[](1);
        safes[0] = address(safe);

        SafeTiers[] memory safeTiers = new SafeTiers[](1);
        safeTiers[0] = SafeTiers.Chad;

        vm.prank(etherFiWallet);
        cashModule.setSafeTier(safes, safeTiers);

        // Check if the cashback percentage is correctly set
        (uint256 cashbackPercentage,) = cashModule.getSafeCashbackPercentageAndSplit(address(safe));
        assertEq(cashbackPercentage, 500);
    }

    function test_setTierCashbackPercentage_fails_whenCalledByNonController() public {
        SafeTiers[] memory tiers = new SafeTiers[](1);
        tiers[0] = SafeTiers.Chad;

        uint256[] memory percentages = new uint256[](1);
        percentages[0] = 500; // 5%

        vm.prank(makeAddr("nonController"));
        vm.expectRevert(ICashModule.OnlyCashModuleController.selector);
        cashModule.setTierCashbackPercentage(tiers, percentages);
    }

    function test_setTierCashbackPercentage_fails_whenArrayLengthMismatch() public {
        SafeTiers[] memory tiers = new SafeTiers[](2);
        tiers[0] = SafeTiers.Pepe;
        tiers[1] = SafeTiers.Chad;

        uint256[] memory percentages = new uint256[](1);
        percentages[0] = 500; // 5%

        vm.prank(owner);
        vm.expectRevert(ICashModule.ArrayLengthMismatch.selector);
        cashModule.setTierCashbackPercentage(tiers, percentages);
    }

    function test_setTierCashbackPercentage_fails_whenPercentageExceedsMaxAllowed() public {
        SafeTiers[] memory tiers = new SafeTiers[](1);
        tiers[0] = SafeTiers.Chad;

        uint256[] memory percentages = new uint256[](1);
        percentages[0] = 1100; // 11%, exceeds 10% max

        vm.prank(owner);
        vm.expectRevert(ICashModule.CashbackPercentageGreaterThanMaxAllowed.selector);
        cashModule.setTierCashbackPercentage(tiers, percentages);
    }

    // Test for setCashbackSplitToSafeBps function
    function test_setCashbackSplitToSafeBps_succeeds_whenCalledBySafeAdmin() public {
        uint256 newSplitBps = 7000; // 70%
        bytes memory signature = _setCashbackSplitToSafePercentage(newSplitBps);

        (, uint256 oldSplitBps) = cashModule.getSafeCashbackPercentageAndSplit(address(safe));

        vm.prank(address(safe));
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.CashbackSplitToSafeBpsSet(address(safe), oldSplitBps, newSplitBps);
        cashModule.setCashbackSplitToSafeBps(address(safe), newSplitBps, owner1, signature);

        // Check if the split percentage is correctly set
        (, uint256 splitBps) = cashModule.getSafeCashbackPercentageAndSplit(address(safe));
        assertEq(splitBps, newSplitBps);
    }

    function test_setCashbackSplitToSafeBps_fails_whenCalledWithSameValue() public {
        uint256 currentSplitBps = initialSplitToSafeBps;
        bytes memory signature = _setCashbackSplitToSafePercentage(currentSplitBps);

        vm.prank(address(safe));
        vm.expectRevert(ICashModule.SplitAlreadyTheSame.selector);
        cashModule.setCashbackSplitToSafeBps(address(safe), currentSplitBps, owner1, signature);
    }

    function test_setCashbackSplitToSafeBps_fails_whenCalledWithInvalidPercentage() public {
        uint256 invalidSplitBps = 11_000; // 110%, exceeds 100%
        bytes memory signature = _setCashbackSplitToSafePercentage(invalidSplitBps);

        vm.prank(address(safe));
        vm.expectRevert(ICashModule.InvalidInput.selector);
        cashModule.setCashbackSplitToSafeBps(address(safe), invalidSplitBps, owner1, signature);
    }

    function test_setCashbackSplitToSafeBps_fails_whenCalledWithInvalidSignature() public {
        uint256 newSplitBps = 7000; // 70%

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, keccak256("abcd"));
        bytes memory invalidSignature = abi.encodePacked(r, s, v);

        vm.prank(address(safe));
        vm.expectRevert(SignatureUtils.InvalidSigner.selector);
        cashModule.setCashbackSplitToSafeBps(address(safe), newSplitBps, owner1, invalidSignature);
    }

    // Test for clearPendingCashback function integration with CashModule
    function test_clearsPendingCashback_whenFundsAreAvailable() public {
        // Setup pending cashback
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), 2 * amount);
        deal(address(scrToken), address(cashbackDispatcher), 0); // Ensure no funds for initial cashback

        bytes memory signature = _setCashbackSplitToSafePercentage(50_00); // 50%
        cashModule.setCashbackSplitToSafeBps(address(safe), 50_00, owner1, signature);

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), spender, txId, address(usdcScroll), amount, true);

        // Verify pending cashback is stored
        uint256 safePendingCashback = cashModule.getPendingCashback(address(safe));
        uint256 spenderPendingCashback = cashModule.getPendingCashback(address(spender));

        uint256 cashbackTokenPrice = priceProvider.price(address(scrToken));
        uint256 safePendingCashbackInCashbackToken = safePendingCashback.mulDiv(1e18, cashbackTokenPrice);
        uint256 spenderPendingCashbackInCashbackToken = safePendingCashback.mulDiv(1e18, cashbackTokenPrice);

        assertGt(safePendingCashback, 0);
        assertGt(spenderPendingCashback, 0);

        // Now add funds to the cashback dispatcher
        deal(address(scrToken), address(cashbackDispatcher), 1000 ether);

        // Make another spend which should trigger clearing pending cashback
        bytes32 newTxId = keccak256("newTxId");

        uint256 cashbackTokenSafeBalBefore = cashbackToken.balanceOf(address(safe));
        uint256 cashbackTokenSpenderBalBefore = cashbackToken.balanceOf(address(spender));

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.PendingCashbackCleared(address(safe), address(safe), address(scrToken), safePendingCashbackInCashbackToken, safePendingCashback);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.PendingCashbackCleared(address(safe), address(spender), address(scrToken), spenderPendingCashbackInCashbackToken, spenderPendingCashback);
        cashModule.spend(address(safe), spender, newTxId, address(usdcScroll), amount, true);

        // Verify pending cashback is cleared
        assertEq(cashModule.getPendingCashback(address(safe)), 0);
        assertEq(cashModule.getPendingCashback(address(spender)), 0);

        assertGt(cashbackToken.balanceOf(address(safe)), cashbackTokenSafeBalBefore);
        assertGt(cashbackToken.balanceOf(address(spender)), cashbackTokenSpenderBalBefore);
    }

    function test_doesNotClearPendingCashback_whenFundsAreStillUnavailable() public {
        // Setup pending cashback
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount * 2); // Ensure enough balance for two spends
        deal(address(scrToken), address(cashbackDispatcher), 0); // Ensure no funds for cashbac
        
        uint256 newSplitBps = 50_00; // 50%
        bytes memory signature = _setCashbackSplitToSafePercentage(newSplitBps); 
        cashModule.setCashbackSplitToSafeBps(address(safe), newSplitBps, owner1, signature);

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), spender, txId, address(usdcScroll), amount, true);

        // Verify pending cashback is stored
        uint256 safePendingCashback = cashModule.getPendingCashback(address(safe));
        uint256 spenderPendingCashback = cashModule.getPendingCashback(address(spender));

        assertGt(safePendingCashback, 0);
        assertGt(spenderPendingCashback, 0);

        // Make another spend without adding funds to cashback dispatcher
        bytes32 newTxId = keccak256("newTxId");

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), spender, newTxId, address(usdcScroll), amount, true);

        // Verify pending cashback is accumulated
        assertGt(cashModule.getPendingCashback(address(safe)), safePendingCashback);
        assertGt(cashModule.getPendingCashback(address(spender)), spenderPendingCashback);
    }

    // Test for spend with cashback when spender is address(0)
    function test_spend_appliesFullCashbackToSafe_whenSpenderIsZeroAddress() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);

        uint256 totalSpendInCashbackToken = cashbackDispatcher.convertUsdToCashbackToken(amount);
        uint256 totalCashback = totalSpendInCashbackToken.mulDiv(initialCashbackPercentage, HUNDRED_PERCENT_IN_BPS);

        uint256 cashbackBalSafeBefore = cashbackToken.balanceOf(address(safe));

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), txId, address(usdcScroll), amount, true);

        uint256 cashbackBalSafeAfter = cashbackToken.balanceOf(address(safe));

        // In CashbackDispatcher, when spender is address(0), safe gets 100% of cashback
        assertEq(cashbackBalSafeAfter - cashbackBalSafeBefore, totalCashback);
    }

    // Test for spend with different tiers having different cashback percentages
    function test_spend_appliesDifferentCashbackRates_forDifferentTiers() public {
        // Setup different tiers with different cashback percentages
        SafeTiers[] memory tiers = new SafeTiers[](3);
        tiers[0] = SafeTiers.Pepe;
        tiers[1] = SafeTiers.Wojak;
        tiers[2] = SafeTiers.Chad;

        uint256[] memory percentages = new uint256[](3);
        percentages[0] = 100; // 1%
        percentages[1] = 300; // 3%
        percentages[2] = 500; // 5%

        vm.prank(owner);
        cashModule.setTierCashbackPercentage(tiers, percentages);

        // Test pepe tier
        address[] memory safes = new address[](1);
        safes[0] = address(safe);

        SafeTiers[] memory safeTiers = new SafeTiers[](1);
        safeTiers[0] = SafeTiers.Pepe;

        // skipping first one since its already pepe
        // vm.prank(etherFiWallet);
        // cashModule.setSafeTier(safes, safeTiers);

        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount * 3); // Enough for 3 tests

        uint256 totalSpendInCashbackToken = cashbackDispatcher.convertUsdToCashbackToken(amount);
        uint256 pepeCashback = totalSpendInCashbackToken.mulDiv(100, HUNDRED_PERCENT_IN_BPS);

        uint256 cashbackBalSafeBefore = cashbackToken.balanceOf(address(safe));
        uint256 cashbackBalSpenderBefore = cashbackToken.balanceOf(address(spender));

        bytes32 pepeTxId = keccak256("pepeTxId");
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), spender, pepeTxId, address(usdcScroll), amount, true);

        uint256 pepeSafeCashback = pepeCashback.mulDiv(initialSplitToSafeBps, HUNDRED_PERCENT_IN_BPS);
        uint256 pepeSpenderCashback = pepeCashback - pepeSafeCashback;

        assertEq(cashbackToken.balanceOf(address(safe)) - cashbackBalSafeBefore, pepeSafeCashback);
        assertEq(cashbackToken.balanceOf(address(spender)) - cashbackBalSpenderBefore, pepeSpenderCashback);

        // Test chad tier
        safeTiers[0] = SafeTiers.Chad;
        vm.prank(etherFiWallet);
        cashModule.setSafeTier(safes, safeTiers);

        uint256 chadCashback = totalSpendInCashbackToken.mulDiv(500, HUNDRED_PERCENT_IN_BPS);

        cashbackBalSafeBefore = cashbackToken.balanceOf(address(safe));
        cashbackBalSpenderBefore = cashbackToken.balanceOf(address(spender));

        bytes32 chadTxId = keccak256("chadTxId");
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), spender, chadTxId, address(usdcScroll), amount, true);

        uint256 chadSafeCashback = chadCashback.mulDiv(initialSplitToSafeBps, HUNDRED_PERCENT_IN_BPS);
        uint256 chadSpenderCashback = chadCashback - chadSafeCashback;

        assertApproxEqAbs(cashbackToken.balanceOf(address(safe)) - cashbackBalSafeBefore, chadSafeCashback, 10);
        assertApproxEqAbs(cashbackToken.balanceOf(address(spender)) - cashbackBalSpenderBefore, chadSpenderCashback, 10);

        // chad should be 5 times pepe
        assertApproxEqAbs(chadSafeCashback, pepeSafeCashback * 5, 10);
    }

    function _setCashbackSplitToSafePercentage(uint256 splitPercentage) internal view returns (bytes memory) {
        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.SET_CASHBACK_SPLIT_TO_SAFE_PERCENTAGE, block.chainid, safe, cashModule.getNonce(address(safe)), abi.encode(splitPercentage))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        return abi.encodePacked(r, s, v);
    }
}
