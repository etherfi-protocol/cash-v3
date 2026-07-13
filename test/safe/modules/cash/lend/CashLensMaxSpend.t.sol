// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

import { DebitModeMaxSpend, Mode, SafeCashData } from "../../../../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../../../../src/interfaces/IDebtManager.sol";
import { ILendGateway } from "../../../../../src/interfaces/ILendGateway.sol";
import { ArrayDeDupLib } from "../../../../../src/libraries/ArrayDeDupLib.sol";
import { CashLens } from "../../../../../src/modules/cash/CashLens.sol";
import { IAggregatorV3, PriceProvider } from "../../../../../src/oracle/PriceProvider.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title CashLensMaxSpendAaveTest
 * @notice The gateway-path debit / credit max-spend and getSafeCashData math, built through real Aave supply /
 *         borrow flows against a real Aave v4 instance. Every position (collateral, debt, reserve liquidity, per
 *         reserve LTV) is genuine Aave state, so the headroom threading, reserve-cash caps, and pending-withdrawal
 *         reservation are asserted against numbers Aave actually produces rather than injected aggregates.
 * @dev USDC and liquidUSD are both listed at a 50% collateral factor (matching the legacy ltv = 50e18 these tests
 *      were written against); weETH keeps the base 80%. liquidUSD is priced off the USDC/USD feed so Aave and the
 *      PriceProvider agree at ~$1 (a test simplification; rate-based liquidUSD pricing keeps its own coverage in
 *      LiquidUSDLiquifier.t.sol). Run with:
 *      source .env && FOUNDRY_PROFILE=lend TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path "test/safe/modules/cash/lend/CashLensMaxSpend.t.sol"
 */
contract CashLensMaxSpendAaveTest is CashGatewayTestSetup {
    IERC20 public liquidUsd = IERC20(0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C);
    uint256 internal liquidUsdReserveId;

    /// @dev Stables at 50% collateral factor, matching the legacy ltv = 50e18 the mock-era tests assumed.
    function _usdcCollateralFactorBps() internal pure override returns (uint16) {
        return 5000;
    }

    function setUp() public override {
        super.setUp();

        // liquidUSD priced off the USDC/USD feed (so Aave and PriceProvider agree at ~$1), and listed on the
        // DebtManager as collateral + borrow token: CashLens gates debit tokens on isBorrowToken even for a
        // gateway safe, and getSafeCashData enumerates the DebtManager collateral list.
        vm.startPrank(owner);
        address[] memory tokens = new address[](1);
        tokens[0] = address(liquidUsd);
        PriceProvider.Config[] memory tokensConfig = new PriceProvider.Config[](1);
        tokensConfig[0] = PriceProvider.Config({ oracle: usdcUsdOracle, priceFunctionCalldata: hex"", isChainlinkType: true, oraclePriceDecimals: IAggregatorV3(usdcUsdOracle).decimals(), maxStaleness: type(uint24).max, dataType: PriceProvider.ReturnType.Int256, isBaseTokenEth: false, isStableToken: true, isBaseTokenBtc: false });
        priceProvider.setTokenConfig(tokens, tokensConfig);

        IDebtManager.CollateralTokenConfig memory collateralConfig;
        collateralConfig.ltv = ltv;
        collateralConfig.liquidationThreshold = liquidationThreshold;
        collateralConfig.liquidationBonus = liquidationBonus;
        debtManager.supportCollateralToken(address(liquidUsd), collateralConfig);
        debtManager.supportBorrowToken(address(liquidUsd), borrowApyPerSecond, uint128(10 * 10 ** IERC20Metadata(address(liquidUsd)).decimals()));

        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;
        cashModule.configureWithdrawAssets(tokens, whitelist);
        vm.stopPrank();

        // liquidUSD Aave reserve at 50% collateral factor, priced by the USDC/USD feed; seed borrowable liquidity.
        liquidUsdReserveId = _addAaveReserve(address(liquidUsd), usdcUsdOracle, 5000, true);
        vm.prank(owner);
        gw.setReserveId(address(liquidUsd), liquidUsdReserveId);
        _seedAaveLiquidity(liquidUsdReserveId, address(liquidUsd), 1_000_000e6);
    }

    // ================ getMaxSpendDebit: validation + raw balance ================

    /// An empty token preference returns an empty, all-zero result.
    function test_debit_emptyPreference_returnsEmpty() public view {
        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), new address[](0));
        assertEq(result.spendableTokens.length, 0);
        assertEq(result.spendableAmounts.length, 0);
        assertEq(result.amountsInUsd.length, 0);
        assertEq(result.totalSpendableInUsd, 0);
    }

    /// Duplicate tokens in the preference revert.
    function test_debit_duplicateTokens_reverts() public {
        address[] memory pref = new address[](2);
        pref[0] = address(usdc);
        pref[1] = address(usdc);
        vm.expectRevert(ArrayDeDupLib.DuplicateElementFound.selector);
        cashLens.getMaxSpendDebit(address(safe), pref);
    }

    /// A non-borrow token in the preference reverts.
    function test_debit_notBorrowToken_reverts() public {
        address[] memory pref = new address[](1);
        pref[0] = makeAddr("nonBorrowToken");
        vm.expectRevert(CashLens.NotABorrowToken.selector);
        cashLens.getMaxSpendDebit(address(safe), pref);
    }

    /// No supplied position and no debt: the raw safe balance of each stable is fully spendable and sums together.
    function test_debit_rawBalances_fullySpendableAndSum() public {
        deal(address(usdc), address(safe), 5000e6);
        deal(address(liquidUsd), address(safe), 3000e6);

        address[] memory pref = new address[](2);
        pref[0] = address(usdc);
        pref[1] = address(liquidUsd);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), pref);
        assertEq(result.spendableAmounts[0], 5000e6, "all raw USDC spendable");
        assertEq(result.spendableAmounts[1], 3000e6, "all raw liquidUSD spendable");
        assertApproxEqAbs(result.totalSpendableInUsd, 8000e6, 2, "total is the sum of both");
    }

    // ================ getMaxSpendDebit: supplied position, no debt ================

    /// No debt: the supplied position is withdrawable and fully spendable.
    function test_debit_suppliedNoDebt_spendsWithdrawable() public {
        _supplyToGateway(address(safe), address(usdc), 1000e6);
        deal(address(usdc), address(safe), 0);

        address[] memory pref = new address[](1);
        pref[0] = address(usdc);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), pref);
        assertApproxEqAbs(result.spendableAmounts[0], 1000e6, 2, "withdrawable supplied amount is spendable");
    }

    /// The withdrawable supplied amount is capped by the reserve's available liquidity.
    function test_debit_suppliedCappedByReserveCash() public {
        _supplyToGateway(address(safe), address(usdc), 1000e6);
        deal(address(usdc), address(safe), 0);

        // A genuinely drained reserve on real Aave needs an unrelated whale borrow; mock the reserve read to
        // isolate the liquidity cap (the branch under test).
        vm.mockCall(address(gw), abi.encodeWithSelector(ILendGateway.availableCash.selector, address(usdc)), abi.encode(uint256(400e6)));

        address[] memory pref = new address[](1);
        pref[0] = address(usdc);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), pref);
        assertEq(result.spendableAmounts[0], 400e6, "capped at reserve liquidity");
    }

    /// Raw balance plus supplied position, no debt: debit spends the sum.
    function test_debit_rawPlusSupplied_sum() public {
        _supplyToGateway(address(safe), address(usdc), 700e6);
        deal(address(usdc), address(safe), 300e6);

        address[] memory pref = new address[](1);
        pref[0] = address(usdc);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), pref);
        assertApproxEqAbs(result.spendableAmounts[0], 1000e6, 2, "raw 300 plus withdrawable supplied 700");
    }

    // ================ getMaxSpendDebit: supplied + debt (headroom threading) ================

    /// With debt, the first token takes the whole borrowing headroom and the second gets none.
    function test_debit_withDebt_headroomThreaded_usdcFirst() public {
        // 1000 USDC + 1000 liquidUSD supplied at 50%, 800 USDC borrowed: headroom $200. Dividing by the 50% LTV,
        // $200 of headroom frees $400 of collateral. USDC is first, so it takes the whole $400.
        _buildDebtPosition(1000e6, 1000e6, 800e6);

        address[] memory pref = new address[](2);
        pref[0] = address(usdc);
        pref[1] = address(liquidUsd);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), pref);
        assertApproxEqAbs(result.spendableAmounts[0], 400e6, 1e4, "USDC takes the full headroom");
        assertEq(result.spendableAmounts[1], 0, "liquidUSD gets none after the headroom is exhausted");
        assertApproxEqAbs(result.totalSpendableInUsd, 400e6, 1e4, "total bounded by the headroom");
    }

    /// Same position, liquidUSD first: order flips which token the headroom goes to.
    function test_debit_withDebt_headroomThreaded_liquidFirst() public {
        _buildDebtPosition(1000e6, 1000e6, 800e6);

        address[] memory pref = new address[](2);
        pref[0] = address(liquidUsd);
        pref[1] = address(usdc);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), pref);
        assertApproxEqAbs(result.spendableAmounts[0], 400e6, 1e4, "liquidUSD takes the full headroom");
        assertEq(result.spendableAmounts[1], 0, "USDC gets none after the headroom is exhausted");
    }

    /// With debt below the borrowing limit, the supplied withdrawal is capped at the LTV borrowing headroom.
    function test_debit_debtCapsAtBorrowHeadroom() public {
        // 1000 USDC supplied at 50%, 200 borrowed: headroom $300, so $600 of supplied is withdrawable.
        _buildDebtPosition(1000e6, 0, 200e6);
        deal(address(usdc), address(safe), 0);

        address[] memory pref = new address[](1);
        pref[0] = address(usdc);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), pref);
        assertApproxEqAbs(result.spendableAmounts[0], 600e6, 1e4, "debit capped at the LTV borrowing headroom");
    }

    /// Debt at the borrowing limit leaves zero headroom, so nothing supplied is spendable.
    function test_debit_debtAtLimit_nothingSpendable() public {
        // 1000 USDC + 1000 liquidUSD at 50% gives $1000 of power; borrowing it all leaves zero headroom.
        _buildDebtPosition(1000e6, 1000e6, 1000e6);
        deal(address(usdc), address(safe), 0);
        deal(address(liquidUsd), address(safe), 0);

        address[] memory pref = new address[](2);
        pref[0] = address(usdc);
        pref[1] = address(liquidUsd);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), pref);
        assertEq(result.spendableAmounts[0], 0, "no USDC spendable when the headroom is zero");
        assertEq(result.spendableAmounts[1], 0, "no liquidUSD spendable when the headroom is zero");
        assertEq(result.totalSpendableInUsd, 0, "total is zero");
    }

    /// Raw safe balance is spendable on top of the headroom-capped supplied amount and does not consume headroom.
    function test_debit_rawDoesNotConsumeHeadroom() public {
        // 1000 USDC supplied at 50%, 400 borrowed: headroom $100 -> $200 supplied withdrawable; plus $500 raw.
        _buildDebtPosition(1000e6, 0, 400e6);
        deal(address(usdc), address(safe), 500e6);

        address[] memory pref = new address[](1);
        pref[0] = address(usdc);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), pref);
        assertApproxEqAbs(result.spendableAmounts[0], 700e6, 1e4, "raw $500 plus headroom-capped supplied $200");
    }

    /// Each token consumes the shared headroom at its OWN LTV: USDC (80%) is face-bound, and the headroom it leaves caps liquidUSD (50%) at liquidUSD's own rate.
    function test_debit_mixedLtv_perTokenThreading() public {
        // 200 USDC @ 80% + 2000 liquidUSD @ 50% supplied, 700 borrowed. Headroom $460. USDC first is face-bound at
        // its 200 supply and bills 200 x 80% = $160, leaving $300. liquidUSD is then headroom-bound: $300 / 50% =
        // $600 of face. A bug reusing one LTV for both would give $375 or $720, so pinning $600 catches it.
        _setAaveCollateralFactor(address(usdc), 8000);
        _supplyToGateway(address(safe), address(usdc), 200e6);
        _supplyToGateway(address(safe), address(liquidUsd), 2000e6);
        _borrowOnGateway(address(safe), address(usdc), 700e6, recipient);
        deal(address(usdc), address(safe), 0);
        deal(address(liquidUsd), address(safe), 0);

        address[] memory pref = new address[](2);
        pref[0] = address(usdc);
        pref[1] = address(liquidUsd);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), pref);
        assertEq(result.spendableAmounts[0], 200e6, "USDC is face-bound at its 200 supply");
        assertApproxEqAbs(result.spendableAmounts[1], 600e6, 1e4, "liquidUSD is headroom-bound at its own 50% LTV, not USDC's 80%");
    }

    /// With debt, a zero-LTV reserve cannot back a withdrawal, so only the raw balance of that reserve is spendable.
    function test_debit_zeroLtvReserveWithDebt_onlyRaw() public {
        // 1000 USDC supplied at 50% with 200 borrowed, so the safe carries debt. Aave rejects a 0 collateral factor,
        // so the zero-LTV branch (defensive code, unreachable on real Aave) is exercised by mocking gw.ltv.
        _buildDebtPosition(1000e6, 0, 200e6);
        deal(address(usdc), address(safe), 300e6);
        vm.mockCall(address(gw), abi.encodeWithSelector(ILendGateway.ltv.selector, address(usdc)), abi.encode(uint256(0)));

        address[] memory pref = new address[](1);
        pref[0] = address(usdc);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), pref);
        assertEq(result.spendableAmounts[0], 300e6, "only the raw balance is spendable when LTV is zero and there is debt");
    }

    // ================ getMaxSpendDebit: pending withdrawals ================

    /// No debt: a pending withdrawal reduces its own token's spendable and leaves the other unaffected.
    function test_debit_pendingReducesOwnToken_noDebt() public {
        deal(address(usdc), address(safe), 5000e6);
        deal(address(liquidUsd), address(safe), 3000e6);

        address[] memory wTokens = new address[](1);
        wTokens[0] = address(usdc);
        uint256[] memory wAmounts = new uint256[](1);
        wAmounts[0] = 2000e6;
        _requestWithdrawal(wTokens, wAmounts, withdrawRecipient);

        address[] memory pref = new address[](2);
        pref[0] = address(usdc);
        pref[1] = address(liquidUsd);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), pref);
        assertEq(result.spendableAmounts[0], 3000e6, "USDC spendable reduced by the pending withdrawal");
        assertEq(result.spendableAmounts[1], 3000e6, "liquidUSD unaffected");
    }

    /// With debt, a same-token pending withdrawal is reserved from the loose balance only; the supplied side stays capped by the headroom.
    function test_debit_sameTokenPending_reservesRawOnly() public {
        // 900 USDC supplied at 50%, 200 borrowed: headroom $250 -> $500 supplied withdrawable. $100 sits loose with
        // a pending withdrawal earmarking it to leave, so the raw side contributes nothing.
        _buildDebtPosition(900e6, 0, 200e6);
        deal(address(usdc), address(safe), 100e6);

        address[] memory wTokens = new address[](1);
        wTokens[0] = address(usdc);
        uint256[] memory wAmounts = new uint256[](1);
        wAmounts[0] = 100e6;
        _requestWithdrawal(wTokens, wAmounts, withdrawRecipient);

        address[] memory pref = new address[](1);
        pref[0] = address(usdc);

        DebitModeMaxSpend memory result = cashLens.getMaxSpendDebit(address(safe), pref);
        assertApproxEqAbs(result.spendableAmounts[0], 500e6, 1e4, "pending reserved from raw only; supplied side capped by headroom");
    }

    // ================ canSpend (debit) declines ================

    /// Debit canSpend declines (does not revert) when a pending withdrawal exceeds the currently available balance.
    function test_canSpendDebit_pendingExceedsAvailable_declines() public {
        deal(address(usdc), address(safe), 5000e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 5000e6;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // Drop the raw balance below the pending amount with no supplied position: available < pending.
        deal(address(usdc), address(safe), 100e6);

        uint256[] memory amountsInUsd = new uint256[](1);
        amountsInUsd[0] = 1e6;
        (bool ok, string memory reason) = cashLens.canSpend(address(safe), keccak256("p3"), tokens, amountsInUsd);
        assertFalse(ok, "should decline");
        assertEq(reason, "Insufficient effective balance after withdrawal to spend with debit mode", "declines with a reason instead of reverting");
    }

    /// A pending raw reservation consumes the shared headroom for a later token: the first leg spends it all, so the second is declined.
    function test_canSpendDebit_pendingRawConsumesSuppliedHeadroom() public {
        // 200 USDC + 1000 liquidUSD supplied at 50%, 500 borrowed: headroom $100. $500 raw USDC, of which $400 is
        // reserved by a pending withdrawal, leaving $100 effective. A $300 USDC spend uses $100 raw + $200 supplied,
        // and that $200 at 50% consumes the entire $100 headroom, so the later $50 liquidUSD leg has nothing left.
        _supplyToGateway(address(safe), address(usdc), 200e6);
        _supplyToGateway(address(safe), address(liquidUsd), 1000e6);
        _borrowOnGateway(address(safe), address(usdc), 500e6, recipient);
        deal(address(usdc), address(safe), 500e6);
        deal(address(liquidUsd), address(safe), 0);

        address[] memory wTokens = new address[](1);
        wTokens[0] = address(usdc);
        uint256[] memory wAmounts = new uint256[](1);
        wAmounts[0] = 400e6;
        _requestWithdrawal(wTokens, wAmounts, withdrawRecipient);

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

    // ================ getMaxSpendCredit ================

    /// Credit max spend equals the gateway's borrowing power when reserve liquidity is ample.
    function test_credit_equalsBorrowPower() public {
        _supplyToGateway(address(safe), address(usdc), 2000e6);

        uint256 creditMaxSpend = cashLens.getMaxSpendCredit(address(safe));
        uint256 borrowPower = gw.getAccountData(address(safe)).availableBorrowsUsd;
        assertGt(creditMaxSpend, 0, "positive credit limit with collateral");
        assertEq(creditMaxSpend, borrowPower, "credit max spend is the gateway borrowing power");
    }

    /// Credit max spend is capped by the borrow token's borrowable liquidity (pool cash under the drawCap),
    /// not just the borrowing power.
    function test_credit_cappedByPoolLiquidity() public {
        _supplyToGateway(address(safe), address(usdc), 2000e6); // ~$1000 borrowing power at 50%

        // Every borrow reserve can lend less than the borrowing power, so borrowable liquidity binds.
        vm.mockCall(address(gw), abi.encodeWithSelector(ILendGateway.availableToBorrow.selector, address(usdc)), abi.encode(uint256(400e6)));
        vm.mockCall(address(gw), abi.encodeWithSelector(ILendGateway.availableToBorrow.selector, address(liquidUsd)), abi.encode(uint256(0)));

        assertEq(cashLens.getMaxSpendCredit(address(safe)), 400e6, "credit max spend capped by borrowable liquidity, not borrowing power");
    }

    // ================ getSafeCashData ================

    /// maxBorrow stays gross (headroom + debt), totalBorrow is the debt, and creditMaxSpend is the net headroom.
    function test_safeCashData_maxBorrowIsGrossWithDebt() public {
        // 2000 USDC supplied at 50% with 800 borrowed: gross power $1000, net headroom $200.
        _buildDebtPosition(2000e6, 0, 800e6);

        SafeCashData memory data = cashLens.getSafeCashData(address(safe), new address[](0));
        ILendGateway.AccountData memory account = gw.getAccountData(address(safe));

        assertApproxEqAbs(data.totalBorrow, 800e6, 2, "totalBorrow is the debt");
        assertEq(data.maxBorrow, account.availableBorrowsUsd + account.debtUsd, "maxBorrow is gross: headroom + debt");
        assertEq(data.creditMaxSpend, account.availableBorrowsUsd, "creditMaxSpend is the net headroom (liquidity ample)");
        assertEq(data.maxBorrow, data.totalBorrow + data.creditMaxSpend, "gross == debt + net headroom");
        assertGt(data.maxBorrow, data.creditMaxSpend, "gross exceeds net once there is debt");
    }

    /// getSafeCashData honors the token preference order and populates the position fields.
    function test_safeCashData_tokenPreferenceOrdering() public {
        _supplyToGateway(address(safe), address(usdc), 2000e6);
        _supplyToGateway(address(safe), address(liquidUsd), 2000e6);

        address[] memory pref = new address[](2);
        pref[0] = address(liquidUsd);
        pref[1] = address(usdc);

        SafeCashData memory data = cashLens.getSafeCashData(address(safe), pref);
        assertEq(data.debitMaxSpend.spendableTokens[0], address(liquidUsd), "first token is liquidUSD");
        assertEq(data.debitMaxSpend.spendableTokens[1], address(usdc), "second token is USDC");
        assertGt(data.debitMaxSpend.totalSpendableInUsd, 0, "has spendable amount");
        assertGt(data.totalCollateral, 0, "has collateral value");
        assertEq(data.totalBorrow, 0, "no borrows initially");
    }

    /// An empty preference falls back to all borrow tokens.
    function test_safeCashData_emptyPreference_allBorrowTokens() public {
        _supplyToGateway(address(safe), address(usdc), 2000e6);
        _supplyToGateway(address(safe), address(liquidUsd), 2000e6);

        SafeCashData memory data = cashLens.getSafeCashData(address(safe), new address[](0));
        assertGt(data.debitMaxSpend.spendableTokens.length, 0, "has default borrow tokens");

        bool hasUsdc;
        bool hasLiquidUsd;
        for (uint256 i = 0; i < data.debitMaxSpend.spendableTokens.length; i++) {
            if (data.debitMaxSpend.spendableTokens[i] == address(usdc)) hasUsdc = true;
            if (data.debitMaxSpend.spendableTokens[i] == address(liquidUsd)) hasLiquidUsd = true;
        }
        assertTrue(hasUsdc && hasLiquidUsd, "includes both USDC and liquidUSD");
    }

    /// debitMaxSpend in getSafeCashData matches a direct getMaxSpendDebit call.
    function test_safeCashData_consistencyWithDirectCall() public {
        _supplyToGateway(address(safe), address(usdc), 2000e6);
        _supplyToGateway(address(safe), address(liquidUsd), 2000e6);

        address[] memory pref = new address[](2);
        pref[0] = address(usdc);
        pref[1] = address(liquidUsd);

        SafeCashData memory data = cashLens.getSafeCashData(address(safe), pref);
        DebitModeMaxSpend memory direct = cashLens.getMaxSpendDebit(address(safe), pref);

        assertEq(data.debitMaxSpend.totalSpendableInUsd, direct.totalSpendableInUsd, "total USD matches");
        assertEq(data.debitMaxSpend.spendableTokens.length, direct.spendableTokens.length, "token count matches");
        for (uint256 i = 0; i < data.debitMaxSpend.spendableTokens.length; i++) {
            assertEq(data.debitMaxSpend.spendableTokens[i], direct.spendableTokens[i], "tokens match");
            assertEq(data.debitMaxSpend.spendableAmounts[i], direct.spendableAmounts[i], "amounts match");
            assertEq(data.debitMaxSpend.amountsInUsd[i], direct.amountsInUsd[i], "USD amounts match");
        }
    }

    /// A non-stable carrying the borrowing power: both supplied stables stay fully spendable, credit is the un-haircut headroom, and maxBorrow stays gross.
    function test_safeCashData_mixedCollateral_weEthCarriesPower() public {
        // weETH carries most of the borrowing power, so the headroom never binds and both stables are face-bound.
        _supplyToGateway(address(safe), address(weETH), 10 ether);
        _supplyToGateway(address(safe), address(usdc), 5000e6);
        _supplyToGateway(address(safe), address(liquidUsd), 2000e6);
        _borrowOnGateway(address(safe), address(usdc), 4000e6, recipient);
        deal(address(usdc), address(safe), 0);
        deal(address(liquidUsd), address(safe), 0);

        address[] memory pref = new address[](2);
        pref[0] = address(usdc);
        pref[1] = address(liquidUsd);

        DebitModeMaxSpend memory debit = cashLens.getMaxSpendDebit(address(safe), pref);
        assertApproxEqAbs(debit.spendableAmounts[0], 5000e6, 2, "USDC fully spendable: the headroom never binds");
        assertApproxEqAbs(debit.spendableAmounts[1], 2000e6, 2, "liquidUSD fully spendable: the headroom never binds");

        SafeCashData memory data = cashLens.getSafeCashData(address(safe), pref);
        ILendGateway.AccountData memory account = gw.getAccountData(address(safe));
        assertApproxEqAbs(data.totalBorrow, 4000e6, 2, "totalBorrow is the debt");
        assertEq(cashLens.getMaxSpendCredit(address(safe)), account.availableBorrowsUsd, "credit max spend is the un-haircut availableBorrowsUsd");
        assertEq(data.maxBorrow, account.availableBorrowsUsd + account.debtUsd, "maxBorrow is gross power: headroom + debt");
        assertEq(data.creditMaxSpend, account.availableBorrowsUsd, "creditMaxSpend is the net headroom");
        assertEq(data.totalCollateral, account.collateralUsd, "totalCollateral mirrors the gateway aggregate");
    }

    // ================ helpers ================

    /// @dev Supplies USDC (+ optional liquidUSD) at 50% collateral factor and borrows `borrowUsdc` against it.
    function _buildDebtPosition(uint256 suppliedUsdc, uint256 suppliedLiquid, uint256 borrowUsdc) internal {
        _supplyToGateway(address(safe), address(usdc), suppliedUsdc);
        if (suppliedLiquid > 0) {
            _supplyToGateway(address(safe), address(liquidUsd), suppliedLiquid);
        }
        if (borrowUsdc > 0) {
            _borrowOnGateway(address(safe), address(usdc), borrowUsdc, recipient);
        }
    }
}
