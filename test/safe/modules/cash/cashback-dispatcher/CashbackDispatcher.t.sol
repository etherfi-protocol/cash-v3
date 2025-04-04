// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { CashModuleTestSetup } from "../CashModuleTestSetup.t.sol";
import { Mode, SafeTiers } from "../../../../../src/interfaces/ICashModule.sol";
import { CashVerificationLib } from "../../../../../src/libraries/CashVerificationLib.sol";
import { CashEventEmitter } from "../../../../../src/modules/cash/CashEventEmitter.sol";
import { CashbackDispatcher } from "../../../../../src/cashback-dispatcher/CashbackDispatcher.sol";
import { MockPriceProvider } from "../../../../../src/mocks/MockPriceProvider.sol";
import { PriceProvider, IAggregatorV3 } from "../../../../../src/oracle/PriceProvider.sol";
import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";
import { IDebtManager } from "../../../../../src/interfaces/IDebtManager.sol";
import { UpgradeableProxy } from "../../../../../src/utils/UpgradeableProxy.sol";

contract CashbackDispatcherTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;

    uint256 pepeCashbackPercentage = 200;
    uint256 wojakCashbackPercentage = 300;
    uint256 chadCashbackPercentage = 400;
    uint256 whaleCashbackPercentage = 500;

    address newCashModuleAddress = makeAddr("newCashModuleAddress");

    ETHRejecter ethRejecter;

    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);

        SafeTiers[] memory userSafeTiers = new SafeTiers[](4);
        userSafeTiers[0] = SafeTiers.Pepe;
        userSafeTiers[1] = SafeTiers.Wojak;
        userSafeTiers[2] = SafeTiers.Chad;
        userSafeTiers[3] = SafeTiers.Whale;

        uint256[] memory cashbackPercentages = new uint256[](4);
        cashbackPercentages[0] = pepeCashbackPercentage;
        cashbackPercentages[1] = wojakCashbackPercentage;
        cashbackPercentages[2] = chadCashbackPercentage;
        cashbackPercentages[3] = whaleCashbackPercentage;

        cashModule.setTierCashbackPercentage(userSafeTiers, cashbackPercentages);

        ethRejecter = new ETHRejecter();

        vm.stopPrank();
    }

    function test_deploy_initializesCorrectValues() public view {
        assertEq(address(cashbackDispatcher.etherFiDataProvider()), address(dataProvider));
        assertEq(address(cashbackDispatcher.priceProvider()), address(priceProvider));
        assertEq(cashbackDispatcher.cashbackToken(), address(scrToken));
        assertEq(cashbackDispatcher.cashModule(), address(cashModule));

        assertEq(uint8(cashModule.getSafeTier(address(safe))), uint8(SafeTiers.Pepe));
        assertEq(cashModule.getTierCashbackPercentage(SafeTiers.Pepe), pepeCashbackPercentage);
        assertEq(cashModule.getTierCashbackPercentage(SafeTiers.Wojak), wojakCashbackPercentage);
        assertEq(cashModule.getTierCashbackPercentage(SafeTiers.Chad), chadCashbackPercentage);
        assertEq(cashModule.getTierCashbackPercentage(SafeTiers.Whale), whaleCashbackPercentage);
    }

    function test_processCashback_providesCashback_inDebitFlowWithPepeTier() public {
        uint256 spendAmt = 100e6;
        deal(address(usdcScroll), address(safe), 100e6);
        deal(address(scrToken), address(cashbackDispatcher), 100 ether);
        
        // owner is pepe, so cashback is 2% -> 2 USDC in scroll tokens
        uint256 cashbackInUsdc = (spendAmt * pepeCashbackPercentage) / HUNDRED_PERCENT_IN_BPS;
        uint256 cashbackInScroll = (cashbackInUsdc * 10 ** IERC20Metadata(address(scrToken)).decimals()) / priceProvider.price(address(scrToken));

        uint256 safeScrBalBefore = scrToken.balanceOf(address(safe));
        
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmt;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), address(0), spendAmt, address(scrToken), cashbackInScroll, cashbackInUsdc, 0, 0, true);
        cashModule.spend(address(safe), address(0), address(0), txId, spendTokens, spendAmounts, true);

        uint256 safeScrBalAfter = scrToken.balanceOf(address(safe));
        assertApproxEqAbs(safeScrBalAfter - safeScrBalBefore, cashbackInScroll, 1000);
    }

    function test_processCashback_providesCashback_inCreditFlowWithPepeTier() public {
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);

        uint256 spendAmt = 100e6;
        deal(address(usdcScroll), address(safe), 10000e6);
        deal(address(usdcScroll), address(debtManager), 10000e6);
        deal(address(scrToken), address(cashbackDispatcher), 100 ether);
        
        // owner is pepe, so cashback is 2% -> 2 USDC in scroll tokens
        uint256 cashbackInUsdc = (spendAmt * pepeCashbackPercentage) / HUNDRED_PERCENT_IN_BPS;
        uint256 cashbackInScroll = (cashbackInUsdc * 10 ** IERC20Metadata(address(scrToken)).decimals()) / priceProvider.price(address(scrToken));

        uint256 safeScrBalBefore = scrToken.balanceOf(address(safe));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmt;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), address(0), spendAmt, address(scrToken), cashbackInScroll, cashbackInUsdc, 0, 0, true);
        cashModule.spend(address(safe), address(0), address(0), txId, spendTokens, spendAmounts, true);

        uint256 safeScrBalAfter = scrToken.balanceOf(address(safe));
        assertApproxEqAbs(safeScrBalAfter - safeScrBalBefore, cashbackInScroll, 1000);
    }

    function test_processCashback_providesCashback_inDebitFlowWithWojakTier() public {
        setTier(SafeTiers.Wojak);

        uint256 spendAmt = 100e6;
        deal(address(usdcScroll), address(safe), 100e6);
        deal(address(scrToken), address(cashbackDispatcher), 100 ether);
        
        uint256 cashbackInUsdc = (spendAmt * wojakCashbackPercentage) / HUNDRED_PERCENT_IN_BPS;
        uint256 cashbackInScroll = (cashbackInUsdc * 10 ** IERC20Metadata(address(scrToken)).decimals()) / priceProvider.price(address(scrToken));

        uint256 safeScrBalBefore = scrToken.balanceOf(address(safe));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmt;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), address(0), spendAmt, address(scrToken), cashbackInScroll, cashbackInUsdc, 0, 0, true);
        cashModule.spend(address(safe), address(0), address(0), txId, spendTokens, spendAmounts, true);

        uint256 safeScrBalAfter = scrToken.balanceOf(address(safe));
        assertApproxEqAbs(safeScrBalAfter - safeScrBalBefore, cashbackInScroll, 1000);
    }

    function test_processCashback_providesCashback_inCreditFlowWithWojakTier() public {
        setTier(SafeTiers.Wojak);

        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);

        uint256 spendAmt = 100e6;
        deal(address(usdcScroll), address(safe), 10000e6);
        deal(address(usdcScroll), address(debtManager), 10000e6);
        deal(address(scrToken), address(cashbackDispatcher), 100 ether);
        
        uint256 cashbackInUsdc = (spendAmt * wojakCashbackPercentage) / HUNDRED_PERCENT_IN_BPS;
        uint256 cashbackInScroll = (cashbackInUsdc * 10 ** IERC20Metadata(address(scrToken)).decimals()) / priceProvider.price(address(scrToken));

        uint256 safeScrBalBefore = scrToken.balanceOf(address(safe));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmt;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), address(0), spendAmt, address(scrToken), cashbackInScroll, cashbackInUsdc, 0, 0, true);
        cashModule.spend(address(safe), address(0), address(0), txId, spendTokens, spendAmounts, true);

        uint256 safeScrBalAfter = scrToken.balanceOf(address(safe));
        assertApproxEqAbs(safeScrBalAfter - safeScrBalBefore, cashbackInScroll, 1000);
    }

    function test_processCashback_providesCashback_inDebitFlowWithChadTier() public {
        setTier(SafeTiers.Chad);

        uint256 spendAmt = 100e6;
        deal(address(usdcScroll), address(safe), 100e6);
        deal(address(scrToken), address(cashbackDispatcher), 100 ether);
        
        uint256 cashbackInUsdc = (spendAmt * chadCashbackPercentage) / HUNDRED_PERCENT_IN_BPS;
        uint256 cashbackInScroll = (cashbackInUsdc * 10 ** IERC20Metadata(address(scrToken)).decimals()) / priceProvider.price(address(scrToken));

        uint256 safeScrBalBefore = scrToken.balanceOf(address(safe));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmt;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), address(0), spendAmt, address(scrToken), cashbackInScroll, cashbackInUsdc, 0, 0, true);
        cashModule.spend(address(safe), address(0), address(0), txId, spendTokens, spendAmounts, true);

        uint256 safeScrBalAfter = scrToken.balanceOf(address(safe));
        assertApproxEqAbs(safeScrBalAfter - safeScrBalBefore, cashbackInScroll, 1000);
    }

    function test_processCashback_providesCashback_inCreditFlowWithChadTier() public {
        setTier(SafeTiers.Chad);

        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);

        uint256 spendAmt = 100e6;
        deal(address(usdcScroll), address(safe), 10000e6);
        deal(address(usdcScroll), address(debtManager), 10000e6);
        deal(address(scrToken), address(cashbackDispatcher), 100 ether);
        
        uint256 cashbackInUsdc = (spendAmt * chadCashbackPercentage) / HUNDRED_PERCENT_IN_BPS;
        uint256 cashbackInScroll = (cashbackInUsdc * 10 ** IERC20Metadata(address(scrToken)).decimals()) / priceProvider.price(address(scrToken));

        uint256 safeScrBalBefore = scrToken.balanceOf(address(safe));
        
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmt;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), address(0), spendAmt, address(scrToken), cashbackInScroll, cashbackInUsdc, 0, 0, true);
        cashModule.spend(address(safe), address(0), address(0), txId, spendTokens, spendAmounts, true);

        uint256 safeScrBalAfter = scrToken.balanceOf(address(safe));
        assertApproxEqAbs(safeScrBalAfter - safeScrBalBefore, cashbackInScroll, 1000);
    }

    function test_processCashback_providesCashback_inDebitFlowWithWhaleTier() public {
        setTier(SafeTiers.Whale);

        uint256 spendAmt = 100e6;
        deal(address(usdcScroll), address(safe), 100e6);
        deal(address(scrToken), address(cashbackDispatcher), 100 ether);
        
        uint256 cashbackInUsdc = (spendAmt * whaleCashbackPercentage) / HUNDRED_PERCENT_IN_BPS;
        uint256 cashbackInScroll = (cashbackInUsdc * 10 ** IERC20Metadata(address(scrToken)).decimals()) / priceProvider.price(address(scrToken));

        uint256 safeScrBalBefore = scrToken.balanceOf(address(safe));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmt;
        
        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), address(0), spendAmt, address(scrToken), cashbackInScroll, cashbackInUsdc, 0, 0, true);
        cashModule.spend(address(safe), address(0), address(0), txId, spendTokens, spendAmounts, true);

        uint256 safeScrBalAfter = scrToken.balanceOf(address(safe));
        assertApproxEqAbs(safeScrBalAfter - safeScrBalBefore, cashbackInScroll, 1000);
    }

    function test_processCashback_providesCashback_inCreditFlowWithWhaleTier() public {
        setTier(SafeTiers.Whale);

        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);

        uint256 spendAmt = 100e6;
        deal(address(usdcScroll), address(safe), 10000e6);
        deal(address(usdcScroll), address(debtManager), 10000e6);
        deal(address(scrToken), address(cashbackDispatcher), 100 ether);
        
        uint256 cashbackInUsdc = (spendAmt * whaleCashbackPercentage) / HUNDRED_PERCENT_IN_BPS;
        uint256 cashbackInScroll = (cashbackInUsdc * 10 ** IERC20Metadata(address(scrToken)).decimals()) / priceProvider.price(address(scrToken));

        uint256 safeScrBalBefore = scrToken.balanceOf(address(safe));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmt;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), address(0), spendAmt, address(scrToken), cashbackInScroll, cashbackInUsdc, 0, 0, true);
        cashModule.spend(address(safe), address(0), address(0), txId, spendTokens, spendAmounts, true);

        uint256 safeScrBalAfter = scrToken.balanceOf(address(safe));
        assertApproxEqAbs(safeScrBalAfter - safeScrBalBefore, cashbackInScroll, 1000);
    }

    function test_processCashback_storesPendingCashback_whenInsufficientFunds() public {
        deal(address(scrToken), address(cashbackDispatcher), 0);
        
        uint256 spendAmt = 100e6;
        deal(address(usdcScroll), address(safe), 100e6);
        
        // owner is pepe, so cashback is 2% -> 2 USDC in scroll tokens
        uint256 cashbackInUsdc = (spendAmt * pepeCashbackPercentage) / HUNDRED_PERCENT_IN_BPS;
        uint256 cashbackInScroll = (cashbackInUsdc * 10 ** IERC20Metadata(address(scrToken)).decimals()) / priceProvider.price(address(scrToken));

        uint256 safePendingCashbackBefore = cashModule.getPendingCashback(address(safe));
        assertEq(safePendingCashbackBefore, 0);

        uint256 safeScrBalBefore = scrToken.balanceOf(address(safe));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmt;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), address(0), spendAmt, address(scrToken), cashbackInScroll, cashbackInUsdc, 0, 0, false);
        cashModule.spend(address(safe), address(0), address(0), txId, spendTokens, spendAmounts, true);

        uint256 safeScrBalAfter = scrToken.balanceOf(address(safe));
        assertEq(safeScrBalAfter, safeScrBalBefore);

        uint256 safePendingCashbackAfter = cashModule.getPendingCashback(address(safe));
        assertEq(safePendingCashbackAfter, cashbackInUsdc);
    }

    function test_processCashback_accumulatesPendingCashback_whenFundsRemainUnavailable() public {
        deal(address(scrToken), address(cashbackDispatcher), 0);
        uint256 spendAmt = 100e6;
        deal(address(usdcScroll), address(safe), spendAmt);
        
        // owner is pepe, so cashback is 2% -> 2 USDC in scroll tokens
        uint256 cashbackInUsdc = (spendAmt * pepeCashbackPercentage) / HUNDRED_PERCENT_IN_BPS;
        uint256 cashbackInScroll = (cashbackInUsdc * 10 ** IERC20Metadata(address(scrToken)).decimals()) / priceProvider.price(address(scrToken));

        uint256 safePendingCashbackBefore = cashModule.getPendingCashback(address(safe));
        assertEq(safePendingCashbackBefore, 0);

        uint256 safeScrBalBefore = scrToken.balanceOf(address(safe));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmt;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), address(0), spendAmt, address(scrToken), cashbackInScroll, cashbackInUsdc, 0, 0, false);
        cashModule.spend(address(safe), address(0), address(0), txId, spendTokens, spendAmounts, true);

        uint256 safeScrBalAfter = scrToken.balanceOf(address(safe));
        assertEq(safeScrBalAfter, safeScrBalBefore);

        uint256 safePendingCashbackAfter = cashModule.getPendingCashback(address(safe));
        assertEq(safePendingCashbackAfter, cashbackInUsdc);

        deal(address(usdcScroll), address(safe), spendAmt);
        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), address(0), spendAmt, address(scrToken), cashbackInScroll, cashbackInUsdc, 0, 0, false);
        cashModule.spend(address(safe), address(0), address(0), keccak256("newTxId"), spendTokens, spendAmounts, true);

        safePendingCashbackAfter = cashModule.getPendingCashback(address(safe));
        assertEq(safePendingCashbackAfter, cashbackInUsdc * 2);
    }

    function test_processCashback_paysPending_whenFundsBecomesAvailable() public {
        deal(address(scrToken), address(cashbackDispatcher), 0);
        uint256 spendAmt = 100e6;
        deal(address(usdcScroll), address(safe), spendAmt);
        
        // owner is pepe, so cashback is 2% -> 2 USDC in scroll tokens
        uint256 cashbackInUsdc = (spendAmt * pepeCashbackPercentage) / HUNDRED_PERCENT_IN_BPS;
        uint256 cashbackInScroll = (cashbackInUsdc * 10 ** IERC20Metadata(address(scrToken)).decimals()) / priceProvider.price(address(scrToken));

        uint256 safePendingCashbackBefore = cashModule.getPendingCashback(address(safe));
        assertEq(safePendingCashbackBefore, 0);

        uint256 safeScrBalBefore = scrToken.balanceOf(address(safe));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmt;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), address(0), spendAmt, address(scrToken), cashbackInScroll, cashbackInUsdc, 0, 0, false);
        cashModule.spend(address(safe), address(0), address(0), txId, spendTokens, spendAmounts, true);

        uint256 safeScrBalAfter = scrToken.balanceOf(address(safe));
        assertEq(safeScrBalAfter, safeScrBalBefore);

        uint256 safePendingCashbackAfter = cashModule.getPendingCashback(address(safe));
        assertEq(safePendingCashbackAfter, cashbackInUsdc);

        deal(address(usdcScroll), address(safe), spendAmt);
        deal(address(scrToken), address(cashbackDispatcher), 1000 ether);

        safeScrBalBefore = scrToken.balanceOf(address(safe));

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.PendingCashbackCleared(address(safe), address(scrToken), cashbackInScroll, cashbackInUsdc);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), address(0), spendAmt, address(scrToken), cashbackInScroll, cashbackInUsdc, 0, 0, true);
        cashModule.spend(address(safe), address(0), address(0), keccak256("newTxId"), spendTokens, spendAmounts, true);

        safePendingCashbackAfter = cashModule.getPendingCashback(address(safe));
        assertEq(safePendingCashbackAfter, 0);

        safeScrBalAfter = scrToken.balanceOf(address(safe));
        assertApproxEqAbs(safeScrBalAfter - safeScrBalBefore, 2 * cashbackInScroll, 1000);
    }

    function test_processCashback_clearsPendingButDoesNotGiveCurrentCashback_whenInsufficientFundsForTotal() public {
        deal(address(scrToken), address(cashbackDispatcher), 0);
        
        uint256 spendAmt = 100e6;
        deal(address(usdcScroll), address(safe), spendAmt);
        
        // owner is pepe, so cashback is 2% -> 2 USDC in scroll tokens
        uint256 cashbackInUsdc = (spendAmt * pepeCashbackPercentage) / HUNDRED_PERCENT_IN_BPS;
        uint256 cashbackInScroll = (cashbackInUsdc * 10 ** IERC20Metadata(address(scrToken)).decimals()) / priceProvider.price(address(scrToken));

        uint256 safePendingCashbackBefore = cashModule.getPendingCashback(address(safe));
        assertEq(safePendingCashbackBefore, 0);

        uint256 safeScrBalBefore = scrToken.balanceOf(address(safe));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmt;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), address(0), spendAmt, address(scrToken), cashbackInScroll, cashbackInUsdc, 0, 0, false);
        cashModule.spend(address(safe), address(0), address(0), txId, spendTokens, spendAmounts, true);

        uint256 safeScrBalAfter = scrToken.balanceOf(address(safe));
        assertEq(safeScrBalAfter, safeScrBalBefore);

        uint256 safePendingCashbackAfter = cashModule.getPendingCashback(address(safe));
        assertEq(safePendingCashbackAfter, cashbackInUsdc);

        deal(address(usdcScroll), address(safe), spendAmt);
        deal(address(scrToken), address(cashbackDispatcher), cashbackInScroll);

        safeScrBalBefore = scrToken.balanceOf(address(safe));

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.PendingCashbackCleared(address(safe), address(scrToken), cashbackInScroll, cashbackInUsdc);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), address(0), spendAmt, address(scrToken), cashbackInScroll, cashbackInUsdc, 0, 0, false);
        cashModule.spend(address(safe), address(0), address(0), keccak256("newTxId"), spendTokens, spendAmounts, true);

        safePendingCashbackAfter = cashModule.getPendingCashback(address(safe));
        assertEq(safePendingCashbackAfter, cashbackInUsdc);

        safeScrBalAfter = scrToken.balanceOf(address(safe));
        assertApproxEqAbs(safeScrBalAfter - safeScrBalBefore, cashbackInScroll, 1000);
    }

    function test_setPriceProvider_succeeds_whenCalledByOwner() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit CashbackDispatcher.PriceProviderSet(address(priceProvider), address(priceProvider));
        cashbackDispatcher.setPriceProvider(address(priceProvider));
    }

    function test_setPriceProvider_reverts_whenAddressZero() public {
        vm.prank(owner);
        vm.expectRevert(CashbackDispatcher.InvalidValue.selector);
        cashbackDispatcher.setPriceProvider(address(0));
    }

    function test_setPriceProvider_reverts_whenCallerNotOwner() public {
        vm.startPrank(notOwner);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        cashbackDispatcher.setPriceProvider(address(priceProvider));
        vm.stopPrank();
    }

    function test_setCashbackToken_succeeds_whenCalledByOwner() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit CashbackDispatcher.CashbackTokenSet(address(scrToken), address(usdcScroll));
        cashbackDispatcher.setCashbackToken(address(usdcScroll));
    }

    function test_setCashbackToken_reverts_whenAddressZero() public {
        vm.prank(owner);
        vm.expectRevert(CashbackDispatcher.InvalidValue.selector);
        cashbackDispatcher.setCashbackToken(address(0));
    }

    function test_setCashbackToken_reverts_whenCallerNotOwner() public {
        vm.startPrank(notOwner);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        cashbackDispatcher.setCashbackToken(address(usdcScroll));
        vm.stopPrank();
    }

    function test_withdrawFunds_succeeds_withErc20Token() public {
        deal(address(usdcScroll), address(cashbackDispatcher), 1 ether);
        uint256 amount = 100e6;

        uint256 ownerBalBefore = usdcScroll.balanceOf(owner);
        uint256 safeBalBefore = usdcScroll.balanceOf(address(cashbackDispatcher));
        
        vm.prank(owner);
        cashbackDispatcher.withdrawFunds(address(usdcScroll), owner, amount);

        uint256 ownerBalAfter = usdcScroll.balanceOf(owner);
        uint256 safeBalAfter = usdcScroll.balanceOf(address(cashbackDispatcher));

        assertEq(ownerBalAfter - ownerBalBefore, amount);
        assertEq(safeBalBefore - safeBalAfter, amount);

        // withdraw all
        vm.prank(owner);
        cashbackDispatcher.withdrawFunds(address(usdcScroll), owner, 0);

        ownerBalAfter = usdcScroll.balanceOf(owner);
        safeBalAfter = usdcScroll.balanceOf(address(cashbackDispatcher));

        assertEq(ownerBalAfter - ownerBalBefore, safeBalBefore);
        assertEq(safeBalAfter, 0);
    }

    function test_withdrawFunds_succeeds_withNativeToken() public {
        deal(address(cashbackDispatcher), 1 ether);
        uint256 amount = 100e6;

        uint256 ownerBalBefore = owner.balance;
        uint256 safeBalBefore = address(cashbackDispatcher).balance;
        
        vm.prank(owner);
        cashbackDispatcher.withdrawFunds(address(0), owner, amount);

        uint256 ownerBalAfter = owner.balance;
        uint256 safeBalAfter = address(cashbackDispatcher).balance;

        assertEq(ownerBalAfter - ownerBalBefore, amount);
        assertEq(safeBalBefore - safeBalAfter, amount);

        // withdraw all
        vm.prank(owner);
        cashbackDispatcher.withdrawFunds(address(0), owner, 0);

        ownerBalAfter = owner.balance;
        safeBalAfter = address(cashbackDispatcher).balance;

        assertEq(ownerBalAfter - ownerBalBefore, safeBalBefore);
        assertEq(safeBalAfter, 0);
    }

    function test_withdrawFunds_reverts_whenRecipientIsAddressZero() public {
        vm.prank(owner);
        vm.expectRevert(CashbackDispatcher.InvalidValue.selector);
        cashbackDispatcher.withdrawFunds(address(usdcScroll), address(0), 1);
    }

    function test_withdrawFunds_reverts_whenNoBalance() public {
        vm.prank(owner);
        vm.expectRevert(CashbackDispatcher.CannotWithdrawZeroAmount.selector);
        cashbackDispatcher.withdrawFunds(address(usdcScroll), owner, 0);
        
        vm.prank(owner);
        vm.expectRevert(CashbackDispatcher.CannotWithdrawZeroAmount.selector);
        cashbackDispatcher.withdrawFunds(address(0), owner, 0);
    }

    function test_withdrawFunds_reverts_whenInsufficientBalance() public {
        vm.prank(owner);
        vm.expectRevert();
        cashbackDispatcher.withdrawFunds(address(usdcScroll), owner, 1);
        
        vm.prank(owner);
        vm.expectRevert(CashbackDispatcher.WithdrawFundsFailed.selector);
        cashbackDispatcher.withdrawFunds(address(0), owner, 1);
    }

    // Test direct cashback function with invalid parameters
    function test_cashback_reverts_whenNotCalledByCashModule() public {
        vm.expectRevert(CashbackDispatcher.OnlyCashModule.selector);
        cashbackDispatcher.cashback(address(safe), address(0), 100e6, 200, 10000);
    }

    // Test direct cashback function with non-EtherFiSafe address
    function test_cashback_reverts_whenSafeIsNotEtherFiSafe() public {
        address randomAddress = makeAddr("randomAddress");
        
        // Mock the call as if coming from CashModule
        vm.prank(address(cashModule));
        vm.expectRevert(CashbackDispatcher.OnlyEtherFiSafe.selector);
        cashbackDispatcher.cashback(randomAddress, address(0), 100e6, 200, 10000);
    }

    // Test the clearPendingCashback function
    function test_clearPendingCashback_success() public {
        // First create pending cashback by doing a spend with no tokens in the dispatcher
        deal(address(scrToken), address(cashbackDispatcher), 0);
        uint256 spendAmt = 100e6;
        deal(address(usdcScroll), address(safe), spendAmt);
        
        uint256 cashbackPercentage = cashModule.getTierCashbackPercentage(SafeTiers.Pepe);
        uint256 cashbackInUsdc = (spendAmt * cashbackPercentage) / 10000;

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmt;
        
        // Spend to create pending cashback
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), address(0), txId, spendTokens, spendAmounts, true);
        
        // Verify pending cashback exists
        assertEq(cashModule.getPendingCashback(address(safe)), cashbackInUsdc);
        
        // Now add tokens to the dispatcher
        uint256 cashbackInScroll = cashbackDispatcher.convertUsdToCashbackToken(cashbackInUsdc);
        deal(address(scrToken), address(cashbackDispatcher), cashbackInScroll);
        
        // Test clearing the pending cashback directly
        vm.prank(address(cashModule));
        (address token, uint256 amount, bool success) = cashbackDispatcher.clearPendingCashback(address(safe));
        
        // Check results
        assertEq(token, address(scrToken), "Token should be SCR token");
        assertGt(amount, 0, "Amount should be positive");
        assertTrue(success, "Should successfully clear cashback");
        
        // Check balance was transferred to safe
        assertApproxEqAbs(scrToken.balanceOf(address(safe)), cashbackInScroll, 1000, "Safe should receive tokens");
    }

    // Test clearPendingCashback when there's no pending cashback
    function test_clearPendingCashback_noPendingCashback() public {
        // Ensure safe has no pending cashback
        assertEq(cashModule.getPendingCashback(address(safe)), 0);
        
        vm.prank(address(cashModule));
        (address token, uint256 amount, bool success) = cashbackDispatcher.clearPendingCashback(address(safe));
        
        assertEq(token, address(scrToken), "Token should be SCR token");
        assertEq(amount, 0, "Amount should be zero");
        assertTrue(success, "Should return success even with zero amount");
    }

    // Test clearPendingCashback with insufficient tokens
    function test_clearPendingCashback_insufficientTokens() public {
        // First create pending cashback by doing a spend with no tokens in the dispatcher
        deal(address(scrToken), address(cashbackDispatcher), 0);
        uint256 spendAmt = 100e6;
        deal(address(usdcScroll), address(safe), spendAmt);
        
        uint256 cashbackPercentage = cashModule.getTierCashbackPercentage(SafeTiers.Pepe);
        uint256 cashbackInUsdc = (spendAmt * cashbackPercentage) / 10000;

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = spendAmt;
        
        // Spend to create pending cashback
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), address(0), txId, spendTokens, spendAmounts, true);
        
        // Verify pending cashback exists
        assertEq(cashModule.getPendingCashback(address(safe)), cashbackInUsdc);
        
        // Try to clear pending cashback with no tokens in dispatcher
        vm.prank(address(cashModule));
        (address token, uint256 amount, bool success) = cashbackDispatcher.clearPendingCashback(address(safe));
        
        // Check results
        assertEq(token, address(scrToken), "Token should be SCR token");
        assertGt(amount, 0, "Amount should be positive");
        assertFalse(success, "Should fail due to insufficient tokens");
        
        // Verify no tokens were transferred
        assertEq(scrToken.balanceOf(address(safe)), 0, "Safe should not receive tokens");
    }

    // Test clearPendingCashback when called by non-CashModule
    function test_clearPendingCashback_reverts_whenNotCalledByCashModule() public {
        vm.expectRevert(CashbackDispatcher.OnlyCashModule.selector);
        cashbackDispatcher.clearPendingCashback(address(safe));
    }

    // Test clearPendingCashback with address(0)
    function test_clearPendingCashback_reverts_withInvalidInput() public {
        vm.prank(address(cashModule));
        vm.expectRevert(CashbackDispatcher.InvalidInput.selector);
        cashbackDispatcher.clearPendingCashback(address(0));
    }

    // Test setCashModule function
    function test_setCashModule_success() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit CashbackDispatcher.CashModuleSet(address(cashModule), newCashModuleAddress);
        cashbackDispatcher.setCashModule(newCashModuleAddress);
        
        // Verify the cashModule address was updated
        assertEq(cashbackDispatcher.cashModule(), newCashModuleAddress);
    }

    // Test setCashModule with zero address
    function test_setCashModule_reverts_withZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(CashbackDispatcher.InvalidValue.selector);
        cashbackDispatcher.setCashModule(address(0));
    }

    // Test setCashModule with unauthorized caller
    function test_setCashModule_reverts_whenCallerNotOwner() public {
        vm.prank(notOwner);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        cashbackDispatcher.setCashModule(newCashModuleAddress);
    }

    // Test withdrawFunds with a contract that rejects ETH transfers
    function test_withdrawFunds_reverts_whenETHTransferIsRejected() public {
        // Fund the cashback dispatcher with ETH
        deal(address(cashbackDispatcher), 1 ether);
        
        // Try to withdraw ETH to a contract that rejects transfers
        vm.prank(owner);
        vm.expectRevert(CashbackDispatcher.WithdrawFundsFailed.selector);
        cashbackDispatcher.withdrawFunds(address(0), address(ethRejecter), 0.5 ether);
    }

    // Test convertUsdToCashbackToken function
    function test_convertUsdToCashbackToken_withZeroAmount() public view {
        uint256 result = cashbackDispatcher.convertUsdToCashbackToken(0);
        assertEq(result, 0, "Should return 0 for 0 input");
    }

    // Test getCashbackAmount function
    function test_getCashbackAmount_calculatesCorrectly() public view {
        uint256 spentAmountInUsd = 1000e6; // 1000 USD
        uint256 cashbackPercentageInBps = 250; // 2.5%
        
        (uint256 tokenAmount, uint256 usdAmount) = cashbackDispatcher.getCashbackAmount(
            cashbackPercentageInBps, 
            spentAmountInUsd
        );
        
        // Expected USD amount is 2.5% of 1000 USD = 25 USD
        assertEq(usdAmount, 25e6, "USD amount should be 25 USD");
        
        // Token amount should match the converted value
        uint256 expectedTokenAmount = cashbackDispatcher.convertUsdToCashbackToken(25e6);
        assertEq(tokenAmount, expectedTokenAmount, "Token amount should match converted value");
    }

    function setTier(SafeTiers tier) internal {
        address[] memory safes = new address[](1);
        safes[0] = address(safe);
        SafeTiers[] memory tiers = new SafeTiers[](1);
        tiers[0] = tier;

        vm.prank(etherFiWallet);
        cashModule.setSafeTier(safes, tiers);
    }

}

// Helper contract to test ETH transfer rejection
contract ETHRejecter {
    // This fallback function will revert when receiving ETH
    receive() external payable {
        revert("ETH transfer rejected");
    }
}
