// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { CashModuleTestSetup } from "../CashModuleTestSetup.t.sol";
import { Mode, SafeTiers, BinSponsor, Cashback, CashbackTokens } from "../../../../../src/interfaces/ICashModule.sol";
import { CashVerificationLib } from "../../../../../src/libraries/CashVerificationLib.sol";
import { CashEventEmitter } from "../../../../../src/modules/cash/CashEventEmitter.sol";
import { CashbackDispatcher } from "../../../../../src/cashback-dispatcher/CashbackDispatcher.sol";
import { MockPriceProvider } from "../../../../../src/mocks/MockPriceProvider.sol";
import { PriceProvider, IAggregatorV3 } from "../../../../../src/oracle/PriceProvider.sol";
import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";
import { IDebtManager } from "../../../../../src/interfaces/IDebtManager.sol";
import { UpgradeableProxy } from "../../../../../src/utils/UpgradeableProxy.sol";
import { EnumerableAddressWhitelistLib } from "../../../../../src/libraries/EnumerableAddressWhitelistLib.sol";

contract CashbackDispatcherTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;

    address newCashModuleAddress = makeAddr("newCashModuleAddress");

    ETHRejecter ethRejecter;

    // Helper function to create single cashback
    function _createSingleCashback(
        address to,
        address token,
        uint256 amountInUsd,
        uint256 cashbackType
    ) private pure returns (Cashback[] memory) {
        CashbackTokens[] memory tokens = new CashbackTokens[](1);
        tokens[0] = CashbackTokens({
            token: token,
            amountInUsd: amountInUsd,
            cashbackType: cashbackType
        });
        
        Cashback[] memory cashbacks = new Cashback[](1);
        cashbacks[0] = Cashback({
            to: to,
            cashbackTokens: tokens
        });
        
        return cashbacks;
    }

    // Helper function to create spend arrays
    function _createSpendArrays(address token, uint256 amount) 
        private 
        pure 
        returns (address[] memory tokens, uint256[] memory amounts) 
    {
        tokens = new address[](1);
        tokens[0] = token;
        amounts = new uint256[](1);
        amounts[0] = amount;
    }

    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);

        ethRejecter = new ETHRejecter();

        vm.stopPrank();
    }

    function test_deploy_initializesCorrectValues() public view {
        address[] memory cashbackTokensInDispatcher = cashbackDispatcher.getCashbackTokens();
        assertEq(address(cashbackDispatcher.etherFiDataProvider()), address(dataProvider));
        assertEq(address(cashbackDispatcher.priceProvider()), address(priceProvider));
        assertEq(cashbackTokensInDispatcher.length, 1);
        assertEq(cashbackTokensInDispatcher[0], address(scrToken));
        assertEq(cashbackDispatcher.cashModule(), address(cashModule));

        assertEq(uint8(cashModule.getSafeTier(address(safe))), uint8(SafeTiers.Pepe));
    }

    function test_processCashback_providesCashback_inDebitFlow() public {
        uint256 spendAmt = 100e6;
        deal(address(usdcScroll), address(safe), 100e6);
        deal(address(scrToken), address(cashbackDispatcher), 100 ether);

        // Use helper to create cashback
        Cashback[] memory cashbacks = _createSingleCashback(
            address(safe),
            address(scrToken),
            1e6,
            0
        );
        
        uint256 cashbackInUsdc = 1e6;
        uint256 cashbackInScroll = cashbackDispatcher.convertUsdToCashbackToken(address(scrToken), cashbackInUsdc);

        uint256 safeScrBalBefore = scrToken.balanceOf(address(safe));
        
        (address[] memory spendTokens, uint256[] memory spendAmounts) = _createSpendArrays(address(usdcScroll), spendAmt);

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), spendAmt, address(safe), address(scrToken), cashbackInScroll, cashbackInUsdc, 0, true);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        uint256 safeScrBalAfter = scrToken.balanceOf(address(safe));
        assertApproxEqAbs(safeScrBalAfter - safeScrBalBefore, cashbackInScroll, 1000);
    }

    function test_processCashback_providesCashback_inCreditFlow() public {
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        uint256 spendAmt = 100e6;
        deal(address(usdcScroll), address(safe), 10000e6);
        deal(address(usdcScroll), address(debtManager), 10000e6);
        deal(address(scrToken), address(cashbackDispatcher), 100 ether);
        
        // Use helper to create cashback
        Cashback[] memory cashbacks = _createSingleCashback(
            address(safe),
            address(scrToken),
            1e6,
            0
        );
        
        uint256 cashbackInUsdc = 1e6;
        uint256 cashbackInScroll = cashbackDispatcher.convertUsdToCashbackToken(address(scrToken), cashbackInUsdc);

        uint256 safeScrBalBefore = scrToken.balanceOf(address(safe));

        (address[] memory spendTokens, uint256[] memory spendAmounts) = _createSpendArrays(address(usdcScroll), spendAmt);

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), spendAmt, address(safe), address(scrToken), cashbackInScroll, cashbackInUsdc, 0, true);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        uint256 safeScrBalAfter = scrToken.balanceOf(address(safe));
        assertApproxEqAbs(safeScrBalAfter - safeScrBalBefore, cashbackInScroll, 1000);
    }

    function test_processCashback_paysPending_whenFundsBecomesAvailable() public {
        deal(address(scrToken), address(cashbackDispatcher), 0);
        uint256 spendAmt = 100e6;
        uint256 cashbackAmountUsd = 1e6;
        deal(address(usdcScroll), address(safe), spendAmt);
        
        // Use helper to create cashback
        Cashback[] memory cashbacks = _createSingleCashback(
            address(safe),
            address(scrToken),
            cashbackAmountUsd,
            0
        );
        
        uint256 cashbackInScroll = cashbackDispatcher.convertUsdToCashbackToken(address(scrToken), cashbackAmountUsd);

        // Check initial state
        assertEq(cashModule.getPendingCashbackForToken(address(safe), address(scrToken)), 0);
        uint256 safeScrBalBefore = scrToken.balanceOf(address(safe));

        (address[] memory spendTokens, uint256[] memory spendAmounts) = _createSpendArrays(address(usdcScroll), spendAmt);

        // First spend - creates pending cashback
        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), spendAmt, address(safe), address(scrToken), cashbackInScroll, cashbackAmountUsd, 0, false);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        // Verify pending cashback
        assertEq(scrToken.balanceOf(address(safe)), safeScrBalBefore);
        assertEq(cashModule.getPendingCashbackForToken(address(safe), address(scrToken)), cashbackAmountUsd);

        // Add funds for second spend
        deal(address(usdcScroll), address(safe), spendAmt);
        deal(address(scrToken), address(cashbackDispatcher), 1000 ether);

        safeScrBalBefore = scrToken.balanceOf(address(safe));

        // Second spend - should clear pending and give new cashback
        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.PendingCashbackCleared(address(safe), address(scrToken), cashbackInScroll, cashbackAmountUsd);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), spendAmt, address(safe), address(scrToken), cashbackInScroll, cashbackAmountUsd, 0, true);
        
        // Create new arrays to avoid stack issues
        (address[] memory spendTokens2, uint256[] memory spendAmounts2) = _createSpendArrays(address(usdcScroll), spendAmt);
        cashModule.spend(address(safe), keccak256("newTxId"), BinSponsor.Reap, spendTokens2, spendAmounts2, cashbacks);

        // Verify results
        assertEq(cashModule.getPendingCashbackForToken(address(safe), address(scrToken)), 0);
        assertApproxEqAbs(scrToken.balanceOf(address(safe)) - safeScrBalBefore, 2 * cashbackInScroll, 1000);
    }

    function test_processCashback_clearsPendingButDoesNotGiveCurrentCashback_whenInsufficientFundsForTotal() public {
        deal(address(scrToken), address(cashbackDispatcher), 0);
        
        uint256 spendAmt = 100e6;
        uint256 cashbackAmountUsd = 1e6;
        deal(address(usdcScroll), address(safe), spendAmt);
        
        // Use helper to create cashback
        Cashback[] memory cashbacks = _createSingleCashback(
            address(safe),
            address(scrToken),
            cashbackAmountUsd,
            0
        );
        
        uint256 cashbackInScroll = cashbackDispatcher.convertUsdToCashbackToken(address(scrToken), cashbackAmountUsd);

        assertEq(cashModule.getPendingCashbackForToken(address(safe), address(scrToken)), 0);
        uint256 safeScrBalBefore = scrToken.balanceOf(address(safe));

        (address[] memory spendTokens, uint256[] memory spendAmounts) = _createSpendArrays(address(usdcScroll), spendAmt);

        // First spend - creates pending
        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), spendAmt, address(safe), address(scrToken), cashbackInScroll, cashbackAmountUsd, 0, false);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        assertEq(scrToken.balanceOf(address(safe)), safeScrBalBefore);
        assertEq(cashModule.getPendingCashbackForToken(address(safe), address(scrToken)), cashbackAmountUsd);

        // Add funds for only one cashback
        deal(address(usdcScroll), address(safe), spendAmt);
        deal(address(scrToken), address(cashbackDispatcher), cashbackInScroll);

        safeScrBalBefore = scrToken.balanceOf(address(safe));

        // Second spend - should clear pending but not give new cashback
        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.PendingCashbackCleared(address(safe), address(scrToken), cashbackInScroll, cashbackAmountUsd);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Cashback(address(safe), spendAmt, address(safe), address(scrToken), cashbackInScroll, cashbackAmountUsd, 0, false);
        
        (address[] memory spendTokens2, uint256[] memory spendAmounts2) = _createSpendArrays(address(usdcScroll), spendAmt);
        cashModule.spend(address(safe), keccak256("newTxId"), BinSponsor.Reap, spendTokens2, spendAmounts2, cashbacks);

        assertEq(cashModule.getPendingCashbackForToken(address(safe), address(scrToken)), cashbackAmountUsd);
        assertApproxEqAbs(scrToken.balanceOf(address(safe)) - safeScrBalBefore, cashbackInScroll, 1000);
    }

    // Rest of the test functions remain the same...
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

    function test_configureCashbackTokens_succeeds_whenCalledByOwner() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdcScroll);
        tokens[1] = address(scrToken);

        bool[] memory shouldWhitelist = new bool[](2);
        shouldWhitelist[0] = false;
        shouldWhitelist[1] = true;

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit CashbackDispatcher.CashbackTokensConfigured(tokens, shouldWhitelist);
        cashbackDispatcher.configureCashbackToken(tokens, shouldWhitelist);
    }

    function test__configureCashbackTokens_reverts_whenAddressZero() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = false;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EnumerableAddressWhitelistLib.InvalidAddress.selector, tokens[0]));
        cashbackDispatcher.configureCashbackToken(tokens, shouldWhitelist);
    }

    function test_configureCashbackTokens_reverts_whenCallerNotOwner() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(scrToken);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = false;

        vm.startPrank(notOwner);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        cashbackDispatcher.configureCashbackToken(tokens, shouldWhitelist);
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

    function test_cashback_reverts_whenNotCalledByCashModule() public {
        vm.expectRevert(CashbackDispatcher.OnlyCashModule.selector);
        cashbackDispatcher.cashback(address(safe), address(scrToken), 100e6);
    }

    function test_clearPendingCashback_success() public {
        // Setup
        deal(address(scrToken), address(cashbackDispatcher), 0);
        uint256 spendAmt = 100e6;
        uint256 cashbackAmountUsd = 1e6;
        deal(address(usdcScroll), address(safe), spendAmt);

        // Create cashback using helper
        Cashback[] memory cashbacks = _createSingleCashback(
            address(safe),
            address(scrToken),
            cashbackAmountUsd,
            0
        );
        
        (address[] memory spendTokens, uint256[] memory spendAmounts) = _createSpendArrays(address(usdcScroll), spendAmt);
        
        // Spend to create pending cashback
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
        
        // Verify pending cashback exists
        assertEq(cashModule.getPendingCashbackForToken(address(safe), address(scrToken)), cashbackAmountUsd);
        
        // Now add tokens to the dispatcher
        uint256 cashbackInScroll = cashbackDispatcher.convertUsdToCashbackToken(address(scrToken), cashbackAmountUsd);
        deal(address(scrToken), address(cashbackDispatcher), cashbackInScroll);
        
        // Test clearing the pending cashback directly
        vm.prank(address(cashModule));
        (uint256 amount, bool success) = cashbackDispatcher.clearPendingCashback(address(safe), address(scrToken), cashbackAmountUsd);
        
        // Check results
        assertGt(amount, 0, "Amount should be positive");
        assertTrue(success, "Should successfully clear cashback");
        
        // Check balance was transferred to safe
        assertApproxEqAbs(scrToken.balanceOf(address(safe)), cashbackInScroll, 1000, "Safe should receive tokens");
    }

    function test_clearPendingCashback_noPendingCashback() public {
        assertEq(cashModule.getPendingCashbackForToken(address(safe), address(scrToken)), 0);
        
        vm.prank(address(cashModule));
        (uint256 amount, bool success) = cashbackDispatcher.clearPendingCashback(address(safe), address(scrToken), 0);
        
        assertEq(amount, 0, "Amount should be zero");
        assertTrue(success, "Should return success even with zero amount");
    }
            
    function test_clearPendingCashback_reverts_whenInvalidCashbackToken() public {
        vm.prank(address(cashModule));
        vm.expectRevert(CashbackDispatcher.InvalidCashbackToken.selector);
        cashbackDispatcher.clearPendingCashback(address(safe), address(weETHScroll), 1 ether);
    }

    function test_clearPendingCashback_insufficientTokens() public {
        deal(address(scrToken), address(cashbackDispatcher), 0);

        vm.prank(address(cashModule));
        (uint256 amount, bool success) = cashbackDispatcher.clearPendingCashback(address(safe), address(scrToken), 100e6);
        
        assertGt(amount, 0, "Amount should be positive");
        assertFalse(success, "Should fail due to insufficient tokens");
        
        assertEq(scrToken.balanceOf(address(safe)), 0, "Safe should not receive tokens");
    }

    function test_clearPendingCashback_reverts_whenNotCalledByCashModule() public {
        vm.expectRevert(CashbackDispatcher.OnlyCashModule.selector);
        cashbackDispatcher.clearPendingCashback(address(safe), address(scrToken), 100e6);
    }

    function test_clearPendingCashback_reverts_withInvalidInput() public {
        vm.prank(address(cashModule));
        vm.expectRevert(CashbackDispatcher.InvalidInput.selector);
        cashbackDispatcher.clearPendingCashback(address(0), address(scrToken), 100e6);
    }

    function test_setCashModule_success() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit CashbackDispatcher.CashModuleSet(address(cashModule), newCashModuleAddress);
        cashbackDispatcher.setCashModule(newCashModuleAddress);
        
        assertEq(cashbackDispatcher.cashModule(), newCashModuleAddress);
    }

    function test_setCashModule_reverts_withZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(CashbackDispatcher.InvalidValue.selector);
        cashbackDispatcher.setCashModule(address(0));
    }

    function test_setCashModule_reverts_whenCallerNotOwner() public {
        vm.prank(notOwner);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        cashbackDispatcher.setCashModule(newCashModuleAddress);
    }

    function test_withdrawFunds_reverts_whenETHTransferIsRejected() public {
        deal(address(cashbackDispatcher), 1 ether);
        
        vm.prank(owner);
        vm.expectRevert(CashbackDispatcher.WithdrawFundsFailed.selector);
        cashbackDispatcher.withdrawFunds(address(0), address(ethRejecter), 0.5 ether);
    }

    function test_convertUsdToCashbackToken_withZeroAmount() public view {
        uint256 result = cashbackDispatcher.convertUsdToCashbackToken(address(scrToken), 0);
        assertEq(result, 0, "Should return 0 for 0 input");
    }
}

// Helper contract to test ETH transfer rejection
contract ETHRejecter {
    receive() external payable {
        revert("ETH transfer rejected");
    }
}