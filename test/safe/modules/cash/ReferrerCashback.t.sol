// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { SafeTiers } from "../../../../src/interfaces/ICashModule.sol";

import { SignatureUtils } from "../../../../src/libraries/SignatureUtils.sol";
import { ModuleBase } from "../../../../src/modules/ModuleBase.sol";
import { CashEventEmitter } from "../../../../src/modules/cash/CashEventEmitter.sol";
import { CashModuleTestSetup, DebtManagerCore, DebtManagerAdmin, CashVerificationLib, ICashModule, IERC20, MessageHashUtils } from "./CashModuleTestSetup.t.sol";
import { BinSponsor } from "../../../../src/interfaces/ICashModule.sol";

contract CashModuleReferrerCashbackTest is CashModuleTestSetup {
    using Math for uint256;
    using MessageHashUtils for bytes32;

    address referrer = makeAddr("referrer");
    address spender = makeAddr("spender");
    uint64 referrerCashbackPercentage;
    IERC20 cashbackToken = scrToken;

    function setUp() public override {
        super.setUp();
        referrerCashbackPercentage = cashModule.getReferrerCashbackPercentage();
    }

    function test_spend_providesReferrerCashback_whenReferrerIsSpecified() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);

        uint256 totalSpendInCashbackToken = cashbackDispatcher.convertUsdToCashbackToken(amount);
        uint256 referrerCashbackAmount = totalSpendInCashbackToken.mulDiv(referrerCashbackPercentage, HUNDRED_PERCENT_IN_BPS);
        uint256 referrerCashbackInUsd = amount.mulDiv(referrerCashbackPercentage, HUNDRED_PERCENT_IN_BPS);

        uint256 cashbackBalReferrerBefore = cashbackToken.balanceOf(address(referrer));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.ReferrerCashback(address(safe), referrer, amount, address(scrToken), referrerCashbackAmount, referrerCashbackInUsd, true);
        cashModule.spend(address(safe), spender, referrer, txId, BinSponsor.Reap, spendTokens, spendAmounts, true);

        uint256 cashbackBalReferrerAfter = cashbackToken.balanceOf(address(referrer));

        assertEq(cashbackBalReferrerAfter - cashbackBalReferrerBefore, referrerCashbackAmount);
    }

    function test_spend_doesNotProvideReferrerCashback_whenReferrerIsAddressZero() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);

        uint256 cashbackBalReferrerBefore = cashbackToken.balanceOf(address(referrer));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), spender, address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, true);

        uint256 cashbackBalReferrerAfter = cashbackToken.balanceOf(address(referrer));

        assertEq(cashbackBalReferrerAfter, cashbackBalReferrerBefore);
    }

    function test_spend_doesNotProvideReferrerCashback_whenShouldReceiveCashbackIsFalse() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);

        uint256 cashbackBalReferrerBefore = cashbackToken.balanceOf(address(referrer));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), spender, referrer, txId, BinSponsor.Reap, spendTokens, spendAmounts, false);

        uint256 cashbackBalReferrerAfter = cashbackToken.balanceOf(address(referrer));

        assertEq(cashbackBalReferrerAfter, cashbackBalReferrerBefore);
    }

    function test_spend_storesPendingReferrerCashback_ifNotEnoughBalanceOnCashbackDispatcher() public {
        // Setup collateral tokens
        vm.startPrank(owner);
        address[] memory collateralTokens = new address[](1);
        collateralTokens[0] = address(scrToken);

        DebtManagerCore.CollateralTokenConfig[] memory collateralTokenConfig = new DebtManagerCore.CollateralTokenConfig[](1);
        collateralTokenConfig[0].ltv = ltv;
        collateralTokenConfig[0].liquidationThreshold = liquidationThreshold;
        collateralTokenConfig[0].liquidationBonus = liquidationBonus;

        DebtManagerAdmin(address(debtManager)).supportCollateralToken(address(scrToken), collateralTokenConfig[0]);
        vm.stopPrank();

        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);
        deal(address(scrToken), address(cashbackDispatcher), 0); // Ensure no funds for cashback

        uint256 totalSpendInCashbackToken = cashbackDispatcher.convertUsdToCashbackToken(amount);
        uint256 referrerCashbackAmount = totalSpendInCashbackToken.mulDiv(referrerCashbackPercentage, HUNDRED_PERCENT_IN_BPS);
        uint256 referrerCashbackInUsd = amount.mulDiv(referrerCashbackPercentage, HUNDRED_PERCENT_IN_BPS);

        uint256 cashbackBalReferrerBefore = cashbackToken.balanceOf(address(referrer));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.ReferrerCashback(address(safe), referrer, amount, address(scrToken), referrerCashbackAmount, referrerCashbackInUsd, false);
        cashModule.spend(address(safe), spender, referrer, txId, BinSponsor.Reap, spendTokens, spendAmounts, true);

        uint256 cashbackBalReferrerAfter = cashbackToken.balanceOf(address(referrer));

        assertEq(cashbackBalReferrerAfter - cashbackBalReferrerBefore, 0);
        assertApproxEqAbs(cashModule.getPendingCashback(address(referrer)), debtManager.convertCollateralTokenToUsd(address(cashbackToken), referrerCashbackAmount), 1);
    }

    function test_clearPendingCashback_clearsReferrerCashback_whenFundsAreAvailable() public {
        // Setup pending cashback
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);
        deal(address(scrToken), address(cashbackDispatcher), 0); // Ensure no funds for initial cashback

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), spender, referrer, txId, BinSponsor.Reap, spendTokens, spendAmounts, true);

        // Verify pending cashback is stored
        uint256 referrerPendingCashback = cashModule.getPendingCashback(address(referrer));
        assertGt(referrerPendingCashback, 0);

        // Now add funds to the cashback dispatcher
        deal(address(scrToken), address(cashbackDispatcher), 1000 ether);

        uint256 cashbackTokenPrice = priceProvider.price(address(scrToken));
        uint256 referrerPendingCashbackInCashbackToken = referrerPendingCashback.mulDiv(1e18, cashbackTokenPrice);

        uint256 cashbackTokenReferrerBalBefore = cashbackToken.balanceOf(address(referrer));

        // Clear the pending cashback
        address[] memory users = new address[](1);
        users[0] = referrer;

        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.PendingCashbackCleared(address(referrer), address(scrToken), referrerPendingCashbackInCashbackToken, referrerPendingCashback);
        cashModule.clearPendingCashback(users);

        // Verify pending cashback is cleared
        assertEq(cashModule.getPendingCashback(address(referrer)), 0);
        assertGt(cashbackToken.balanceOf(address(referrer)), cashbackTokenReferrerBalBefore);
    }

    function test_setReferrerCashbackPercentageInBps_succeeds_whenCalledByController() public {
        uint64 newPercentage = 200; // 2%
        
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.ReferrerCashbackPercentageSet(referrerCashbackPercentage, newPercentage);
        cashModule.setReferrerCashbackPercentageInBps(newPercentage);

        assertEq(cashModule.getReferrerCashbackPercentage(), newPercentage);
    }

    function test_setReferrerCashbackPercentageInBps_fails_whenCalledByNonController() public {
        uint64 newPercentage = 200; // 2%
        
        vm.prank(makeAddr("nonController"));
        vm.expectRevert(ICashModule.OnlyCashModuleController.selector);
        cashModule.setReferrerCashbackPercentageInBps(newPercentage);
    }

    function test_setReferrerCashbackPercentageInBps_fails_whenPercentageExceedsMaxAllowed() public {
        uint64 invalidPercentage = 11_000; // 110%, exceeds 100%
        
        vm.prank(owner);
        vm.expectRevert(ICashModule.InvalidInput.selector);
        cashModule.setReferrerCashbackPercentageInBps(invalidPercentage);
    }

    function test_spend_appliesCorrectReferrerCashbackRate_afterPercentageChange() public {
        uint64 newPercentage = 300; // 3%
        
        vm.prank(owner);
        cashModule.setReferrerCashbackPercentageInBps(newPercentage);

        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);

        uint256 totalSpendInCashbackToken = cashbackDispatcher.convertUsdToCashbackToken(amount);
        uint256 referrerCashbackAmount = totalSpendInCashbackToken.mulDiv(newPercentage, HUNDRED_PERCENT_IN_BPS);
        uint256 referrerCashbackInUsd = amount.mulDiv(newPercentage, HUNDRED_PERCENT_IN_BPS);

        uint256 cashbackBalReferrerBefore = cashbackToken.balanceOf(address(referrer));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.ReferrerCashback(address(safe), referrer, amount, address(scrToken), referrerCashbackAmount, referrerCashbackInUsd, true);
        cashModule.spend(address(safe), spender, referrer, txId, BinSponsor.Reap, spendTokens, spendAmounts, true);

        uint256 cashbackBalReferrerAfter = cashbackToken.balanceOf(address(referrer));

        assertEq(cashbackBalReferrerAfter - cashbackBalReferrerBefore, referrerCashbackAmount);
    }
}