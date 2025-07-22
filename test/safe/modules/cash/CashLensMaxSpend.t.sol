// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

import { Mode, SafeCashData, BinSponsor, SafeData, DebitModeMaxSpend, Cashback, CashbackTokens, CashbackTypes } from "../../../../src/interfaces/ICashModule.sol";
import { IEtherFiSafeFactory } from "../../../../src/interfaces/IEtherFiSafeFactory.sol";
import { CashLens } from "../../../../src/modules/cash/CashLens.sol";
import { IDebtManager } from "../../../../src/interfaces/IDebtManager.sol";
import { CashModuleTestSetup } from "./CashModuleTestSetup.t.sol";
import { SpendingLimit } from "../../../../src/libraries/SpendingLimitLib.sol";
import { PriceProvider, IAggregatorV3 } from "../../../../src/oracle/PriceProvider.sol"; 
import { ILayerZeroTeller, AccountantWithRateProviders } from "../../../../src/interfaces/ILayerZeroTeller.sol";
import { ArrayDeDupLib } from "../../../../src/libraries/ArrayDeDupLib.sol";

contract CashLensMaxSpendTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;

    IERC20 public liquidUsdScroll = IERC20(0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C);
    ILayerZeroTeller public liquidUsdTeller = ILayerZeroTeller(0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387);
    
    uint256 weETHBal = 10 ether;
    uint256 usdcBal = 50000e6;
    uint256 liquidUsdBal = 30000e6;
    uint256 liquidUsdBorrowPower;
    uint256 usdcBorrowPower;
    uint256 weEthBorrowPower;
    uint256 liquidAmtInUsd;

    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);

        // Setup liquidUSD price config
        AccountantWithRateProviders liquidUsdAccountant = liquidUsdTeller.accountant();

        PriceProvider.Config memory liquidUsdConfig = PriceProvider.Config({
            oracle: address(liquidUsdAccountant),
            priceFunctionCalldata: abi.encodeWithSelector(AccountantWithRateProviders.getRate.selector),
            isChainlinkType: false,
            oraclePriceDecimals: liquidUsdAccountant.decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Uint256,
            isBaseTokenEth: false,
            isStableToken: true,
            isBaseTokenBtc: false
        });

        address[] memory tokens = new address[](1);
        tokens[0] = address(liquidUsdScroll);

        PriceProvider.Config[] memory tokensConfig = new PriceProvider.Config[](1);
        tokensConfig[0] = liquidUsdConfig;

        priceProvider.setTokenConfig(tokens, tokensConfig);

        // Setup liquidUSD as collateral and borrow token
        IDebtManager.CollateralTokenConfig[] memory collateralTokenConfig = new IDebtManager.CollateralTokenConfig[](1);
        collateralTokenConfig[0].ltv = ltv;
        collateralTokenConfig[0].liquidationThreshold = liquidationThreshold;
        collateralTokenConfig[0].liquidationBonus = liquidationBonus;

        debtManager.supportCollateralToken(address(liquidUsdScroll), collateralTokenConfig[0]);        

        minShares = uint128(10 * 10 ** IERC20Metadata(address(liquidUsdScroll)).decimals());
        debtManager.supportBorrowToken(address(liquidUsdScroll), borrowApyPerSecond, minShares);

        // Add liquidUSD to withdraw whitelist
        address[] memory withdrawTokens = new address[](1);
        withdrawTokens[0] = address(liquidUsdScroll);
        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;
        cashModule.configureWithdrawAssets(withdrawTokens, whitelist);

        // Add collateral to safe
        deal(address(weETHScroll), address(safe), weETHBal);
        deal(address(usdcScroll), address(safe), usdcBal);
        deal(address(liquidUsdScroll), address(safe), liquidUsdBal); 
        
        // Ensure debt manager has sufficient liquidity
        deal(address(usdcScroll), address(debtManager), 100000e6);
        deal(address(liquidUsdScroll), address(debtManager), 100000e6);

        uint256 weEthInUsd = debtManager.convertCollateralTokenToUsd(address(weETHScroll), weETHBal);
        liquidAmtInUsd = debtManager.convertCollateralTokenToUsd(address(liquidUsdScroll), liquidUsdBal);     
        weEthBorrowPower = (weEthInUsd * ltv) / HUNDRED_PERCENT;
        usdcBorrowPower = (usdcBal * ltv) / HUNDRED_PERCENT;
        liquidUsdBorrowPower = (liquidAmtInUsd * ltv) / HUNDRED_PERCENT;

        vm.stopPrank();
    }

    // ================ getMaxSpendDebit Tests ================

    function test_getMaxSpendDebit_emptyTokenPreference() public view {
        address[] memory emptyPreference = new address[](0);
        
        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), emptyPreference);
        
        assertEq(result.spendableTokens.length, 0, "Should return empty tokens array");
        assertEq(result.spendableAmounts.length, 0, "Should return empty amounts array");
        assertEq(result.amountsInUsd.length, 0, "Should return empty USD amounts array");
        assertEq(result.totalSpendableInUsd, 0, "Should return zero total");
    }

    function test_getMaxSpendDebit_singleToken_USDC_healthyPosition() public view {
        address[] memory tokenPreference = new address[](1);
        tokenPreference[0] = address(usdcScroll);
        
        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);
        
        assertEq(result.spendableTokens.length, 1, "Should return one token");
        assertEq(result.spendableTokens[0], address(usdcScroll), "Token should be USDC");
        assertEq(result.spendableAmounts[0], usdcBal, "Should be able to spend all USDC");
        assertEq(result.amountsInUsd[0], usdcBal, "USD value should match");
        assertEq(result.totalSpendableInUsd, usdcBal, "Total should match USDC value");
    }

    function test_getMaxSpendDebit_singleToken_liquidUSD_healthyPosition() public view {
        address[] memory tokenPreference = new address[](1);
        tokenPreference[0] = address(liquidUsdScroll);
        
        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);
        
        assertEq(result.spendableTokens.length, 1, "Should return one token");
        assertEq(result.spendableTokens[0], address(liquidUsdScroll), "Token should be liquidUSD");
        assertEq(result.spendableAmounts[0], liquidUsdBal, "Should be able to spend all liquidUSD");
        assertApproxEqRel(result.amountsInUsd[0], liquidAmtInUsd, 1, "USD value should match approximately"); // Allow 1% deviation for rate
        assertApproxEqRel(result.totalSpendableInUsd, liquidAmtInUsd, 1, "Total should match liquidUSD value");
    }

    function test_getMaxSpendDebit_bothTokens_healthyPosition() public view {
        address[] memory tokenPreference = new address[](2);
        tokenPreference[0] = address(usdcScroll);
        tokenPreference[1] = address(liquidUsdScroll);
        
        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);
        
        assertEq(result.spendableTokens.length, 2, "Should return two tokens");
        assertEq(result.spendableAmounts[0], usdcBal, "Should be able to spend all USDC");
        assertEq(result.spendableAmounts[1], liquidUsdBal, "Should be able to spend all liquidUSD");
        assertApproxEqRel(result.totalSpendableInUsd, usdcBal + liquidAmtInUsd, 1, "Total should be sum of both");
    }

    function test_getMaxSpendDebit_underwaterPosition_USDCFirst() public {
        // Create debt by borrowing in credit mode
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);
        
        _updateSpendingLimit(1000_000e6, 1000_000e6);
        
        // Borrow large % of collateral value to create underwater position
        uint256 borrowAmount = weEthBorrowPower + usdcBorrowPower - 1e6;
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = borrowAmount;

        Cashback[] memory cashbacks = new Cashback[](1);
        CashbackTokens[] memory cashbackTokens = new CashbackTokens[](1);

        CashbackTokens memory scr = CashbackTokens({
            token: address(scrToken),
            amountInUsd: 1e6,
            cashbackType: CashbackTypes.Regular
        });

        cashbackTokens[0] = scr;

        Cashback memory scrCashback = Cashback({
            to: address(safe),
            cashbackTokens: cashbackTokens
        });

        cashbacks[0] = scrCashback;
        
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
        
        // Switch back to debit mode
        _setMode(Mode.Debit);
        vm.warp(block.timestamp + 1);
        
        // Check max spend with USDC first preference
        address[] memory tokenPreference = new address[](2);
        tokenPreference[0] = address(usdcScroll);
        tokenPreference[1] = address(liquidUsdScroll);
        
        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);
        
        // With debt, USDC should be used first to cover deficit
        assertLt(result.spendableAmounts[0], usdcBal, "USDC spend should be restricted");
        assertEq(result.spendableAmounts[1], liquidUsdBal, "liquidUSD should be fully spendable after USDC covers deficit");
        assertGt(result.totalSpendableInUsd, 0, "Should still be able to spend something");
    }

    function test_getMaxSpendDebit_underwaterPosition_liquidUSDFirst() public {
        // Create debt
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);
        _updateSpendingLimit(1000_000e6, 1000_000e6);
        
        uint256 borrowAmount = weEthBorrowPower + liquidUsdBorrowPower - 1e6;
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = borrowAmount;

        Cashback[] memory cashbacks = new Cashback[](1);
        CashbackTokens[] memory cashbackTokens = new CashbackTokens[](1);

        CashbackTokens memory scr = CashbackTokens({
            token: address(scrToken),
            amountInUsd: 1e6,
            cashbackType: CashbackTypes.Regular
        });

        cashbackTokens[0] = scr;

        Cashback memory scrCashback = Cashback({
            to: address(safe),
            cashbackTokens: cashbackTokens
        });

        cashbacks[0] = scrCashback;
        
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
        
        // Check max spend with liquidUSD first preference
        address[] memory tokenPreference = new address[](2);
        tokenPreference[0] = address(liquidUsdScroll);
        tokenPreference[1] = address(usdcScroll);
        
        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);
        
        // With debt, liquidUSD should be used first to cover deficit
        assertLt(result.spendableAmounts[0], liquidUsdBal, "liquidUSD spend should be restricted");
        assertEq(result.spendableAmounts[1], usdcBal, "USDC should be fully spendable after liquidUSD covers deficit");
        assertGt(result.totalSpendableInUsd, 0, "Should still be able to spend something");
    }

    function test_getMaxSpendDebit_withPendingWithdrawals_USDC() public {
        // Create withdrawal request for USDC
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 20000e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);
        
        address[] memory tokenPreference = new address[](2);
        tokenPreference[0] = address(usdcScroll);
        tokenPreference[1] = address(liquidUsdScroll);
        
        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);
        uint256 effectiveUsdcBal = usdcBal - amounts[0];
        assertEq(result.spendableAmounts[0], effectiveUsdcBal, "USDC should only spend effective balance");
        assertEq(result.spendableAmounts[1], liquidUsdBal, "liquidUSD should be unaffected");
        assertApproxEqRel(result.totalSpendableInUsd, effectiveUsdcBal + liquidAmtInUsd, 1, "Total should reflect reduced USDC");
    }

    function test_getMaxSpendDebit_withPendingWithdrawals_liquidUSD() public {
        // Create withdrawal request for liquidUSD
        address[] memory tokens = new address[](1);
        tokens[0] = address(liquidUsdScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 15000e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);
        
        address[] memory tokenPreference = new address[](2);
        tokenPreference[0] = address(usdcScroll);
        tokenPreference[1] = address(liquidUsdScroll);
        
        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);
        uint256 effectiveLiquidUsdBal = liquidUsdBal - amounts[0];
        uint256 liquidUsdAmtInUsd = debtManager.convertCollateralTokenToUsd(address(liquidUsdScroll), effectiveLiquidUsdBal);

        assertEq(result.spendableAmounts[0], usdcBal, "USDC should be unaffected");
        assertEq(result.spendableAmounts[1], effectiveLiquidUsdBal, "liquidUSD should only spend effective balance");
        assertApproxEqRel(result.totalSpendableInUsd, usdcBal + liquidUsdAmtInUsd, 1, "Total should reflect reduced liquidUSD");
    }

    function test_getMaxSpendDebit_duplicateTokens() public {
        address[] memory tokenPreference = new address[](2);
        tokenPreference[0] = address(usdcScroll);
        tokenPreference[1] = address(usdcScroll);
        
        vm.expectRevert(ArrayDeDupLib.DuplicateElementFound.selector);
        cashLens.getMaxSpendDebit(address(safe), tokenPreference);
    }

    function test_getMaxSpendDebit_notBorrowToken() public {
        address nonBorrowToken = makeAddr("nonBorrowToken");
        
        address[] memory tokenPreference = new address[](1);
        tokenPreference[0] = nonBorrowToken;
        
        vm.expectRevert(CashLens.NotABorrowToken.selector);
        cashLens.getMaxSpendDebit(address(safe), tokenPreference);
    }

    function test_getMaxSpendDebit_cannotCoverDeficit() public {        
        // Create large debt
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);
        
        uint256 borrowAmount = 10000e6;
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = borrowAmount;

        Cashback[] memory cashbacks = new Cashback[](1);
        CashbackTokens[] memory cashbackTokens = new CashbackTokens[](1);

        CashbackTokens memory scr = CashbackTokens({
            token: address(scrToken),
            amountInUsd: 1e6,
            cashbackType: CashbackTypes.Regular
        });

        cashbackTokens[0] = scr;

        Cashback memory scrCashback = Cashback({
            to: address(safe),
            cashbackTokens: cashbackTokens
        });

        cashbacks[0] = scrCashback;
        
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        // Remove most collateral
        deal(address(usdcScroll), address(safe), 500e6);
        deal(address(liquidUsdScroll), address(safe), 500e6);
        deal(address(weETHScroll), address(safe), 0);
        
        // Try to get max spend - should return empty as deficit cannot be covered
        address[] memory tokenPreference = new address[](2);
        tokenPreference[0] = address(usdcScroll);
        tokenPreference[1] = address(liquidUsdScroll);
        
        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);
        
        assertEq(result.spendableTokens.length, 0, "Should return empty when deficit cannot be covered");
        assertEq(result.totalSpendableInUsd, 0, "Total should be zero");
    }

    function test_getMaxSpendDebit_zeroEffectiveBalance() public {
        // Create withdrawal request for all USDC
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50000e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);
        
        address[] memory tokenPreference = new address[](1);
        tokenPreference[0] = address(usdcScroll);
        
        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);
        
        assertEq(result.spendableAmounts[0], 0, "Should have zero spendable with full withdrawal");
        assertEq(result.totalSpendableInUsd, 0, "Total should be zero");
    }

    // ================ Updated getSafeCashData Tests ================

    function test_getSafeCashData_withTokenPreference_USDC_liquidUSD() public view {
        address[] memory tokenPreference = new address[](2);
        tokenPreference[0] = address(usdcScroll);
        tokenPreference[1] = address(liquidUsdScroll);
        
        SafeCashData memory data = cashLens.getSafeCashData(address(safe), tokenPreference);
        
        // Verify debitMaxSpend uses the preference
        assertEq(data.debitMaxSpend.spendableTokens.length, 2, "Should have two tokens in preference order");
        assertEq(data.debitMaxSpend.spendableTokens[0], address(usdcScroll), "First token should be USDC");
        assertEq(data.debitMaxSpend.spendableTokens[1], address(liquidUsdScroll), "Second token should be liquidUSD");
        assertGt(data.debitMaxSpend.totalSpendableInUsd, 0, "Should have spendable amount");
        
        // Verify other data is still populated correctly
        assertGt(data.totalCollateral, 0, "Should have collateral value");
        assertEq(data.totalBorrow, 0, "Should have no borrows initially");
    }

    function test_getSafeCashData_withTokenPreference_liquidUSD_USDC() public view {
        address[] memory tokenPreference = new address[](2);
        tokenPreference[0] = address(liquidUsdScroll);
        tokenPreference[1] = address(usdcScroll);
        
        SafeCashData memory data = cashLens.getSafeCashData(address(safe), tokenPreference);
        
        // Verify debitMaxSpend uses the preference
        assertEq(data.debitMaxSpend.spendableTokens[0], address(liquidUsdScroll), "First token should be liquidUSD");
        assertEq(data.debitMaxSpend.spendableTokens[1], address(usdcScroll), "Second token should be USDC");
    }

    function test_getSafeCashData_emptyTokenPreference() public view {
        address[] memory emptyPreference = new address[](0);
        
        SafeCashData memory data = cashLens.getSafeCashData(address(safe), emptyPreference);
        
        // Should use all borrow tokens when preference is empty
        assertGt(data.debitMaxSpend.spendableTokens.length, 0, "Should have default borrow tokens");
        assertGt(data.debitMaxSpend.totalSpendableInUsd, 0, "Should have spendable amount");
        
        // Check that it includes both USDC and liquidUSD
        bool hasUSDC = false;
        bool hasLiquidUSD = false;
        for (uint i = 0; i < data.debitMaxSpend.spendableTokens.length; i++) {
            if (data.debitMaxSpend.spendableTokens[i] == address(usdcScroll)) hasUSDC = true;
            if (data.debitMaxSpend.spendableTokens[i] == address(liquidUsdScroll)) hasLiquidUSD = true;
        }
        assertTrue(hasUSDC && hasLiquidUSD, "Should include both USDC and liquidUSD");
    }

    function test_getSafeCashData_singleTokenPreference() public view {
        address[] memory tokenPreference = new address[](1);
        tokenPreference[0] = address(liquidUsdScroll);
        
        SafeCashData memory data = cashLens.getSafeCashData(address(safe), tokenPreference);
        
        assertEq(data.debitMaxSpend.spendableTokens.length, 1, "Should have only liquidUSD");
        assertEq(data.debitMaxSpend.spendableTokens[0], address(liquidUsdScroll), "Token should be liquidUSD");
        assertApproxEqRel(data.debitMaxSpend.totalSpendableInUsd, liquidAmtInUsd, 1, "Should match liquidUSD value");
    }

    function test_getSafeCashData_consistencyWithDirectCall() public view {
        address[] memory tokenPreference = new address[](2);
        tokenPreference[0] = address(usdcScroll);
        tokenPreference[1] = address(liquidUsdScroll);
        
        // Get data through getSafeCashData
        SafeCashData memory data = cashLens.getSafeCashData(address(safe), tokenPreference);
        
        // Get data through direct getMaxSpendDebit call
        DebitModeMaxSpend memory directResult = cashLens.getMaxSpendDebit(address(safe), tokenPreference);
        
        // Compare results
        assertEq(data.debitMaxSpend.totalSpendableInUsd, directResult.totalSpendableInUsd, "Total USD should match");
        assertEq(data.debitMaxSpend.spendableTokens.length, directResult.spendableTokens.length, "Token count should match");
        
        for (uint i = 0; i < data.debitMaxSpend.spendableTokens.length; i++) {
            assertEq(data.debitMaxSpend.spendableTokens[i], directResult.spendableTokens[i], "Tokens should match");
            assertEq(data.debitMaxSpend.spendableAmounts[i], directResult.spendableAmounts[i], "Amounts should match");
            assertEq(data.debitMaxSpend.amountsInUsd[i], directResult.amountsInUsd[i], "USD amounts should match");
        }
    }

    // ================ getMaxSpendCredit Tests ================

    function test_getMaxSpendCredit_withUSDC_liquidUSD_collateral() public view {
        uint256 creditMaxSpend = cashLens.getMaxSpendCredit(address(safe));
        
        // Calculate expected based on collateral
        uint256 expectedMaxBorrow = debtManager.getMaxBorrowAmount(address(safe), true);
        
        assertEq(creditMaxSpend, expectedMaxBorrow, "Credit max spend should match max borrow");
        assertGt(creditMaxSpend, 0, "Should have positive credit limit with collateral");
    }
}