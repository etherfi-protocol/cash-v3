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

    /// @notice Sets the gateway account aggregate, deriving availableBorrowsUsd = collateralUsd x ltv - debtUsd (floored at 0). CashLens does not read healthFactor.
    function _setGatewayAccount(uint256 collateralUsd, uint256 debtUsd, uint256 ltv) internal {
        uint256 maxBorrowUsd = (collateralUsd * ltv) / HUNDRED_PERCENT;
        gateway.setAccountData(address(safe), IGateway.AccountData({ collateralUsd: collateralUsd, debtUsd: debtUsd, availableBorrowsUsd: maxBorrowUsd > debtUsd ? maxBorrowUsd - debtUsd : 0, healthFactor: 1e18 }));
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

        _setGatewayAccount(suppliedUsdc + suppliedLiquid, debtUsd, ltvValue);
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
        _setGatewayAccount(1000e6, 400e6, 50e18);

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

    /// maxBorrow stays gross (collateral x LTV, debt not subtracted) like DebtManager, while creditMaxSpend is the net headroom.
    function test_getSafeCashData_maxBorrowIsGrossWithDebt() public {
        // $2000 USDC collateral at 50% LTV with $800 debt: gross borrow power $1000, net headroom $200.
        _setDebtPosition(2000e6, 0, 50e18, 800e6);

        address[] memory emptyPreference = new address[](0);
        SafeCashData memory data = cashLens.getSafeCashData(address(safe), emptyPreference);

        assertEq(data.totalBorrow, 800e6, "totalBorrow is the debt");
        assertEq(data.maxBorrow, 1000e6, "maxBorrow is gross collateral x LTV, debt not subtracted");
        assertEq(data.creditMaxSpend, 200e6, "creditMaxSpend is the net headroom");
        assertEq(data.maxBorrow, data.totalBorrow + data.creditMaxSpend, "gross == debt + net headroom");
        assertGt(data.maxBorrow, data.creditMaxSpend, "gross exceeds net once there is debt");
    }

    /// A pending withdrawal on one token reduces another token's debit spendable: once it leaves Aave, the gateway reports less shared borrowing power.
    function test_getMaxSpendDebit_pendingWithdrawalReducesOtherTokenHeadroom() public {
        // Debt position: USDC + liquidUSD supplied at 50% LTV with $600 headroom; liquidUSD has raw balance for the request.
        deal(address(usdc), address(safe), 0);
        deal(address(liquidUsd), address(safe), 2000e6);
        gateway.setSuppliedOf(address(safe), address(usdc), 1000e6);
        gateway.setSuppliedOf(address(safe), address(liquidUsd), 1000e6);
        gateway.setAvailableCash(address(usdc), type(uint128).max);
        gateway.setLtv(address(usdc), 50e18);
        gateway.setLtv(address(liquidUsd), 50e18);
        _setGatewayAccount(2000e6, 400e6, 50e18);

        address[] memory tokenPreference = new address[](1);
        tokenPreference[0] = address(usdc);

        uint256 withoutPending = cashLens.getMaxSpendDebit(address(safe), tokenPreference).spendableAmounts[0];
        assertEq(withoutPending, 1000e6, "USDC spendable capped by its supply, headroom ample");

        // Queue a $1000 liquidUSD withdrawal. It is pulled from Aave, so the gateway now holds $1000 less liquidUSD and $500 less borrowing power.
        address[] memory wTokens = new address[](1);
        wTokens[0] = address(liquidUsd);
        uint256[] memory wAmounts = new uint256[](1);
        wAmounts[0] = 1000e6;
        _requestWithdrawal(wTokens, wAmounts, withdrawRecipient);
        gateway.setSuppliedOf(address(safe), address(liquidUsd), 0);
        _setGatewayAccount(1000e6, 400e6, 50e18);

        uint256 withPending = cashLens.getMaxSpendDebit(address(safe), tokenPreference).spendableAmounts[0];
        // Headroom is now $100 -> $100 / 50% = $200 of USDC withdrawable.
        assertEq(withPending, 200e6, "a pending liquidUSD withdrawal lowers USDC's spendable via the shared headroom");
    }

    /// With debt, a same-token pending withdrawal is reserved from the loose balance only: it zeroes the raw portion, while the supplied side stays capped by the borrowing headroom and is untouched by the pending.
    function test_getMaxSpendDebit_sameTokenPendingWithDebtChargesHeadroomOnce() public {
        // $900 is supplied to Aave; the $100 sits loose in the safe as a pending withdrawal, earmarked to leave.
        deal(address(usdc), address(safe), 100e6);
        gateway.setSuppliedOf(address(safe), address(usdc), 900e6);
        gateway.setAvailableCash(address(usdc), type(uint128).max);
        gateway.setLtv(address(usdc), 50e18);
        _setGatewayAccount(900e6, 200e6, 50e18);

        address[] memory wTokens = new address[](1);
        wTokens[0] = address(usdc);
        uint256[] memory wAmounts = new uint256[](1);
        wAmounts[0] = 100e6;
        _requestWithdrawal(wTokens, wAmounts, withdrawRecipient);

        address[] memory tokenPreference = new address[](1);
        tokenPreference[0] = address(usdc);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);
        // Aave allows $250 / 50% = $500 of supplied withdrawal; the raw $100 is fully reserved by the pending, so total is $500.
        assertEq(result.spendableAmounts[0], 500e6, "pending reserved from raw only; supplied side capped by headroom");
    }

    /// Debit canSpend declines (does not revert) when a pending withdrawal exceeds the currently available balance.
    function test_canSpendDebit_pendingExceedsAvailable_declinesNotReverts() public {
        // Queue a withdrawal for the full USDC balance, then drop the raw balance below it with no supplied position,
        // so available (raw + withdrawable) is less than the pending amount.
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = usdcBal;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        deal(address(usdc), address(safe), 100e6);
        gateway.setSuppliedOf(address(safe), address(usdc), 0);

        uint256[] memory amountsInUsd = new uint256[](1);
        amountsInUsd[0] = 1e6;

        (bool ok, string memory reason) = cashLens.canSpend(address(safe), keccak256("p3"), tokens, amountsInUsd);
        assertFalse(ok, "should decline");
        assertEq(reason, "Insufficient effective balance after withdrawal to spend with debit mode", "declines with a reason instead of reverting");
    }

    /// Pending withdrawals reserve raw balance before calculating how much supplied collateral a debit spend consumes.
    function test_canSpendDebit_pendingRawConsumesSuppliedHeadroomForLaterTokens() public {
        // $1,200 collateral at 50% LTV gives $600 max borrow; $500 debt leaves $100 headroom,
        // so only $200 of supplied collateral can be spent across all debit tokens.
        deal(address(usdc), address(safe), 500e6);
        deal(address(liquidUsd), address(safe), 0);

        // The Safe has $500 raw USDC, but $400 of it will be reserved by the pending withdrawal below.
        // That leaves only $100 effective raw USDC for spending.
        //
        // The requested USDC spend is $300, so it must use:
        //   $100 effective raw USDC + $200 supplied USDC withdrawn from Aave.
        //
        // With 50% LTV, withdrawing that $200 supplied USDC consumes all $100 of shared headroom.
        gateway.setSuppliedOf(address(safe), address(usdc), 200e6);
        gateway.setSuppliedOf(address(safe), address(liquidUsd), 1000e6);
        gateway.setAvailableCash(address(usdc), type(uint128).max);
        gateway.setAvailableCash(address(liquidUsd), type(uint128).max);
        gateway.setLtv(address(usdc), 50e18);
        gateway.setLtv(address(liquidUsd), 50e18);
        gateway.setAccountData(address(safe), IGateway.AccountData({ collateralUsd: 1200e6, debtUsd: 500e6, availableBorrowsUsd: 100e6, healthFactor: 144e16 }));

        address[] memory withdrawTokens = new address[](1);
        withdrawTokens[0] = address(usdc);
        uint256[] memory withdrawAmounts = new uint256[](1);
        withdrawAmounts[0] = 400e6;
        _requestWithdrawal(withdrawTokens, withdrawAmounts, withdrawRecipient);

        // The second leg asks for $50 liquidUSD. It should fail because the first USDC leg
        // already consumed the entire shared Aave headroom after accounting for the pending withdrawal.
        address[] memory spendTokens = new address[](2);
        spendTokens[0] = address(usdc);
        spendTokens[1] = address(liquidUsd);
        uint256[] memory amountsInUsd = new uint256[](2);
        amountsInUsd[0] = 300e6;
        amountsInUsd[1] = 50e6;

        (bool ok, string memory reason) = cashLens.canSpend(address(safe), keccak256("pending-headroom"), spendTokens, amountsInUsd);

        assertFalse(ok, "USDC should consume the full shared headroom after reserving its pending withdrawal");
        assertEq(reason, "Insufficient token balance for debit mode spending", "later token should not reuse consumed headroom");
    }

    /// With debt, a zero-LTV reserve cannot back a safe withdrawal, so only the raw balance is spendable.
    function test_getMaxSpendDebit_zeroLtvWithDebt() public {
        deal(address(usdc), address(safe), 300e6);
        gateway.setSuppliedOf(address(safe), address(usdc), 1000e6);
        gateway.setAvailableCash(address(usdc), type(uint128).max);
        gateway.setLtv(address(usdc), 0);
        _setGatewayAccount(1000e6, 200e6, 30e18);

        address[] memory tokenPreference = new address[](1);
        tokenPreference[0] = address(usdc);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), tokenPreference);
        assertEq(result.spendableAmounts[0], 300e6, "Only the raw balance is spendable when LTV is zero and there is debt");
    }
}
