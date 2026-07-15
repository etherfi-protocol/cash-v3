// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { UUPSProxy } from "../../../../../src/UUPSProxy.sol";
import { ModuleCheckBalance } from "../../../../../src/modules/ModuleCheckBalance.sol";
import { LiquidUSDLiquifierOPModule } from "../../../../../src/modules/etherfi/LiquidUSDLiquifierOP.sol";
import { AccountantWithRateProviders, ILayerZeroTeller } from "../../../../../src/interfaces/ILayerZeroTeller.sol";
import { PriceProvider } from "../../../../../src/oracle/PriceProvider.sol";
import { ChainConfig } from "../../../../utils/Utils.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { CashVerificationLib } from "../../../../../src/libraries/CashVerificationLib.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title LiquidUsdLiquifierGatewayTest
 * @notice Exercises the liquifier's gateway repay leg against the real LendGateway: the float hops through
 *         the safe into gateway.repay (capped at the safe's Aave debt), and the LiquidUSD reclaim pulls the
 *         shortfall out of the safe's Aave position, since LiquidUSD is a listed reserve. The legacy
 *         DebtManager twin lives in test/safe/modules/etherfi/LiquidUSDLiquifier.t.sol.
 */
contract LiquidUsdLiquifierGatewayTest is CashGatewayTestSetup {
    using MessageHashUtils for bytes32;

    LiquidUSDLiquifierOPModule internal liquifier;
    IERC20 internal liquidUsd;

    function setUp() public override {
        ChainConfig memory _cc = getChainConfig();
        vm.skip(_cc.liquidUsd == address(0), "Liquid USD does not exist on this chain");

        super.setUp();

        liquidUsd = IERC20(chainConfig.liquidUsd);

        // LiquidUSD is a listed reserve: register it on Aave (the $1 USDC feed is close enough for
        // collateral valuation here) and price it on the PriceProvider via its real accountant rate.
        uint256 liquidUsdReserveId = _addAaveReserve(address(liquidUsd), usdcUsdOracle, _usdcCollateralFactorBps(), false);
        AccountantWithRateProviders accountant = ILayerZeroTeller(chainConfig.liquidUsdTeller).accountant();
        PriceProvider.Config[] memory configs = new PriceProvider.Config[](1);
        configs[0] = PriceProvider.Config({
            oracle: address(accountant),
            priceFunctionCalldata: abi.encodeWithSelector(AccountantWithRateProviders.getRate.selector),
            isChainlinkType: false,
            oraclePriceDecimals: accountant.decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Uint256,
            isBaseTokenEth: false,
            isStableToken: true,
            isBaseTokenBtc: false
        });

        address liquifierImpl = address(new LiquidUSDLiquifierOPModule(address(debtManager), address(dataProvider)));
        liquifier = LiquidUSDLiquifierOPModule(address(new UUPSProxy(liquifierImpl, "")));
        liquifier.initialize(address(roleRegistry));

        vm.startPrank(owner);
        priceProvider.setTokenConfig(_addr1(address(liquidUsd)), configs);
        gw.setReserveId(address(liquidUsd), liquidUsdReserveId);
        // The repay and reclaim legs drive the gateway on the safe's behalf, so the liquifier is a driver.
        gw.setDriver(address(liquifier), true);
        dataProvider.configureDefaultModules(_addr1(address(liquifier)), _bool1(true));
        vm.stopPrank();
    }

    /// @dev Real Aave USDC debt plus the safe's LiquidUSD fully supplied to Aave (as the sweep leaves it).
    function _buildDebtAndSuppliedLiquidUsd(uint256 debtAmount, uint256 liquidUsdSupplied) internal {
        _buildGatewayPosition(address(safe), address(weETH), 1 ether, address(usdc), debtAmount);
        _supplyToGateway(address(safe), address(liquidUsd), liquidUsdSupplied);
        deal(address(usdc), address(liquifier), 1000e6);
    }

    // The repayment/exit path stays open for an effectively opted-out safe: a matured opt-out whose
    // unwind open borrows block leaves LiquidUSD supplied while isLendActive reads false — the reclaim's
    // withdraw bookend is engine-gated (not lend-active-gated), so this deleveraging repayment (the very
    // thing that unblocks the opt-out) still sources the supplied LiquidUSD instead of reverting on the
    // balance check. New supply and borrows stay blocked for the safe.
    function test_repay_worksWhileMaturedOptOutBlockedByDebt() public {
        // Request the opt-out debt-free, borrow during the window (blocking the unwind), then mature it
        _requestOptOut();
        _buildDebtAndSuppliedLiquidUsd(500e6, 1000e6);
        (,, uint64 modeDelay) = cashModule.getDelays();
        vm.warp(block.timestamp + modeDelay + 1);
        assertTrue(cashModule.isLendOptedOut(address(safe)), "effectively opted out");
        assertFalse(cashModule.isLendActive(address(safe)), "lend inactive");

        uint256 usdAmount = 200e6;
        uint256 debtBefore = gw.debtOf(address(safe), address(usdc));
        uint256 expectedLiquidUsd = liquifier.convertUsdToLiquidUSD(usdAmount);

        vm.prank(etherFiWallet);
        liquifier.repayUsingLiquidUSD(address(safe), usdAmount);

        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), debtBefore - usdAmount, 1, "Aave debt not reduced");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(liquidUsd)), 1000e6 - expectedLiquidUsd, 2, "supplied LiquidUSD not reclaimed");
        assertTrue(cashModule.lendOptOutFinalizeTime(address(safe)) != 0, "opt-out still pending until the debt clears");
    }

    function _requestOptOut() internal {
        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.TOGGLE_LEND_METHOD, block.chainid, address(safe), nonce, abi.encode(false))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digest);
        cashModule.toggleLend(address(safe), false, owner1, abi.encodePacked(r, s, v));
    }

    // The repay reduces the safe's Aave debt with the liquifier's float and reclaims the equivalent
    // LiquidUSD, pulling it out of the safe's Aave position since none is loose.
    function test_repay_repaysAaveDebtAndReclaimsSuppliedLiquidUsd() public {
        _buildDebtAndSuppliedLiquidUsd(500e6, 1000e6);

        uint256 usdAmount = 200e6;
        uint256 debtBefore = gw.debtOf(address(safe), address(usdc));
        uint256 liquifierLiquidUsdBefore = liquidUsd.balanceOf(address(liquifier));
        uint256 liquifierUsdcBefore = usdc.balanceOf(address(liquifier));
        uint256 expectedLiquidUsd = liquifier.convertUsdToLiquidUSD(usdAmount);

        vm.prank(etherFiWallet);
        liquifier.repayUsingLiquidUSD(address(safe), usdAmount);

        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), debtBefore - usdAmount, 1, "Aave debt not reduced");
        assertApproxEqAbs(liquifierUsdcBefore - usdc.balanceOf(address(liquifier)), usdAmount, 1, "float not spent by the repaid amount");
        assertApproxEqAbs(liquidUsd.balanceOf(address(liquifier)) - liquifierLiquidUsdBefore, expectedLiquidUsd, 2, "LiquidUSD not reclaimed");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(liquidUsd)), 1000e6 - expectedLiquidUsd, 2, "supplied LiquidUSD not debited");
        assertEq(liquidUsd.balanceOf(address(safe)), 0, "LiquidUSD left loose in safe");
        assertEq(usdc.balanceOf(address(safe)), 0, "USDC left loose in safe");
    }

    // The reclaim consumes the safe's loose LiquidUSD first and pulls only the shortfall out of Aave.
    function test_repay_reclaimsLooseFirstThenSuppliedShortfall() public {
        _buildDebtAndSuppliedLiquidUsd(500e6, 1000e6);
        uint256 loose = 100e6;
        deal(address(liquidUsd), address(safe), loose);

        uint256 expectedLiquidUsd = liquifier.convertUsdToLiquidUSD(200e6);
        assertGt(expectedLiquidUsd, loose, "fixture: reclaim must exceed the loose balance");

        vm.prank(etherFiWallet);
        liquifier.repayUsingLiquidUSD(address(safe), 200e6);

        assertEq(liquidUsd.balanceOf(address(safe)), 0, "loose LiquidUSD not consumed first");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(liquidUsd)), 1000e6 - (expectedLiquidUsd - loose), 2, "only the shortfall should leave Aave");
    }

    // The safe's own loose USDC is not consumed: the gateway pulls exactly the USDC the liquifier deposited,
    // and the reclaim charges LiquidUSD only for the realized debt reduction.
    function test_repay_doesNotTouchSafesOwnLooseUsdc() public {
        _buildDebtAndSuppliedLiquidUsd(500e6, 1000e6);
        uint256 loose = 300e6;
        deal(address(usdc), address(safe), loose);

        uint256 debtBefore = gw.debtOf(address(safe), address(usdc));

        vm.prank(etherFiWallet);
        liquifier.repayUsingLiquidUSD(address(safe), 200e6);

        assertApproxEqAbs(usdc.balanceOf(address(safe)), loose, 1, "safe's own loose USDC was consumed");
        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), debtBefore - 200e6, 1, "debt not reduced by the repaid amount");
    }

    // A reclaim larger than the safe's total LiquidUSD (loose + supplied) refuses rather than under-collecting.
    function test_repay_revertsWhenSafeCannotCoverReclaim() public {
        _buildGatewayPosition(address(safe), address(weETH), 1 ether, address(usdc), 200e6);
        _supplyToGateway(address(safe), address(liquidUsd), 10e6);
        deal(address(usdc), address(liquifier), 1000e6);

        vm.prank(etherFiWallet);
        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        liquifier.repayUsingLiquidUSD(address(safe), 100e6);
    }

    // A repay above the debt is capped at it: the debt clears, the float spends exactly the debt, and no
    // USDC is stranded in the safe by the gateway's dust refund.
    function test_repay_capsAtDebtAndStrandsNoFloat() public {
        _buildDebtAndSuppliedLiquidUsd(100e6, 1000e6);

        uint256 debt = gw.debtOf(address(safe), address(usdc));
        uint256 floatBefore = usdc.balanceOf(address(liquifier));

        vm.prank(etherFiWallet);
        liquifier.repayUsingLiquidUSD(address(safe), 400e6);

        assertEq(gw.debtOf(address(safe), address(usdc)), 0, "Aave debt not cleared");
        assertEq(usdc.balanceOf(address(safe)), 0, "float stranded in safe");
        assertApproxEqAbs(floatBefore - usdc.balanceOf(address(liquifier)), debt, 1, "float spent beyond the debt");
    }

    // With no Aave debt the cap resolves to zero and the repay refuses rather than moving float around.
    function test_repay_revertsOnZeroDebt() public {
        deal(address(usdc), address(liquifier), 1000e6);

        vm.prank(etherFiWallet);
        vm.expectRevert(LiquidUSDLiquifierOPModule.AmountZero.selector);
        liquifier.repayUsingLiquidUSD(address(safe), 100e6);
    }
}
