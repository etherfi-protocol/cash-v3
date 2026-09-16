// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { UUPSProxy } from "../../../../../src/UUPSProxy.sol";
import { StdStorage, stdStorage } from "forge-std/Test.sol";

import { IAggregatorV3 } from "../../../../../src/interfaces/IAggregatorV3.sol";
import { ICashModule } from "../../../../../src/interfaces/ICashModule.sol";
import { IMidasVault } from "../../../../../src/interfaces/IMidasVault.sol";
import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";
import { ModuleCheckBalance } from "../../../../../src/modules/ModuleCheckBalance.sol";
import { MidasLiquifierModule } from "../../../../../src/modules/etherfi/MidasLiquifierModule.sol";
import { LendGateway } from "../../../../../src/modules/lend-gateway/LendGateway.sol";
import { PriceProvider } from "../../../../../src/oracle/PriceProvider.sol";
import { UpgradeableProxy } from "../../../../../src/utils/UpgradeableProxy.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

contract MockMidasRedemptionVault is IMidasVault {
    address public immutable midasToken;

    constructor(address _midasToken) {
        midasToken = _midasToken;
    }

    function depositInstant(address, uint256, uint256, bytes32) external { }
    function redeemInstant(address, uint256, uint256) external { }

    function redeemRequest(address, uint256 amountMTokenIn, address) external returns (uint256) {
        IERC20(midasToken).transferFrom(msg.sender, address(this), amountMTokenIn);
        return 0;
    }
}

/**
 * @title MidasLiquifierGatewayTest
 * @notice Exercises the Midas liquifier's gateway repay leg against the real LendGateway: the float hops
 *         through the safe into gateway.repay (capped at the safe's Aave debt) and the payment token reclaim
 *         pulls the shortfall out of the safe's Aave position. The legacy DebtManager twin lives in
 *         test/safe/modules/etherfi/MidasLiquifier.t.sol.
 */
contract MidasLiquifierGatewayTest is CashGatewayTestSetup {
    using stdStorage for StdStorage;

    MidasLiquifierModule internal liquifier;
    MockERC20 internal mToken;
    MockMidasRedemptionVault internal redemptionVault;

    uint16 constant FEE_BPS = 50;

    function setUp() public override {
        super.setUp();

        mToken = new MockERC20("Liquid RWA", "liquidRWA", 18);
        redemptionVault = new MockMidasRedemptionVault(address(mToken));

        uint256 mTokenReserveId = _addAaveReserve(address(mToken), usdcUsdOracle, 7000, false);
        PriceProvider.Config[] memory configs = new PriceProvider.Config[](1);
        configs[0] = PriceProvider.Config({ oracle: usdcUsdOracle, priceFunctionCalldata: hex"", isChainlinkType: true, oraclePriceDecimals: IAggregatorV3(usdcUsdOracle).decimals(), maxStaleness: type(uint24).max, dataType: PriceProvider.ReturnType.Int256, isBaseTokenEth: false, isStableToken: true, isBaseTokenBtc: false });

        address impl = address(new MidasLiquifierModule(address(debtManager), address(dataProvider)));
        liquifier = MidasLiquifierModule(address(new UUPSProxy(impl, "")));
        liquifier.initialize(address(roleRegistry));

        vm.startPrank(owner);
        priceProvider.setTokenConfig(_addr1(address(mToken)), configs);
        gw.setReserveId(address(mToken), mTokenReserveId);
        gw.setDriver(address(liquifier), true);
        dataProvider.configureDefaultModules(_addr1(address(liquifier)), _bool1(true));
        liquifier.setPair(address(mToken), address(usdc), address(redemptionVault), FEE_BPS, 0);
        vm.stopPrank();
    }

    function _buildDebtAndSuppliedMToken(uint256 debtAmount, uint256 supplied) internal {
        _buildGatewayPosition(address(safe), address(weETH), 1 ether, address(usdc), debtAmount);
        _supplyToGateway(address(safe), address(mToken), supplied);
        deal(address(usdc), address(liquifier), 1000e6);
    }

    function _paymentWithFee(uint256 debtAmount) internal view returns (uint256) {
        uint256 payment = liquifier.convertDebtToPayment(address(mToken), debtAmount);
        return payment + payment * FEE_BPS / 10_000;
    }

    /// @notice Verifies repayment uses the module's float and collects payment plus fees from Aave-supplied tokens.
    function test_repay_repaysAaveDebtAndReclaimsSuppliedPayment() public {
        _buildDebtAndSuppliedMToken(500e6, 1000e18);

        uint256 debtAmount = 200e6;
        uint256 debtBefore = gw.debtOf(address(safe), address(usdc));
        uint256 floatBefore = usdc.balanceOf(address(liquifier));
        uint256 expected = _paymentWithFee(debtAmount);

        vm.prank(etherFiWallet);
        liquifier.repay(address(safe), address(mToken), debtAmount);

        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), debtBefore - debtAmount, 1, "Aave debt not reduced");
        assertApproxEqAbs(floatBefore - usdc.balanceOf(address(liquifier)), debtAmount, 1, "float not spent by the repaid amount");
        assertApproxEqAbs(mToken.balanceOf(address(liquifier)), expected, 1e12, "payment not reclaimed");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(mToken)), 1000e18 - expected, 1e12, "supplied payment not debited");
        assertEq(mToken.balanceOf(address(safe)), 0, "payment token left loose in safe");
        assertEq(usdc.balanceOf(address(safe)), 0, "USDC left loose in safe");
    }

    /// @notice Verifies collection uses loose payment tokens first and withdraws only the shortfall from Aave.
    function test_repay_reclaimsLooseFirstThenSuppliedShortfall() public {
        _buildDebtAndSuppliedMToken(500e6, 1000e18);
        uint256 loose = 100e18;
        mToken.mint(address(safe), loose);

        uint256 expected = _paymentWithFee(200e6);
        assertGt(expected, loose, "fixture: reclaim must exceed the loose balance");

        vm.prank(etherFiWallet);
        liquifier.repay(address(safe), address(mToken), 200e6);

        assertEq(mToken.balanceOf(address(safe)), 0, "loose payment not consumed first");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(mToken)), 1000e18 - (expected - loose), 1e12, "only the shortfall should leave Aave");
    }

    /// @notice Verifies repayment preserves the Safe's existing loose USDC balance.
    function test_repay_doesNotTouchSafesOwnLooseUsdc() public {
        _buildDebtAndSuppliedMToken(500e6, 1000e18);
        deal(address(usdc), address(safe), 300e6);
        uint256 debtBefore = gw.debtOf(address(safe), address(usdc));

        vm.prank(etherFiWallet);
        liquifier.repay(address(safe), address(mToken), 200e6);

        assertApproxEqAbs(usdc.balanceOf(address(safe)), 300e6, 1, "safe's own loose USDC was consumed");
        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), debtBefore - 200e6, 1, "debt not reduced by the repaid amount");
    }

    /// @notice Verifies repayment reverts when the Safe cannot cover the payment with its available tokens.
    function test_repay_revertsWhenSafeCannotCoverReclaim() public {
        _buildGatewayPosition(address(safe), address(weETH), 1 ether, address(usdc), 200e6);
        _supplyToGateway(address(safe), address(mToken), 10e18);
        deal(address(usdc), address(liquifier), 1000e6);

        vm.prank(etherFiWallet);
        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        liquifier.repay(address(safe), address(mToken), 100e6);
    }

    /// @notice Verifies an oversized repayment clears only outstanding debt without leaving float in the Safe.
    function test_repay_capsAtDebtAndStrandsNoFloat() public {
        _buildDebtAndSuppliedMToken(100e6, 1000e18);
        uint256 debt = gw.debtOf(address(safe), address(usdc));
        uint256 floatBefore = usdc.balanceOf(address(liquifier));

        vm.prank(etherFiWallet);
        liquifier.repay(address(safe), address(mToken), 400e6);

        assertEq(gw.debtOf(address(safe), address(usdc)), 0, "Aave debt not cleared");
        assertEq(usdc.balanceOf(address(safe)), 0, "float stranded in safe");
        assertApproxEqAbs(floatBefore - usdc.balanceOf(address(liquifier)), debt, 1, "float spent beyond the debt");
    }

    /// @notice Verifies repayment reverts when the Safe has no outstanding debt.
    function test_repay_revertsOnZeroDebt() public {
        deal(address(usdc), address(liquifier), 1000e6);

        vm.prank(etherFiWallet);
        vm.expectRevert(MidasLiquifierModule.AmountZero.selector);
        liquifier.repay(address(safe), address(mToken), 100e6);
    }

    /// @notice Verifies repayment reverts when the module has insufficient USDC float.
    function test_repay_revertsWhenFloatInsufficient() public {
        _buildGatewayPosition(address(safe), address(weETH), 1 ether, address(usdc), 200e6);
        _supplyToGateway(address(safe), address(mToken), 1000e18);

        vm.prank(etherFiWallet);
        vm.expectRevert(MidasLiquifierModule.InsufficientFloat.selector);
        liquifier.repay(address(safe), address(mToken), 100e6);
    }

    /// @notice Verifies redemption transfers collected payment tokens from the module to the Midas vault.
    function test_redeemMidas_sendsAccumulatedPaymentToVault() public {
        _buildDebtAndSuppliedMToken(500e6, 1000e18);
        vm.prank(etherFiWallet);
        liquifier.repay(address(safe), address(mToken), 200e6);
        uint256 held = mToken.balanceOf(address(liquifier));
        assertGt(held, 0);

        vm.prank(owner);
        liquifier.redeemMidas(address(mToken), held);

        assertEq(mToken.balanceOf(address(liquifier)), 0);
        assertEq(mToken.balanceOf(address(redemptionVault)), held);
    }

    // ----------------------------------------------------------------- fee, roles, engine gate

    /// @notice Verifies repayment emits Repaid with the expected Safe, payment token, and debt token.
    function test_repay_emitsRepaidWithFee() public {
        _buildDebtAndSuppliedMToken(500e6, 1000e18);
        uint256 debtAmount = 200e6;
        uint256 payment = liquifier.convertDebtToPayment(address(mToken), debtAmount);
        uint256 fee = payment * FEE_BPS / 10_000;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, false);
        emit MidasLiquifierModule.Repaid(address(safe), address(mToken), address(usdc), debtAmount, payment, fee);
        liquifier.repay(address(safe), address(mToken), debtAmount);
    }

    /// @notice Verifies zero-fee repayment collects only the converted payment amount.
    function test_repay_zeroFeeTakesExactConversion() public {
        _buildDebtAndSuppliedMToken(500e6, 1000e18);
        vm.prank(owner);
        liquifier.setPair(address(mToken), address(usdc), address(redemptionVault), 0, 0);
        uint256 payment = liquifier.convertDebtToPayment(address(mToken), 200e6);

        vm.prank(etherFiWallet);
        liquifier.repay(address(safe), address(mToken), 200e6);

        assertApproxEqAbs(mToken.balanceOf(address(liquifier)), payment, 1e12, "fee charged at 0 bps");
    }

    /// @notice Verifies repayment collects both proportional and converted flat fees.
    function test_repay_flatFeeAddsOnTopOfBps() public {
        _buildDebtAndSuppliedMToken(500e6, 1000e18);
        uint128 flatFee = 1e6; // 1 USDC per repayment
        vm.prank(owner);
        liquifier.setPair(address(mToken), address(usdc), address(redemptionVault), FEE_BPS, flatFee);

        uint256 payment = liquifier.convertDebtToPayment(address(mToken), 200e6);
        uint256 expected = payment + payment * FEE_BPS / 10_000 + liquifier.convertDebtToPayment(address(mToken), flatFee);

        vm.prank(etherFiWallet);
        liquifier.repay(address(safe), address(mToken), 200e6);

        assertApproxEqAbs(mToken.balanceOf(address(liquifier)), expected, 1e12, "flat fee not charged");
    }

    // A fee takes more collateral than the debt it clears, so it is the one part of a repayment that can
    // worsen health. From under the floor, a fee-heavy repay that lowers health is rejected, while a small
    // fee that still leaves health better than before goes through.
    /// @notice Verifies repayment below the gateway floor rejects fees that worsen health but allows fees that improve health.
    function test_repay_feeTakesGatewayHealthFactorFloor() public {
        _supplyToGateway(address(safe), address(mToken), 10_000e18);
        _borrowOnGateway(address(safe), address(usdc), 6800e6, recipient);
        deal(address(usdc), address(liquifier), 1000e6);
        vm.prank(owner);
        gw.setMinHealthFactor(1.05e18);
        uint256 hfBefore = gw.healthFactor(address(safe));
        assertLt(hfBefore, 1.05e18, "safe starts below the floor");

        // 100 of debt cleared for 200 of collateral out: health drops, and it is under the floor
        vm.prank(owner);
        liquifier.setPair(address(mToken), address(usdc), address(redemptionVault), 0, 100e6);
        vm.prank(etherFiWallet);
        vm.expectRevert(LendGateway.HealthFactorBelowMinimum.selector);
        liquifier.repay(address(safe), address(mToken), 100e6);

        // 100 of debt cleared for 110 of collateral out: health still improves, so the floor does not apply
        vm.prank(owner);
        liquifier.setPair(address(mToken), address(usdc), address(redemptionVault), 0, 10e6);
        vm.prank(etherFiWallet);
        liquifier.repay(address(safe), address(mToken), 100e6);
        assertGt(gw.healthFactor(address(safe)), hfBefore, "health improved");
    }

    // Zero fee is the de-risking path and is never blocked by the floor, even from under it.
    /// @notice Verifies zero-fee repayment remains available below the gateway health floor.
    function test_repay_zeroFeeIgnoresGatewayHealthFactorFloor() public {
        _supplyToGateway(address(safe), address(mToken), 10_000e18);
        _borrowOnGateway(address(safe), address(usdc), 6800e6, recipient);
        deal(address(usdc), address(liquifier), 1000e6);
        vm.startPrank(owner);
        gw.setMinHealthFactor(1.05e18);
        liquifier.setPair(address(mToken), address(usdc), address(redemptionVault), 0, 0);
        vm.stopPrank();

        vm.prank(etherFiWallet);
        liquifier.repay(address(safe), address(mToken), 100e6);
        assertEq(gw.debtOf(address(safe), address(usdc)), 6700e6, "debt not reduced");
    }

    /// @notice Verifies repayment rejects a payment token without a configured pair.
    function test_repay_revertsWhenPairNotSet() public {
        vm.prank(etherFiWallet);
        vm.expectRevert(MidasLiquifierModule.PairNotSet.selector);
        liquifier.repay(address(safe), address(usdc), 10e6);
    }

    /// @notice Verifies repayment rejects a zero debt amount.
    function test_repay_revertsOnZeroAmount() public {
        vm.prank(etherFiWallet);
        vm.expectRevert(MidasLiquifierModule.AmountZero.selector);
        liquifier.repay(address(safe), address(mToken), 0);
    }

    /// @notice Verifies repayment rejects callers without the EtherFi Wallet role.
    function test_repay_onlyEtherFiWallet() public {
        vm.prank(makeAddr("notEtherFiWallet"));
        vm.expectRevert(MidasLiquifierModule.OnlyEtherFiWallet.selector);
        liquifier.repay(address(safe), address(mToken), 10e6);
    }

    /// @notice Verifies repayment rejects an account that is not an EtherFi Safe.
    function test_repay_onlyEtherFiSafe() public {
        vm.prank(etherFiWallet);
        vm.expectRevert(MidasLiquifierModule.OnlyEtherFiSafe.selector);
        liquifier.repay(makeAddr("notASafe"), address(mToken), 10e6);
    }

    // ----------------------------------------------------------------- conversions

    /// @notice Verifies conversion between six-decimal debt and eighteen-decimal payment tokens preserves value within rounding tolerance.
    function test_conversions_roundTrip() public view {
        uint256 debtAmount = 123_456_789;
        uint256 payment = liquifier.convertDebtToPayment(address(mToken), debtAmount);
        assertApproxEqAbs(payment, debtAmount * 1e12, 1e12, "18-dec payment for 6-dec debt at ~$1");
        assertApproxEqAbs(liquifier.convertPaymentToDebt(address(mToken), payment), debtAmount, 1, "round trip");
    }

    // ----------------------------------------------------------------- pair config

    /// @notice Verifies pair configuration stores every field and emits the matching PairSet event.
    function test_setPair_emitsAndStores() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit MidasLiquifierModule.PairSet(address(mToken), address(usdc), address(redemptionVault), 25, 2e6);
        liquifier.setPair(address(mToken), address(usdc), address(redemptionVault), 25, 2e6);

        MidasLiquifierModule.Pair memory pair = liquifier.pairs(address(mToken));
        assertEq(pair.debtToken, address(usdc));
        assertEq(pair.redemptionVault, address(redemptionVault));
        assertEq(pair.feeBps, 25);
        assertEq(pair.flatFee, 2e6);
    }

    /// @notice Verifies pair configuration rejects a zero payment token, debt token, or redemption vault address.
    function test_setPair_revertsOnZeroAddress() public {
        vm.startPrank(owner);
        vm.expectRevert(MidasLiquifierModule.InvalidValue.selector);
        liquifier.setPair(address(0), address(usdc), address(redemptionVault), 0, 0);
        vm.expectRevert(MidasLiquifierModule.InvalidValue.selector);
        liquifier.setPair(address(mToken), address(0), address(redemptionVault), 0, 0);
        vm.expectRevert(MidasLiquifierModule.InvalidValue.selector);
        liquifier.setPair(address(mToken), address(usdc), address(0), 0, 0);
        vm.stopPrank();
    }

    /// @notice Verifies pair configuration rejects proportional fees above MAX_FEE_BPS.
    function test_setPair_revertsOnFeeTooHigh() public {
        uint16 tooHigh = liquifier.MAX_FEE_BPS() + 1;
        vm.prank(owner);
        vm.expectRevert(MidasLiquifierModule.FeeTooHigh.selector);
        liquifier.setPair(address(mToken), address(usdc), address(redemptionVault), tooHigh, 0);
    }

    /// @notice Verifies only the role registry owner can configure a pair.
    function test_setPair_onlyRoleRegistryOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(UpgradeableProxy.OnlyRoleRegistryOwner.selector);
        liquifier.setPair(address(mToken), address(usdc), address(redemptionVault), 0, 0);
    }

    /// @notice Verifies pair removal clears its configuration, emits PairRemoved, and blocks subsequent repayment.
    function test_removePair_clearsAndBlocksRepay() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit MidasLiquifierModule.PairRemoved(address(mToken));
        liquifier.removePair(address(mToken));

        assertEq(liquifier.pairs(address(mToken)).debtToken, address(0));

        vm.prank(etherFiWallet);
        vm.expectRevert(MidasLiquifierModule.PairNotSet.selector);
        liquifier.repay(address(safe), address(mToken), 10e6);
    }

    // ----------------------------------------------------------------- redeemMidas

    /// @notice Verifies redemption emits the payment token, output asset, and requested amount.
    function test_redeemMidas_emits() public {
        mToken.mint(address(liquifier), 500e18);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit MidasLiquifierModule.MidasRedeemRequested(address(mToken), address(usdc), 500e18);
        liquifier.redeemMidas(address(mToken), 500e18);
    }

    /// @notice Verifies redemption rejects callers without the settlement dispatcher bridger role.
    function test_redeemMidas_onlySettlementDispatcherBridger() public {
        vm.prank(makeAddr("notBridger"));
        vm.expectRevert(MidasLiquifierModule.OnlySettlementDispatcherBridger.selector);
        liquifier.redeemMidas(address(mToken), 1e18);
    }

    /// @notice Verifies redemption rejects a zero amount or an unconfigured pair.
    function test_redeemMidas_revertsOnZeroAmountAndUnknownPair() public {
        vm.startPrank(owner);
        vm.expectRevert(MidasLiquifierModule.AmountZero.selector);
        liquifier.redeemMidas(address(mToken), 0);
        vm.expectRevert(MidasLiquifierModule.PairNotSet.selector);
        liquifier.redeemMidas(address(usdc), 1e6);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- withdrawFunds

    /// @notice Verifies the owner can withdraw the full ERC20 balance and a specified ETH amount.
    function test_withdrawFunds_erc20AndNative() public {
        deal(address(usdc), address(liquifier), 1000e6);
        deal(address(liquifier), 1 ether);
        address recipient = makeAddr("recipient");

        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true);
        emit MidasLiquifierModule.FundsWithdrawn(address(usdc), 1000e6, recipient);
        liquifier.withdrawFunds(address(usdc), recipient, 0);
        liquifier.withdrawFunds(liquifier.ETH(), recipient, 0.5 ether);
        vm.stopPrank();

        assertEq(usdc.balanceOf(recipient), 1000e6);
        assertEq(recipient.balance, 0.5 ether);
    }

    /// @notice Verifies withdrawals reject invalid recipients, empty balances, failed ETH transfers, and unauthorized callers.
    function test_withdrawFunds_reverts() public {
        address eth = liquifier.ETH();
        vm.startPrank(owner);
        vm.expectRevert(MidasLiquifierModule.InvalidValue.selector);
        liquifier.withdrawFunds(address(usdc), address(0), 1);
        vm.expectRevert(MidasLiquifierModule.CannotWithdrawZeroAmount.selector);
        liquifier.withdrawFunds(address(mToken), owner, 0);
        vm.expectRevert(MidasLiquifierModule.WithdrawFundsFailed.selector);
        liquifier.withdrawFunds(eth, owner, 1 ether);
        vm.stopPrank();

        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(UpgradeableProxy.OnlyRoleRegistryOwner.selector);
        liquifier.withdrawFunds(address(usdc), owner, 1);
    }
}
