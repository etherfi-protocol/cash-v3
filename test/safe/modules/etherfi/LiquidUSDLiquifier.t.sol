// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

import { SafeTestSetup, MessageHashUtils } from "../..//SafeTestSetup.t.sol";
import { LiquidUSDLiquifierModule, IERC20, SafeERC20, ModuleCheckBalance } from "../../../../src/modules/etherfi/LiquidUSDLiquifier.sol";
import { BinSponsor, Cashback, Mode, SpendingLimit } from "../../../../src/interfaces/ICashModule.sol";
import { CashEventEmitter } from "../cash/CashModuleTestSetup.t.sol";
import { CashVerificationLib } from "../../../../src/libraries/CashVerificationLib.sol";
import { IDebtManager } from "../../../../src/interfaces/IDebtManager.sol";
import { PriceProvider } from "../../../../src/oracle/PriceProvider.sol";
import { AccountantWithRateProviders } from "../../../../src/interfaces/ILayerZeroTeller.sol";
import { ILayerZeroTeller } from "../../../../src/interfaces/ILayerZeroTeller.sol";
import { UUPSProxy } from "../../../../src/UUPSProxy.sol";

contract LiquidUSDLiquifierTest is SafeTestSetup {
    using SafeERC20 for IERC20;
    using MessageHashUtils for bytes32;

    LiquidUSDLiquifierModule public liquidUSDLiquifier;

    IERC20 public LIQUID_USD = IERC20(0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C);
    IERC20 public USDC = IERC20(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
    ILayerZeroTeller liquidUsdTeller = ILayerZeroTeller(0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387);

    uint256 initialLiquidUSDBalance = 10000e6;
    uint256 initialUSDCBalance = 10000e6;
    uint256 initialDebtAmount = 100e6;
    uint16 discount = 1;
    uint24 secondsToDeadline = 3 days;

    function setUp() public override {
        super.setUp();

        _setLiquidUsdAsCollateralAndBorrowToken();
        _updateSpendingLimit(10000e6, 10000e6);

        address liquidUsdLiquifierImpl = address(new LiquidUSDLiquifierModule(address(debtManager), address(dataProvider)));
        liquidUSDLiquifier = LiquidUSDLiquifierModule(address(new UUPSProxy(liquidUsdLiquifierImpl, "")));
        liquidUSDLiquifier.initialize(address(roleRegistry));

        address[] memory modules = new address[](1);
        modules[0] = address(liquidUSDLiquifier);
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.prank(owner);
        dataProvider.configureDefaultModules(modules, shouldWhitelist);

        deal(address(LIQUID_USD), address(safe), initialLiquidUSDBalance);
        deal(address(USDC), address(liquidUSDLiquifier), initialUSDCBalance);

        address[] memory tokens = new address[](1);
        tokens[0] = address(USDC);
        uint256[] memory amountsInUsd = new uint256[](1);
        amountsInUsd[0] = initialDebtAmount;
        Cashback[] memory cashbacks = new Cashback[](0);

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), keccak256("txId"), BinSponsor.Reap, tokens, amountsInUsd, cashbacks);
    }

    function test_RepayUsingLiquidUSD() public {
        uint256 liquidUsdAmount = 10e6;
        uint256 usdAmount = debtManager.convertCollateralTokenToUsd(address(LIQUID_USD), liquidUsdAmount);

        uint256 debtBefore = debtManager.borrowingOf(address(safe), address(USDC));

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit LiquidUSDLiquifierModule.RepaidUsingLiquidUSD(address(safe), usdAmount, liquidUsdAmount);
        liquidUSDLiquifier.repayUsingLiquidUSD(address(safe), liquidUsdAmount);

        uint256 debtAfter = debtManager.borrowingOf(address(safe), address(USDC));
        assertEq(debtBefore - debtAfter, usdAmount);
    }

    function test_RepayUsingLiquidUSD_ReturnsExcessFunds() public {
        uint256 usdAmount = initialDebtAmount + 10e6;
        uint256 liquidUsdAmount = debtManager.convertUsdToCollateralToken(address(LIQUID_USD), usdAmount);

        uint256 liquidUsdAmountToRepay = debtManager.convertUsdToCollateralToken(address(LIQUID_USD), initialDebtAmount);

        deal(address(USDC), address(liquidUSDLiquifier), usdAmount);

        uint256 liquidUsdAmountBefore = LIQUID_USD.balanceOf(address(safe));

        vm.prank(etherFiWallet);
        liquidUSDLiquifier.repayUsingLiquidUSD(address(safe), liquidUsdAmount);

        uint256 debtAfter = debtManager.borrowingOf(address(safe), address(USDC));
        uint256 liquidUsdAmountAfter = LIQUID_USD.balanceOf(address(safe));

        assertEq(debtAfter, 0);
        assertApproxEqAbs(liquidUsdAmountAfter, liquidUsdAmountBefore - liquidUsdAmountToRepay, 10);
    }

    function test_RepayUsingLiquidUSD_InsufficientUsdcBalance() public {
        deal(address(USDC), address(liquidUSDLiquifier), 0);
    
        vm.prank(etherFiWallet);
        vm.expectRevert(LiquidUSDLiquifierModule.InsufficientUsdcBalance.selector);
        liquidUSDLiquifier.repayUsingLiquidUSD(address(safe), 10e6);
    }

    function test_RepayUsingLiquidUSD_InsufficientAvailableBalanceOnSafe() public {
        deal(address(LIQUID_USD), address(safe), 0);
    
        vm.prank(etherFiWallet);
        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        liquidUSDLiquifier.repayUsingLiquidUSD(address(safe), 10e6);
    }

    function test_RepayUsingLiquidUSD_OnlyEtherFiWallet() public {
        vm.prank(makeAddr("notEtherFiWallet"));
        vm.expectRevert(LiquidUSDLiquifierModule.OnlyEtherFiWallet.selector);
        liquidUSDLiquifier.repayUsingLiquidUSD(address(safe), 10e6);
    }

    function test_WithdrawLiquidUSD() public {
        uint128 amount = 100e6;
        uint128 minReturn = 100e6;

        deal(address(LIQUID_USD), address(liquidUSDLiquifier), amount);

        uint128 amountOut = liquidUSDLiquifier.LIQUID_USD_BORING_QUEUE().previewAssetsOut(address(usdcScroll), amount, discount);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit LiquidUSDLiquifierModule.LiquidUSDWithdrawalRequested(amount, amountOut);
        liquidUSDLiquifier.withdrawLiquidUSD(amount, minReturn, discount, secondsToDeadline);
    }

    function test_WithdrawLiquidUSD_InsufficientReturnAmount() public {
        uint128 amount = 100e6;
        uint128 minReturn = 1000e6;

        deal(address(LIQUID_USD), address(liquidUSDLiquifier), amount);

        vm.prank(owner);
        vm.expectRevert(LiquidUSDLiquifierModule.InsufficientReturnAmount.selector);
        liquidUSDLiquifier.withdrawLiquidUSD(amount, minReturn, discount, secondsToDeadline);
    }

    function test_WithdrawLiquidUSD_OnlySettlementDispatcherBridger() public {
        vm.prank(makeAddr("notSettlementDispatcherBridger"));
        vm.expectRevert(LiquidUSDLiquifierModule.OnlySettlementDispatcherBridger.selector);
        liquidUSDLiquifier.withdrawLiquidUSD(100e6, 100e6, discount, secondsToDeadline);
    }

    function _updateSpendingLimit(uint256 dailyLimit, uint256 monthlyLimit) internal {
        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.UPDATE_SPENDING_LIMIT_METHOD, block.chainid, address(safe), nonce, abi.encode(dailyLimit, monthlyLimit))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        (, uint64 spendLimitDelay,) = cashModule.getDelays();

        SpendingLimit memory oldLimit = cashLens.applicableSpendingLimit(address(safe));
        SpendingLimit memory newLimit = SpendingLimit({
            dailyLimit: oldLimit.dailyLimit,
            monthlyLimit: oldLimit.monthlyLimit,
            spentToday: oldLimit.spentToday,
            spentThisMonth: oldLimit.spentThisMonth,
            newDailyLimit: oldLimit.newDailyLimit,
            newMonthlyLimit: oldLimit.newMonthlyLimit,
            dailyRenewalTimestamp: oldLimit.dailyRenewalTimestamp,
            monthlyRenewalTimestamp: oldLimit.monthlyRenewalTimestamp,
            dailyLimitChangeActivationTime: oldLimit.dailyLimitChangeActivationTime,
            monthlyLimitChangeActivationTime: oldLimit.monthlyLimitChangeActivationTime,
            timezoneOffset: oldLimit.timezoneOffset
        });

        if (dailyLimit < oldLimit.dailyLimit) {
            newLimit.newDailyLimit = dailyLimit;
            newLimit.dailyLimitChangeActivationTime = uint64(block.timestamp) + spendLimitDelay;
        } else {
            newLimit.dailyLimit = dailyLimit;
            newLimit.newDailyLimit = 0;
            newLimit.dailyLimitChangeActivationTime = 0;
        }

        if (monthlyLimit < newLimit.monthlyLimit) {
            newLimit.newMonthlyLimit = monthlyLimit;
            newLimit.monthlyLimitChangeActivationTime = uint64(block.timestamp) + spendLimitDelay;
        } else {
            newLimit.monthlyLimit = monthlyLimit;
            newLimit.newMonthlyLimit = 0;
            newLimit.monthlyLimitChangeActivationTime = 0;
        }

        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.SpendingLimitChanged(address(safe), oldLimit, newLimit);
        cashModule.updateSpendingLimit(address(safe), dailyLimit, monthlyLimit, owner1, signature);
    }

    function _setLiquidUsdAsCollateralAndBorrowToken() internal {
        vm.startPrank(owner);

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
        tokens[0] = address(LIQUID_USD);

        PriceProvider.Config[] memory tokensConfig = new PriceProvider.Config[](1);
        tokensConfig[0] = liquidUsdConfig;

        priceProvider.setTokenConfig(tokens, tokensConfig);

        IDebtManager.CollateralTokenConfig[] memory collateralTokenConfig = new IDebtManager.CollateralTokenConfig[](1);

        collateralTokenConfig[0].ltv = ltv;
        collateralTokenConfig[0].liquidationThreshold = liquidationThreshold;
        collateralTokenConfig[0].liquidationBonus = liquidationBonus;

        debtManager.supportCollateralToken(address(LIQUID_USD), collateralTokenConfig[0]);        

        minShares = uint128(10 * 10 ** IERC20Metadata(address(LIQUID_USD)).decimals());
        debtManager.supportBorrowToken(address(LIQUID_USD), borrowApyPerSecond, minShares);

        vm.stopPrank();
    }
}