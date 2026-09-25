// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { StdStorage, stdStorage } from "forge-std/Test.sol";

import { UUPSProxy } from "../../../../src/UUPSProxy.sol";
import { IAggregatorV3 } from "../../../../src/interfaces/IAggregatorV3.sol";
import { BinSponsor, Cashback, ICashModule, Mode } from "../../../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../../../src/interfaces/IDebtManager.sol";
import { IMidasVault } from "../../../../src/interfaces/IMidasVault.sol";
import { MockERC20 } from "../../../../src/mocks/MockERC20.sol";
import { IERC20, MidasLiquifierModule, ModuleCheckBalance } from "../../../../src/modules/etherfi/MidasLiquifierModule.sol";
import { PriceProvider } from "../../../../src/oracle/PriceProvider.sol";
import { MessageHashUtils } from "../../SafeTestSetup.t.sol";
import { CashModuleTestSetup } from "../cash/CashModuleTestSetup.t.sol";

/// @dev Redemption vault stub: escrows the Midas token and returns nothing, like the real async vault.
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

/// @notice Legacy (DebtManager) engine repay tests; the gateway twin and the config, redeem and withdraw tests live in
///         test/safe/modules/cash/lend/MidasLiquifierGateway.t.sol.
contract MidasLiquifierTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;
    using stdStorage for StdStorage;

    MidasLiquifierModule public liquifier;
    MockERC20 public mToken;
    MockMidasRedemptionVault public redemptionVault;
    IERC20 public USDC;

    uint16 constant FEE_BPS = 50;
    uint256 initialMTokenBalance = 10_000e18;
    uint256 initialFloat = 10_000e6;
    uint256 initialDebtAmount = 100e6;

    function setUp() public override {
        super.setUp();

        USDC = IERC20(chainConfig.usdc);
        _updateSpendingLimit(10_000e6, 10_000e6);
        deal(address(weETH), address(safe), 1 ether);
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        mToken = new MockERC20("Liquid RWA", "liquidRWA", 18);
        redemptionVault = new MockMidasRedemptionVault(address(mToken));

        // Price the 18-decimal vault token off the USDC/USD feed so it is worth $1 like its underlying.
        PriceProvider.Config[] memory configs = new PriceProvider.Config[](1);
        configs[0] = PriceProvider.Config({ oracle: usdcUsdOracle, priceFunctionCalldata: hex"", isChainlinkType: true, oraclePriceDecimals: IAggregatorV3(usdcUsdOracle).decimals(), maxStaleness: type(uint24).max, dataType: PriceProvider.ReturnType.Int256, isBaseTokenEth: false, isStableToken: true, isBaseTokenBtc: false });
        address[] memory tokens = new address[](1);
        tokens[0] = address(mToken);

        stdstore.enable_packed_slots().target(address(cashModule)).sig(ICashModule.usesLendGateway.selector).with_key(address(safe)).checked_write(false);

        address impl = address(new MidasLiquifierModule(address(debtManager), address(dataProvider)));
        liquifier = MidasLiquifierModule(address(new UUPSProxy(impl, "")));
        liquifier.initialize(address(roleRegistry));

        address[] memory modules = new address[](1);
        modules[0] = address(liquifier);
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.startPrank(owner);
        priceProvider.setTokenConfig(tokens, configs);
        dataProvider.configureDefaultModules(modules, shouldWhitelist);
        liquifier.setPair(address(mToken), address(USDC), address(redemptionVault), FEE_BPS, 0);
        vm.stopPrank();

        mToken.mint(address(safe), initialMTokenBalance);
        deal(address(USDC), address(liquifier), initialFloat);

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(USDC);
        uint256[] memory amountsInUsd = new uint256[](1);
        amountsInUsd[0] = initialDebtAmount;
        Cashback[] memory cashbacks = new Cashback[](0);

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), keccak256("txId"), BinSponsor.Reap, spendTokens, amountsInUsd, cashbacks);
    }

    /// @notice Verifies legacy repayment reduces debt using the module's float and collects payment plus the proportional fee.
    function test_repay_reducesDebtAndTakesPaymentPlusFee() public {
        uint256 debtAmount = 10e6;
        uint256 expectedPayment = liquifier.convertDebtToPayment(address(mToken), debtAmount);
        uint256 expectedFee = expectedPayment * FEE_BPS / 10_000;
        uint256 debtBefore = debtManager.borrowingOf(address(safe), address(USDC));
        uint256 safeMTokenBefore = mToken.balanceOf(address(safe));
        uint256 floatBefore = USDC.balanceOf(address(liquifier));

        vm.prank(etherFiWallet);
        liquifier.repay(address(safe), address(mToken), debtAmount, type(uint256).max);

        // The DebtManager settles through its normalized-debt index, so the repaid figure can land 1 unit off.
        assertApproxEqAbs(debtBefore - debtManager.borrowingOf(address(safe), address(USDC)), debtAmount, 1, "debt not reduced");
        assertApproxEqAbs(floatBefore - USDC.balanceOf(address(liquifier)), debtAmount, 1, "float not spent");
        assertApproxEqAbs(safeMTokenBefore - mToken.balanceOf(address(safe)), expectedPayment + expectedFee, 1e12, "payment not taken");
        assertEq(mToken.balanceOf(address(liquifier)), safeMTokenBefore - mToken.balanceOf(address(safe)), "payment not received");
    }

    /// @notice Verifies that fees which leave a legacy Safe unhealthy revert repayment and restore debt and token balances.
    function test_repay_revertsWhenFeeLeavesLegacySafeUnhealthy() public {
        vm.startPrank(owner);
        debtManager.supportCollateralToken(address(mToken), IDebtManager.CollateralTokenConfig({ ltv: 70e18, liquidationThreshold: 80e18, liquidationBonus: 4e18 }));
        liquifier.setPair(address(mToken), address(USDC), address(redemptionVault), 0, 100e6);
        vm.stopPrank();

        // $200 collateral supports the existing $100 debt. Repaying $10 and charging $100 leaves
        // $90 collateral against $90 debt, although the approval-time hook still sees $200 collateral.
        deal(address(weETH), address(safe), 0);
        deal(address(mToken), address(safe), 200e18);
        debtManager.ensureHealth(address(safe));
        uint256 debtBefore = debtManager.borrowingOf(address(safe), address(USDC));

        vm.prank(etherFiWallet);
        vm.expectRevert(IDebtManager.AccountUnhealthy.selector);
        liquifier.repay(address(safe), address(mToken), 10e6, type(uint256).max);

        assertEq(debtManager.borrowingOf(address(safe), address(USDC)), debtBefore, "debt change not reverted");
        assertEq(USDC.balanceOf(address(liquifier)), initialFloat, "float change not reverted");
        assertEq(mToken.balanceOf(address(safe)), 200e18, "payment not reverted");
    }

    /// @notice Verifies an oversized legacy repayment clears outstanding debt and charges payment plus fees only on that debt.
    function test_repay_capsAtOutstandingDebt() public {
        uint256 requested = initialDebtAmount + 10e6;
        uint256 expectedPayment = liquifier.convertDebtToPayment(address(mToken), initialDebtAmount);
        uint256 safeMTokenBefore = mToken.balanceOf(address(safe));

        vm.prank(etherFiWallet);
        liquifier.repay(address(safe), address(mToken), requested, type(uint256).max);

        // The DebtManager floors the normalized amount it clears, so a full repayment can leave one unit of USD dust
        assertApproxEqAbs(debtManager.borrowingOf(address(safe), address(USDC)), 0, 1, "debt not cleared");
        assertApproxEqAbs(safeMTokenBefore - mToken.balanceOf(address(safe)), expectedPayment + expectedPayment * FEE_BPS / 10_000, 1e12, "charged beyond the debt");
    }

    /// @notice Verifies an oversized request succeeds when the float covers the outstanding legacy debt.
    function test_repay_capsAtDebtBeforeCheckingFloat() public {
        uint256 debt = debtManager.borrowingOf(address(safe), address(USDC));
        deal(address(USDC), address(liquifier), debt);

        vm.prank(etherFiWallet);
        liquifier.repay(address(safe), address(mToken), debt + 10e6, type(uint256).max);
        assertApproxEqAbs(debtManager.borrowingOf(address(safe), address(USDC)), 0, 1, "debt not cleared");
    }

    /// @notice Verifies payment tokens reserved by a pending withdrawal cannot be taken as repayment.
    function test_repay_respectsPendingWithdrawalReservation() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(mToken);
        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;
        vm.prank(owner);
        cashModule.configureWithdrawAssets(tokens, whitelist);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = initialMTokenBalance - 1e18;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // 10 USDC of debt needs about 10.05 payment tokens, but only 1 is left unreserved
        vm.prank(etherFiWallet);
        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        liquifier.repay(address(safe), address(mToken), 10e6, type(uint256).max);
    }

    /// @notice Verifies a pair whose debt token the Safe has never borrowed reverts before any conversion.
    function test_repay_revertsWithoutLegacyDebtInPairToken() public {
        MockERC20 otherDebt = new MockERC20("Other", "OTH", 6);
        vm.prank(owner);
        liquifier.setPair(address(mToken), address(otherDebt), address(redemptionVault), 0, 0);

        vm.prank(etherFiWallet);
        vm.expectRevert(MidasLiquifierModule.AmountZero.selector);
        liquifier.repay(address(safe), address(mToken), 10e6, type(uint256).max);
    }

    /// @notice Verifies full repayment can clear an unhealthy legacy Safe's debt.
    function test_repay_worksWhenSafeIsUnhealthy() public {
        // Crash the collateral factor of weETH so the safe is underwater, then confirm de-risking still goes through.
        vm.prank(owner);
        debtManager.setCollateralTokenConfig(address(weETH), IDebtManager.CollateralTokenConfig({ ltv: 1e18, liquidationThreshold: 2e18, liquidationBonus: 1e18 }));
        vm.expectRevert();
        debtManager.ensureHealth(address(safe));

        vm.prank(etherFiWallet);
        liquifier.repay(address(safe), address(mToken), initialDebtAmount, type(uint256).max);
        assertApproxEqAbs(debtManager.borrowingOf(address(safe), address(USDC)), 0, 1, "debt not cleared");
    }

    /// @notice Verifies legacy repayment reverts when the module has insufficient USDC float.
    function test_repay_revertsWhenFloatInsufficient() public {
        deal(address(USDC), address(liquifier), 0);

        vm.prank(etherFiWallet);
        vm.expectRevert(MidasLiquifierModule.InsufficientFloat.selector);
        liquifier.repay(address(safe), address(mToken), 10e6, type(uint256).max);
    }

    /// @notice Verifies legacy repayment reverts when the Safe has no payment tokens.
    function test_repay_revertsWhenSafeCannotCoverPayment() public {
        deal(address(mToken), address(safe), 0);

        vm.prank(etherFiWallet);
        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        liquifier.repay(address(safe), address(mToken), 10e6, type(uint256).max);
    }
}
