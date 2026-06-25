// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { BinSponsor, Cashback, CashbackTokens, DebitModeMaxSpend, Mode, SafeCashData, SafeData } from "../../../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../../../src/interfaces/IDebtManager.sol";
import { IEtherFiSafeFactory } from "../../../../src/interfaces/IEtherFiSafeFactory.sol";
import { IGateway } from "../../../../src/interfaces/IGateway.sol";
import { AccountantWithRateProviders, ILayerZeroTeller } from "../../../../src/interfaces/ILayerZeroTeller.sol";
import { ArrayDeDupLib } from "../../../../src/libraries/ArrayDeDupLib.sol";
import { SpendingLimit } from "../../../../src/libraries/SpendingLimitLib.sol";
import { CashLens } from "../../../../src/modules/cash/CashLens.sol";
import { IAggregatorV3, PriceProvider } from "../../../../src/oracle/PriceProvider.sol";
import { CashModuleTestSetup } from "./CashModuleTestSetup.t.sol";

contract CashLensMaxSpendTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;

    IERC20 public liquidUsd = IERC20(0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C);
    ILayerZeroTeller public liquidUsdTeller = ILayerZeroTeller(0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387);

    uint256 weETHBal = 10 ether;
    uint256 usdcBal = 50_000e6;
    uint256 liquidUsdBal = 30_000e6;
    uint256 liquidUsdBorrowPower;
    uint256 usdcBorrowPower;
    uint256 weEthBorrowPower;
    uint256 liquidAmtInUsd;

    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);

        // Setup liquidUSD price config
        AccountantWithRateProviders liquidUsdAccountant = liquidUsdTeller.accountant();

        PriceProvider.Config memory liquidUsdConfig = PriceProvider.Config({ oracle: address(liquidUsdAccountant), priceFunctionCalldata: abi.encodeWithSelector(AccountantWithRateProviders.getRate.selector), isChainlinkType: false, oraclePriceDecimals: liquidUsdAccountant.decimals(), maxStaleness: 2 days, dataType: PriceProvider.ReturnType.Uint256, isBaseTokenEth: false, isStableToken: true, isBaseTokenBtc: false });

        address[] memory tokens = new address[](1);
        tokens[0] = address(liquidUsd);

        PriceProvider.Config[] memory tokensConfig = new PriceProvider.Config[](1);
        tokensConfig[0] = liquidUsdConfig;

        priceProvider.setTokenConfig(tokens, tokensConfig);

        // Setup liquidUSD as collateral and borrow token
        IDebtManager.CollateralTokenConfig[] memory collateralTokenConfig = new IDebtManager.CollateralTokenConfig[](1);
        collateralTokenConfig[0].ltv = ltv;
        collateralTokenConfig[0].liquidationThreshold = liquidationThreshold;
        collateralTokenConfig[0].liquidationBonus = liquidationBonus;

        debtManager.supportCollateralToken(address(liquidUsd), collateralTokenConfig[0]);

        minShares = uint128(10 * 10 ** IERC20Metadata(address(liquidUsd)).decimals());
        debtManager.supportBorrowToken(address(liquidUsd), borrowApyPerSecond, minShares);

        // Add liquidUSD to withdraw whitelist
        address[] memory withdrawTokens = new address[](1);
        withdrawTokens[0] = address(liquidUsd);
        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;
        cashModule.configureWithdrawAssets(withdrawTokens, whitelist);

        // Add collateral to safe
        deal(address(weETH), address(safe), weETHBal);
        deal(address(usdc), address(safe), usdcBal);
        deal(address(liquidUsd), address(safe), liquidUsdBal);

        // Ensure debt manager has sufficient liquidity
        deal(address(usdc), address(debtManager), 100_000e6);
        deal(address(liquidUsd), address(debtManager), 100_000e6);

        uint256 weEthInUsd = debtManager.convertCollateralTokenToUsd(address(weETH), weETHBal);
        liquidAmtInUsd = debtManager.convertCollateralTokenToUsd(address(liquidUsd), liquidUsdBal);
        weEthBorrowPower = (weEthInUsd * ltv) / HUNDRED_PERCENT;
        usdcBorrowPower = (usdcBal * ltv) / HUNDRED_PERCENT;
        liquidUsdBorrowPower = (liquidAmtInUsd * ltv) / HUNDRED_PERCENT;

        vm.stopPrank();
    }

    // ================ getMaxSpendDebit Tests ================

    /// An empty token preference returns an empty, all-zero result.
    function test_getMaxSpendDebit_emptyTokenPreference() public view {
        address[] memory emptyPreference = new address[](0);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), emptyPreference);

        assertEq(result.spendableTokens.length, 0, "Should return empty tokens array");
        assertEq(result.spendableAmounts.length, 0, "Should return empty amounts array");
        assertEq(result.amountsInUsd.length, 0, "Should return empty USD amounts array");
        assertEq(result.totalSpendableInUsd, 0, "Should return zero total");
    }

    /// No debt: a supplied USDC position is fully spendable.
    function test_getMaxSpendDebit_singleToken_USDC_healthyPosition() public view {
        address[] memory tokenPreference = new address[](1);
        tokenPreference[0] = address(usdc);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);

        assertEq(result.spendableTokens.length, 1, "Should return one token");
        assertEq(result.spendableTokens[0], address(usdc), "Token should be USDC");
        assertEq(result.spendableAmounts[0], usdcBal, "Should be able to spend all USDC");
        assertEq(result.amountsInUsd[0], usdcBal, "USD value should match");
        assertEq(result.totalSpendableInUsd, usdcBal, "Total should match USDC value");
    }

    /// No debt: a supplied liquidUSD position is fully spendable, priced by its rate.
    function test_getMaxSpendDebit_singleToken_liquidUSD_healthyPosition() public view {
        address[] memory tokenPreference = new address[](1);
        tokenPreference[0] = address(liquidUsd);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);

        assertEq(result.spendableTokens.length, 1, "Should return one token");
        assertEq(result.spendableTokens[0], address(liquidUsd), "Token should be liquidUSD");
        assertEq(result.spendableAmounts[0], liquidUsdBal, "Should be able to spend all liquidUSD");
        assertApproxEqRel(result.amountsInUsd[0], liquidAmtInUsd, 1, "USD value should match approximately"); // Allow 1% deviation for rate
        assertApproxEqRel(result.totalSpendableInUsd, liquidAmtInUsd, 1, "Total should match liquidUSD value");
    }

    /// No debt: both supplied stables are fully spendable and sum together.
    function test_getMaxSpendDebit_bothTokens_healthyPosition() public view {
        address[] memory tokenPreference = new address[](2);
        tokenPreference[0] = address(usdc);
        tokenPreference[1] = address(liquidUsd);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);

        assertEq(result.spendableTokens.length, 2, "Should return two tokens");
        assertEq(result.spendableAmounts[0], usdcBal, "Should be able to spend all USDC");
        assertEq(result.spendableAmounts[1], liquidUsdBal, "Should be able to spend all liquidUSD");
        assertApproxEqRel(result.totalSpendableInUsd, usdcBal + liquidAmtInUsd, 1, "Total should be sum of both");
    }

    /// @notice Sets a gateway debt position: both stables supplied with ample reserve cash, a uniform LTV, a debt, and zero raw safe balance. The borrowing headroom is derived as collateral x LTV - debt (stables valued at $1)
    function _setDebtPosition(uint256 suppliedUsdc, uint256 suppliedLiquid, uint256 ltvValue, uint256 debtUsd) internal {
        deal(address(usdc), address(safe), 0);
        deal(address(liquidUsd), address(safe), 0);
        gateway.setSuppliedOf(address(safe), address(usdc), suppliedUsdc);
        gateway.setSuppliedOf(address(safe), address(liquidUsd), suppliedLiquid);
        gateway.setAvailableCash(address(usdc), type(uint128).max);
        gateway.setAvailableCash(address(liquidUsd), type(uint128).max);
        gateway.setLtv(address(usdc), ltvValue);
        gateway.setLtv(address(liquidUsd), ltvValue);

        uint256 collateralUsd = suppliedUsdc + suppliedLiquid;
        uint256 maxBorrowUsd = (collateralUsd * ltvValue) / HUNDRED_PERCENT;
        uint256 availableBorrowsUsd = maxBorrowUsd > debtUsd ? maxBorrowUsd - debtUsd : 0;
        gateway.setAccountData(address(safe), IGateway.AccountData({ collateralUsd: collateralUsd, debtUsd: debtUsd, availableBorrowsUsd: availableBorrowsUsd, healthFactor: 1e18 }));
    }

    /// With debt, USDC first takes the whole borrowing headroom and liquidUSD gets none.
    function test_getMaxSpendDebit_withDebt_USDCFirst() public {
        // With debt, the borrowing headroom caps supplied withdrawal. Supplied $1000 each at 50% LTV,
        // debt $800, so headroom = $2000 x 50% - $800 = $200. Headroom is borrowing power, not collateral:
        // dividing by the 50% LTV, $200 of headroom frees $400 of collateral (withdrawing it lowers borrowing
        // power by exactly $200). USDC is first, so it takes the whole $400 and liquidUSD gets none.
        _setDebtPosition(1000e6, 1000e6, 50e18, 800e6);

        address[] memory tokenPreference = new address[](2);
        tokenPreference[0] = address(usdc);
        tokenPreference[1] = address(liquidUsd);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);
        assertEq(result.spendableAmounts[0], 400e6, "USDC takes the full headroom");
        assertEq(result.spendableAmounts[1], 0, "liquidUSD gets none after the headroom is exhausted");
        assertEq(result.totalSpendableInUsd, 400e6, "Total bounded by the headroom");
    }

    /// Same position, liquidUSD first: order flips which token the headroom goes to.
    function test_getMaxSpendDebit_withDebt_liquidUSDFirst() public {
        _setDebtPosition(1000e6, 1000e6, 50e18, 800e6);

        address[] memory tokenPreference = new address[](2);
        tokenPreference[0] = address(liquidUsd);
        tokenPreference[1] = address(usdc);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);
        // approx, not assertEq: liquidUSD's price is a rate (not 1:1), so the _toUsd/_fromUsd round trip floors a few units short of exact. USDC-first is exact because USDC is 1:1.
        assertApproxEqAbs(result.totalSpendableInUsd, 400e6, 1e6, "debt caps total debit at the $400 the headroom allows");
        assertApproxEqAbs(result.amountsInUsd[1], 0, 1e6, "liquidUSD first leaves USDC no headroom");
    }

    /// A pending USDC withdrawal reduces USDC's spendable; liquidUSD is unaffected.
    function test_getMaxSpendDebit_withPendingWithdrawals_USDC() public {
        // Create withdrawal request for USDC
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 20_000e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        address[] memory tokenPreference = new address[](2);
        tokenPreference[0] = address(usdc);
        tokenPreference[1] = address(liquidUsd);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);
        uint256 effectiveUsdcBal = usdcBal - amounts[0];
        assertEq(result.spendableAmounts[0], effectiveUsdcBal, "USDC should only spend effective balance");
        assertEq(result.spendableAmounts[1], liquidUsdBal, "liquidUSD should be unaffected");
        assertApproxEqRel(result.totalSpendableInUsd, effectiveUsdcBal + liquidAmtInUsd, 1, "Total should reflect reduced USDC");
    }

    /// A pending liquidUSD withdrawal reduces liquidUSD's spendable; USDC is unaffected.
    function test_getMaxSpendDebit_withPendingWithdrawals_liquidUSD() public {
        // Create withdrawal request for liquidUSD
        address[] memory tokens = new address[](1);
        tokens[0] = address(liquidUsd);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 15_000e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        address[] memory tokenPreference = new address[](2);
        tokenPreference[0] = address(usdc);
        tokenPreference[1] = address(liquidUsd);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);
        uint256 effectiveLiquidUsdBal = liquidUsdBal - amounts[0];
        uint256 liquidUsdAmtInUsd = debtManager.convertCollateralTokenToUsd(address(liquidUsd), effectiveLiquidUsdBal);

        assertEq(result.spendableAmounts[0], usdcBal, "USDC should be unaffected");
        assertEq(result.spendableAmounts[1], effectiveLiquidUsdBal, "liquidUSD should only spend effective balance");
        assertApproxEqRel(result.totalSpendableInUsd, usdcBal + liquidUsdAmtInUsd, 1, "Total should reflect reduced liquidUSD");
    }

    /// Duplicate tokens in the preference revert.
    function test_getMaxSpendDebit_duplicateTokens() public {
        address[] memory tokenPreference = new address[](2);
        tokenPreference[0] = address(usdc);
        tokenPreference[1] = address(usdc);

        vm.expectRevert(ArrayDeDupLib.DuplicateElementFound.selector);
        cashLens.getMaxSpendDebit(address(safe), tokenPreference);
    }

    /// A non-borrow token in the preference reverts.
    function test_getMaxSpendDebit_notBorrowToken() public {
        address nonBorrowToken = makeAddr("nonBorrowToken");

        address[] memory tokenPreference = new address[](1);
        tokenPreference[0] = nonBorrowToken;

        vm.expectRevert(CashLens.NotABorrowToken.selector);
        cashLens.getMaxSpendDebit(address(safe), tokenPreference);
    }

    /// Debt at the borrowing limit leaves zero headroom, so nothing supplied is spendable.
    function test_getMaxSpendDebit_cannotCoverDeficit() public {
        // Debt has consumed all borrowing power, so the headroom is zero and no supplied collateral can be
        // withdrawn. With no raw balance, nothing is spendable.
        _setDebtPosition(1000e6, 1000e6, 50e18, 1200e6);

        address[] memory tokenPreference = new address[](2);
        tokenPreference[0] = address(usdc);
        tokenPreference[1] = address(liquidUsd);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);
        assertEq(result.spendableAmounts[0], 0, "No USDC spendable when the headroom is zero");
        assertEq(result.spendableAmounts[1], 0, "No liquidUSD spendable when the headroom is zero");
        assertEq(result.totalSpendableInUsd, 0, "Total should be zero");
    }

    /// Raw safe balance is spendable on top of the headroom-capped supplied amount.
    function test_getMaxSpendDebit_rawBalanceDoesNotConsumeHeadroom() public {
        // Raw safe balance is spendable on top of the headroom-capped supplied amount and does not consume headroom.
        // supplied $1000 USDC at 50% LTV, debt $400, borrow headroom $100 -> $200 supplied withdrawable; plus $500 raw.
        deal(address(usdc), address(safe), 500e6);
        gateway.setSuppliedOf(address(safe), address(usdc), 1000e6);
        gateway.setAvailableCash(address(usdc), type(uint128).max);
        gateway.setLtv(address(usdc), 50e18);
        gateway.setAccountData(address(safe), IGateway.AccountData({ collateralUsd: 1000e6, debtUsd: 400e6, availableBorrowsUsd: 100e6, healthFactor: 1e18 }));

        address[] memory tokenPreference = new address[](1);
        tokenPreference[0] = address(usdc);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);
        assertEq(result.spendableAmounts[0], 700e6, "Raw $500 plus headroom-capped supplied $200");
    }

    /// With debt, supplied withdrawal is capped at the LTV borrowing headroom.
    function test_getMaxSpendDebit_debtCapsAtBorrowHeadroom() public {
        // With debt, the supplied withdrawal is capped by the LTV borrowing headroom (availableBorrowsUsd).
        // Supplied $1000 USDC at 50% LTV, debt $200 -> borrow headroom $300 -> $600 of supplied withdrawable.
        _setDebtPosition(1000e6, 0, 50e18, 200e6);

        address[] memory tokenPreference = new address[](1);
        tokenPreference[0] = address(usdc);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);
        assertEq(result.spendableAmounts[0], 600e6, "Debit capped at the LTV borrowing headroom");
    }

    /// A pending withdrawal of the entire balance leaves nothing spendable.
    function test_getMaxSpendDebit_zeroEffectiveBalance() public {
        // Create withdrawal request for all USDC
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50_000e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        address[] memory tokenPreference = new address[](1);
        tokenPreference[0] = address(usdc);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);

        assertEq(result.spendableAmounts[0], 0, "Should have zero spendable with full withdrawal");
        assertEq(result.totalSpendableInUsd, 0, "Total should be zero");
    }

    // ================ Phase-one supplied-position Tests ================

    /// Scenario 2, no debt and nothing raw: debit spends the withdrawable supplied position.
    function test_getMaxSpendDebit_suppliedOnly_noRawBalance() public {
        deal(address(usdc), address(safe), 0);
        gateway.setSuppliedOf(address(safe), address(usdc), 1000e6);
        gateway.setAvailableCash(address(usdc), type(uint128).max);

        address[] memory tokenPreference = new address[](1);
        tokenPreference[0] = address(usdc);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);
        assertEq(result.spendableAmounts[0], 1000e6, "Should spend the withdrawable supplied amount");
        assertGt(result.totalSpendableInUsd, 0, "Total should be positive");
    }

    /// The withdrawable supplied amount is capped by the reserve's available liquidity.
    function test_getMaxSpendDebit_withdrawableCappedByReserveCash() public {
        deal(address(usdc), address(safe), 0);
        gateway.setSuppliedOf(address(safe), address(usdc), 1000e6);
        gateway.setAvailableCash(address(usdc), 400e6);

        address[] memory tokenPreference = new address[](1);
        tokenPreference[0] = address(usdc);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);
        assertEq(result.spendableAmounts[0], 400e6, "Should cap at reserve liquidity");
    }

    /// Mixed raw balance plus supplied position: debit spends the sum.
    function test_getMaxSpendDebit_rawPlusSupplied() public {
        deal(address(usdc), address(safe), 300e6);
        gateway.setSuppliedOf(address(safe), address(usdc), 700e6);
        gateway.setAvailableCash(address(usdc), type(uint128).max);

        address[] memory tokenPreference = new address[](1);
        tokenPreference[0] = address(usdc);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);
        assertEq(result.spendableAmounts[0], 1000e6, "Should spend raw plus withdrawable supplied");
    }

    // ================ Updated getSafeCashData Tests ================

    /// getSafeCashData honors the token preference order and populates the position fields.
    function test_getSafeCashData_withTokenPreference_USDC_liquidUSD() public {
        address[] memory tokenPreference = new address[](2);
        tokenPreference[0] = address(usdc);
        tokenPreference[1] = address(liquidUsd);

        _mirrorPositionToGateway(address(safe));
        SafeCashData memory data = cashLens.getSafeCashData(address(safe), tokenPreference);

        // Verify debitMaxSpend uses the preference
        assertEq(data.debitMaxSpend.spendableTokens.length, 2, "Should have two tokens in preference order");
        assertEq(data.debitMaxSpend.spendableTokens[0], address(usdc), "First token should be USDC");
        assertEq(data.debitMaxSpend.spendableTokens[1], address(liquidUsd), "Second token should be liquidUSD");
        assertGt(data.debitMaxSpend.totalSpendableInUsd, 0, "Should have spendable amount");

        // Verify other data is still populated correctly
        assertGt(data.totalCollateral, 0, "Should have collateral value");
        assertEq(data.totalBorrow, 0, "Should have no borrows initially");
    }

    /// getSafeCashData reflects a reversed token preference order.
    function test_getSafeCashData_withTokenPreference_liquidUSD_USDC() public view {
        address[] memory tokenPreference = new address[](2);
        tokenPreference[0] = address(liquidUsd);
        tokenPreference[1] = address(usdc);

        SafeCashData memory data = cashLens.getSafeCashData(address(safe), tokenPreference);

        // Verify debitMaxSpend uses the preference
        assertEq(data.debitMaxSpend.spendableTokens[0], address(liquidUsd), "First token should be liquidUSD");
        assertEq(data.debitMaxSpend.spendableTokens[1], address(usdc), "Second token should be USDC");
    }

    /// An empty preference falls back to all borrow tokens.
    function test_getSafeCashData_emptyTokenPreference() public view {
        address[] memory emptyPreference = new address[](0);

        SafeCashData memory data = cashLens.getSafeCashData(address(safe), emptyPreference);

        // Should use all borrow tokens when preference is empty
        assertGt(data.debitMaxSpend.spendableTokens.length, 0, "Should have default borrow tokens");
        assertGt(data.debitMaxSpend.totalSpendableInUsd, 0, "Should have spendable amount");

        // Check that it includes both USDC and liquidUSD
        bool hasUSDC = false;
        bool hasLiquidUSD = false;
        for (uint256 i = 0; i < data.debitMaxSpend.spendableTokens.length; i++) {
            if (data.debitMaxSpend.spendableTokens[i] == address(usdc)) hasUSDC = true;
            if (data.debitMaxSpend.spendableTokens[i] == address(liquidUsd)) hasLiquidUSD = true;
        }
        assertTrue(hasUSDC && hasLiquidUSD, "Should include both USDC and liquidUSD");
    }

    /// A single-token preference returns just that token's spendable.
    function test_getSafeCashData_singleTokenPreference() public view {
        address[] memory tokenPreference = new address[](1);
        tokenPreference[0] = address(liquidUsd);

        SafeCashData memory data = cashLens.getSafeCashData(address(safe), tokenPreference);

        assertEq(data.debitMaxSpend.spendableTokens.length, 1, "Should have only liquidUSD");
        assertEq(data.debitMaxSpend.spendableTokens[0], address(liquidUsd), "Token should be liquidUSD");
        assertApproxEqRel(data.debitMaxSpend.totalSpendableInUsd, liquidAmtInUsd, 1, "Should match liquidUSD value");
    }

    /// debitMaxSpend in getSafeCashData matches a direct getMaxSpendDebit call.
    function test_getSafeCashData_consistencyWithDirectCall() public view {
        address[] memory tokenPreference = new address[](2);
        tokenPreference[0] = address(usdc);
        tokenPreference[1] = address(liquidUsd);

        // Get data through getSafeCashData
        SafeCashData memory data = cashLens.getSafeCashData(address(safe), tokenPreference);

        // Get data through direct getMaxSpendDebit call
        DebitModeMaxSpend memory directResult = cashLens.getMaxSpendDebit(address(safe), tokenPreference);

        // Compare results
        assertEq(data.debitMaxSpend.totalSpendableInUsd, directResult.totalSpendableInUsd, "Total USD should match");
        assertEq(data.debitMaxSpend.spendableTokens.length, directResult.spendableTokens.length, "Token count should match");

        for (uint256 i = 0; i < data.debitMaxSpend.spendableTokens.length; i++) {
            assertEq(data.debitMaxSpend.spendableTokens[i], directResult.spendableTokens[i], "Tokens should match");
            assertEq(data.debitMaxSpend.spendableAmounts[i], directResult.spendableAmounts[i], "Amounts should match");
            assertEq(data.debitMaxSpend.amountsInUsd[i], directResult.amountsInUsd[i], "USD amounts should match");
        }
    }

    // ================ getMaxSpendCredit Tests ================

    /// Credit max spend equals the gateway's borrowing power.
    function test_getMaxSpendCredit_withUSDC_liquidUSD_collateral() public {
        _mirrorPositionToGateway(address(safe));
        uint256 creditMaxSpend = cashLens.getMaxSpendCredit(address(safe));

        // Calculate expected based on collateral
        uint256 expectedMaxBorrow = debtManager.getMaxBorrowAmount(address(safe), true);

        assertEq(creditMaxSpend, expectedMaxBorrow, "Credit max spend should match max borrow");
        assertGt(creditMaxSpend, 0, "Should have positive credit limit with collateral");
    }
}
