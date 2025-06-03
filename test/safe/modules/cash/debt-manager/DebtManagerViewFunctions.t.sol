// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { CashModuleTestSetup } from "../CashModuleTestSetup.t.sol";
import { Mode, BinSponsor } from "../../../../../src/interfaces/ICashModule.sol";
import { CashVerificationLib } from "../../../../../src/libraries/CashVerificationLib.sol";
import { MockPriceProvider } from "../../../../../src/mocks/MockPriceProvider.sol";
import { PriceProvider, IAggregatorV3 } from "../../../../../src/oracle/PriceProvider.sol";
import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";
import { IDebtManager } from "../../../../../src/interfaces/IDebtManager.sol";

contract DebtManagerViewFunctionTests is CashModuleTestSetup {
    using SafeERC20 for IERC20;
    using MessageHashUtils for bytes32;

    uint256 collateralAmount = 0.01 ether;
    uint256 borrowAmt;

    function setUp() public override {
        super.setUp();

        // remove all supplies from debt manager
        vm.startPrank(owner);
        debtManager.withdrawBorrowToken(address(usdcScroll), debtManager.supplierBalance(owner, address(usdcScroll)));
        vm.stopPrank();

        // Setup for credit mode
        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);

        // Add collateral and supply tokens
        deal(address(weETHScroll), address(safe), collateralAmount);
        deal(address(usdcScroll), address(owner), 1000e6);
        
        vm.startPrank(owner);
        IERC20(address(usdcScroll)).approve(address(debtManager), 1000e6);
        debtManager.supply(owner, address(usdcScroll), 1000e6);
        vm.stopPrank();

        // Setup a borrow amount
        borrowAmt = debtManager.remainingBorrowingCapacityInUSD(address(safe)) / 2;
    }

    // Test getUserCollateralForToken external function
    function test_getUserCollateralForToken() public view {
        (uint256 tokenAmount, uint256 usdAmount) = debtManager.getUserCollateralForToken(address(safe), address(weETHScroll));
        
        // Verify returned amounts
        assertEq(tokenAmount, collateralAmount, "Token amount should match the collateral amount");
        uint256 expectedUsdAmount = debtManager.convertCollateralTokenToUsd(address(weETHScroll), collateralAmount);
        assertEq(usdAmount, expectedUsdAmount, "USD amount should match the converted collateral value");
    }

    // Test getUserCollateralForToken with unsupported token
    function test_getUserCollateralForToken_reverts_withUnsupportedToken() public {
        address unsupportedToken = makeAddr("unsupportedToken");
        
        vm.expectRevert(IDebtManager.UnsupportedCollateralToken.selector);
        debtManager.getUserCollateralForToken(address(safe), unsupportedToken);
    }

    // Test getUserCurrentState comprehensive function
    function test_getUserCurrentState() public {
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = borrowAmt;

        // Borrow some tokens first to have both collateral and borrows
        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), address(0), txId, BinSponsor.Reap, spendTokens, spendAmounts, false);
        
        // Get user state
        (
            IDebtManager.TokenData[] memory totalCollaterals,
            uint256 totalCollateralInUsd,
            IDebtManager.TokenData[] memory borrowings,
            uint256 totalBorrowings
        ) = debtManager.getUserCurrentState(address(safe));
        
        // Verify collateral data
        assertEq(totalCollaterals.length, 1, "Should have one collateral token");
        assertEq(totalCollaterals[0].token, address(weETHScroll), "Collateral token should be weETHScroll");
        assertEq(totalCollaterals[0].amount, collateralAmount, "Collateral amount should match");
        
        uint256 expectedCollateralInUsd = debtManager.convertCollateralTokenToUsd(address(weETHScroll), collateralAmount);
        assertEq(totalCollateralInUsd, expectedCollateralInUsd, "Total collateral in USD should match");
        
        // Verify borrowing data
        assertEq(borrowings.length, 1, "Should have one borrowed token");
        assertEq(borrowings[0].token, address(usdcScroll), "Borrowed token should be USDC");
        assertApproxEqAbs(borrowings[0].amount, borrowAmt, 1, "Borrowed amount should match");
        assertApproxEqAbs(totalBorrowings, borrowAmt, 1, "Total borrowings should match");
    }

    // Test getCollateralValueInUsd
    function test_getCollateralValueInUsd() public {
        // Test with a single collateral token
        uint256 collateralValue = debtManager.getCollateralValueInUsd(address(safe));
        uint256 expectedValue = debtManager.convertCollateralTokenToUsd(address(weETHScroll), collateralAmount);
        assertEq(collateralValue, expectedValue, "Collateral value should match expected USD value");
        
        // Add a second collateral token
        address newToken = address(new MockERC20("Second", "SEC", 18));
        uint256 newTokenAmount = 5 ether;
        
        // Configure and add token as collateral
        vm.startPrank(owner);
        
        // Configure price provider
        address[] memory tokens = new address[](1);
        tokens[0] = newToken;
        
        PriceProvider.Config[] memory configs = new PriceProvider.Config[](1);
        configs[0] = PriceProvider.Config({
            oracle: usdcUsdOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(usdcUsdOracle).decimals(),
            maxStaleness: 1 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });
        
        priceProvider.setTokenConfig(tokens, configs);
        
        // Add as collateral
        IDebtManager.CollateralTokenConfig memory tokenConfig;
        tokenConfig.ltv = ltv;
        tokenConfig.liquidationThreshold = liquidationThreshold;
        tokenConfig.liquidationBonus = liquidationBonus;
        debtManager.supportCollateralToken(newToken, tokenConfig);
        vm.stopPrank();
        
        // Give safe some of the new token
        deal(newToken, address(safe), newTokenAmount);
        
        // Get updated collateral value
        uint256 newCollateralValue = debtManager.getCollateralValueInUsd(address(safe));
        uint256 newTokenValue = debtManager.convertCollateralTokenToUsd(newToken, newTokenAmount);
        uint256 totalExpectedValue = expectedValue + newTokenValue;
        
        assertEq(newCollateralValue, totalExpectedValue, "Total collateral value should include both tokens");
    }

    // Test ensureHealth function
    function test_ensureHealth_succeeds_whenPositionHealthy() public {
        // Position is initially healthy
        debtManager.ensureHealth(address(safe));
        
        // Borrow some tokens (but less than max)
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdcScroll), borrowAmt);
        
        // Position should still be healthy
        debtManager.ensureHealth(address(safe));
    }
    
    function test_ensureHealth_reverts_whenPositionUnhealthy() public {
        // Borrow maximum amount
        uint256 maxBorrowAmount = debtManager.getMaxBorrowAmount(address(safe), true);
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdcScroll), maxBorrowAmount);
        
        // Manipulate price to make position unhealthy
        MockPriceProvider mockPriceProvider = new MockPriceProvider(1500e6, address(usdcScroll)); // Half the original price
        vm.prank(owner);
        dataProvider.setPriceProvider(address(mockPriceProvider));
        
        // Now the position should be unhealthy
        vm.expectRevert(IDebtManager.AccountUnhealthy.selector);
        debtManager.ensureHealth(address(safe));
    }
    
    // Test getMaxBorrowAmount with both parameter options
    function test_getMaxBorrowAmount_differsByParameter() public view {
        // Get max borrow amount with LTV
        uint256 maxBorrowWithLtv = debtManager.getMaxBorrowAmount(address(safe), true);
        
        // Get max borrow amount with liquidation threshold
        uint256 maxBorrowWithThreshold = debtManager.getMaxBorrowAmount(address(safe), false);
        
        // Liquidation threshold should allow higher borrowing than LTV
        assertGt(maxBorrowWithThreshold, maxBorrowWithLtv, "Threshold should allow higher borrowing than LTV");
        
        // The difference should align with config values
        uint256 collateralValue = debtManager.getCollateralValueInUsd(address(safe));
        uint256 expectedLtvAmount = (collateralValue * ltv) / HUNDRED_PERCENT;
        uint256 expectedThresholdAmount = (collateralValue * liquidationThreshold) / HUNDRED_PERCENT;
        
        assertApproxEqAbs(maxBorrowWithLtv, expectedLtvAmount, 10, "LTV calculation should match");
        assertApproxEqAbs(maxBorrowWithThreshold, expectedThresholdAmount, 10, "Threshold calculation should match");
    }
    
    // Test totalSupplies() for all tokens
    function test_totalSupplies() public {
        // Set up a second borrow token
        MockERC20 secondToken = new MockERC20("Second", "SEC", 18);
        
        vm.startPrank(owner);
        
        // Configure token
        address[] memory tokens = new address[](1);
        tokens[0] = address(secondToken);
        
        PriceProvider.Config[] memory configs = new PriceProvider.Config[](1);
        configs[0] = PriceProvider.Config({
            oracle: usdcUsdOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(usdcUsdOracle).decimals(),
            maxStaleness: 1 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: true,
            isBaseTokenBtc: false
        });
        
        priceProvider.setTokenConfig(tokens, configs);
        
        // Add as collateral and borrow token
        IDebtManager.CollateralTokenConfig memory tokenConfig;
        tokenConfig.ltv = ltv;
        tokenConfig.liquidationThreshold = liquidationThreshold;
        tokenConfig.liquidationBonus = liquidationBonus;
        debtManager.supportCollateralToken(address(secondToken), tokenConfig);
        debtManager.supportBorrowToken(address(secondToken), borrowApyPerSecond, uint128(10 * 10 ** secondToken.decimals()));
        
        // Supply some of the new token
        uint256 secondTokenAmount = 10 ether;
        deal(address(secondToken), owner, secondTokenAmount);
        secondToken.approve(address(debtManager), secondTokenAmount);
        debtManager.supply(owner, address(secondToken), secondTokenAmount);
        vm.stopPrank();
        
        // Get total supplies
        (IDebtManager.TokenData[] memory supplies, uint256 totalValueInUsd) = debtManager.totalSupplies();

        // Should have both tokens
        assertEq(supplies.length, 2, "Should have two supplied tokens");
        
        // Check total value
        uint256 usdcValue = debtManager.convertCollateralTokenToUsd(address(usdcScroll), 1000e6);
        uint256 secondTokenValue = debtManager.convertCollateralTokenToUsd(address(secondToken), secondTokenAmount);

        uint256 expectedTotal = usdcValue + secondTokenValue;
        
        assertEq(totalValueInUsd, expectedTotal, "Total USD value should match");
        
        // Verify each token is included
        bool foundUsdc = false;
        bool foundSecondToken = false;
        
        for (uint256 i = 0; i < supplies.length; i++) {
            if (supplies[i].token == address(usdcScroll)) {
                foundUsdc = true;
                assertEq(supplies[i].amount, 1000e6, "USDC amount should match");
            } else if (supplies[i].token == address(secondToken)) {
                foundSecondToken = true;
                assertEq(supplies[i].amount, secondTokenAmount, "Second token amount should match");
            }
        }
        
        assertTrue(foundUsdc, "USDC should be in supplies");
        assertTrue(foundSecondToken, "Second token should be in supplies");
    }
    
    // Test remainingBorrowingCapacityInUSD
    function test_remainingBorrowingCapacityInUSD() public {
        // Initial capacity
        uint256 initialCapacity = debtManager.remainingBorrowingCapacityInUSD(address(safe));
        
        // Borrow half
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdcScroll), initialCapacity / 2);
        
        // Check remaining capacity
        uint256 remainingCapacity = debtManager.remainingBorrowingCapacityInUSD(address(safe));
        assertApproxEqAbs(remainingCapacity, initialCapacity / 2, 2, "Remaining capacity should be half of initial");
        
        // Borrow remaining amount
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdcScroll), remainingCapacity);
        
        // Should have no remaining capacity
        uint256 finalCapacity = debtManager.remainingBorrowingCapacityInUSD(address(safe));
        assertApproxEqAbs(finalCapacity, 0, 1, "Final capacity should be close to zero");
    }
    
    // Test collateralOf with multiple tokens
    function test_collateralOf_withMultipleTokens() public {
        // Add a second collateral token
        address secondToken = address(new MockERC20("Second", "SEC", 18));
        uint256 secondTokenAmount = 5 ether;
        
        // Configure and add token as collateral
        vm.startPrank(owner);
        
        // Configure price provider
        address[] memory tokens = new address[](1);
        tokens[0] = secondToken;
        
        PriceProvider.Config[] memory configs = new PriceProvider.Config[](1);
        configs[0] = PriceProvider.Config({
            oracle: usdcUsdOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(usdcUsdOracle).decimals(),
            maxStaleness: 1 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });
        
        priceProvider.setTokenConfig(tokens, configs);
        
        // Add as collateral
        IDebtManager.CollateralTokenConfig memory tokenConfig;
        tokenConfig.ltv = ltv;
        tokenConfig.liquidationThreshold = liquidationThreshold;
        tokenConfig.liquidationBonus = liquidationBonus;
        debtManager.supportCollateralToken(secondToken, tokenConfig);
        vm.stopPrank();
        
        // Give safe some of the new token
        deal(secondToken, address(safe), secondTokenAmount);
        
        // Get collateral data
        (IDebtManager.TokenData[] memory collateralTokens, uint256 totalCollateralInUsd) = debtManager.collateralOf(address(safe));
        
        // Should have two tokens
        assertEq(collateralTokens.length, 2, "Should have two collateral tokens");
        
        // Check total value
        uint256 weEthValue = debtManager.convertCollateralTokenToUsd(address(weETHScroll), collateralAmount);
        uint256 secondTokenValue = debtManager.convertCollateralTokenToUsd(secondToken, secondTokenAmount);
        uint256 expectedTotal = weEthValue + secondTokenValue;
        
        assertEq(totalCollateralInUsd, expectedTotal, "Total USD value should match");
        
        // Verify each token is included
        bool foundWeEth = false;
        bool foundSecondToken = false;
        
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            if (collateralTokens[i].token == address(weETHScroll)) {
                foundWeEth = true;
                assertEq(collateralTokens[i].amount, collateralAmount, "weETH amount should match");
            } else if (collateralTokens[i].token == secondToken) {
                foundSecondToken = true;
                assertEq(collateralTokens[i].amount, secondTokenAmount, "Second token amount should match");
            }
        }
        
        assertTrue(foundWeEth, "weETH should be in collaterals");
        assertTrue(foundSecondToken, "Second token should be in collaterals");
    }
}