// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { CashModuleTestSetup } from "../CashModuleTestSetup.t.sol";
import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";
import { PriceProvider } from "../../../../../src/oracle/PriceProvider.sol";
import { IAggregatorV3 } from "../../../../../src/interfaces/IAggregatorV3.sol"; 
import { IDebtManager } from "../../../../../src/interfaces/IDebtManager.sol"; 
import { BinSponsor } from "../../../../../src/interfaces/ICashModule.sol"; 

contract DebtManagerInterestIndexTest is CashModuleTestSetup {
    using Math for uint256;

    function test_getCurrentIndex_returnsInitialIndex_whenNoTimeElapsed() public view {
        // Test that the index is equal to the initial value when no time has elapsed
        uint256 initialIndex = debtManager.getCurrentIndex(address(usdcScroll));
        assertEq(initialIndex, PRECISION); // PRECISION is the initial index value
    }

    function test_getCurrentIndex_accumulatesInterest_overTime() public {
        // Capture initial state
        uint256 initialIndex = debtManager.getCurrentIndex(address(usdcScroll));
        uint64 apy = debtManager.borrowApyPerSecond(address(usdcScroll));
        
        // Warp forward in time
        uint256 timeElapsed = 10 days;
        vm.warp(block.timestamp + timeElapsed);
        
        // Calculate expected interest
        uint256 expectedInterest = initialIndex.mulDiv(apy * timeElapsed, HUNDRED_PERCENT);
        uint256 expectedIndex = initialIndex + expectedInterest;
        
        // Get current index and verify
        uint256 currentIndex = debtManager.getCurrentIndex(address(usdcScroll));
        assertEq(currentIndex, expectedIndex);
    }

    function test_getCurrentIndex_updatesCorrectly_afterBorrow() public {
        deal(address(weETHScroll), address(safe), 10 ether);
        // Borrow to trigger an index update
        uint256 borrowAmt = 1000e6; // 1000 USDC
        
        vm.startPrank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdcScroll), borrowAmt);
        vm.stopPrank();
        
        // Get the updated index
        uint256 indexAfterBorrow = debtManager.getCurrentIndex(address(usdcScroll));
        
        // Verify it's equal to PRECISION since no time has passed
        assertEq(indexAfterBorrow, PRECISION);
        
        // Warp forward in time
        uint256 timeElapsed = 30 days;
        vm.warp(block.timestamp + timeElapsed);
        
        // Calculate expected interest
        uint64 apy = debtManager.borrowApyPerSecond(address(usdcScroll));
        uint256 expectedInterest = indexAfterBorrow.mulDiv(apy * timeElapsed, HUNDRED_PERCENT);
        uint256 expectedIndex = indexAfterBorrow + expectedInterest;
        
        // Get current index and verify
        uint256 currentIndex = debtManager.getCurrentIndex(address(usdcScroll));
        assertEq(currentIndex, expectedIndex);
    }

    function test_getCurrentIndex_updatesCorrectly_afterApyChange() public {
        // Capture initial state
        uint256 initialIndex = debtManager.getCurrentIndex(address(usdcScroll));
        uint64 initialApy = debtManager.borrowApyPerSecond(address(usdcScroll));
        
        // Warp forward in time
        uint256 firstTimeElapsed = 10 days;
        vm.warp(block.timestamp + firstTimeElapsed);
        
        // Calculate expected interest for first period
        uint256 firstExpectedInterest = initialIndex.mulDiv(initialApy * firstTimeElapsed, HUNDRED_PERCENT);
        uint256 expectedIndexAfterFirstPeriod = initialIndex + firstExpectedInterest;
        
        // Change the APY as admin
        uint64 newApy = initialApy * 2; // Double the APY
        vm.startPrank(owner);
        debtManager.setBorrowApy(address(usdcScroll), newApy);
        vm.stopPrank();
        
        // Get index right after APY change
        uint256 indexAfterApyChange = debtManager.getCurrentIndex(address(usdcScroll));
        
        // Verify the index was properly updated before the APY change
        assertEq(indexAfterApyChange, expectedIndexAfterFirstPeriod);
        
        // Warp forward again
        uint256 secondTimeElapsed = 10 days;
        vm.warp(block.timestamp + secondTimeElapsed);
        
        // Calculate expected interest for second period with new APY
        uint256 secondExpectedInterest = indexAfterApyChange.mulDiv(newApy * secondTimeElapsed, HUNDRED_PERCENT);
        uint256 expectedFinalIndex = indexAfterApyChange + secondExpectedInterest;
        
        // Get the final index and verify
        uint256 finalIndex = debtManager.getCurrentIndex(address(usdcScroll));
        assertEq(finalIndex, expectedFinalIndex);
    }

    function test_getCurrentIndex_worksCorrectly_withExtremeValues() public {
        // Test with extremely high APY
        uint64 highApy = debtManager.MAX_BORROW_APY(); // Use the maximum allowed APY
        
        vm.startPrank(owner);
        debtManager.setBorrowApy(address(usdcScroll), highApy);
        vm.stopPrank();
        
        uint256 indexBeforeTimeJump = debtManager.getCurrentIndex(address(usdcScroll));
        
        // Warp forward a very long time
        uint256 longTimeElapsed = 365 days;
        vm.warp(block.timestamp + longTimeElapsed);
        
        // Get current index with extreme values
        uint256 indexAfterLongTime = debtManager.getCurrentIndex(address(usdcScroll));
        
        // Calculate expected interest (manually to avoid overflows)
        uint256 expectedInterest = indexBeforeTimeJump.mulDiv(highApy * longTimeElapsed, HUNDRED_PERCENT);
        uint256 expectedIndex = indexBeforeTimeJump + expectedInterest;
        
        // Verify the index calculation handles extreme values correctly
        assertEq(indexAfterLongTime, expectedIndex);
    }

    function test_getCurrentIndex_forMultipleTokens() public {
        // Set up a second borrow token with different APY
        address newToken = address(new MockERC20("Token2", "TK2", 18));
        uint64 differentApy = borrowApyPerSecond * 2; // Different APY
        
        vm.startPrank(owner);
        
        // Configure token in price provider
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
            isStableToken: true,
            isBaseTokenBtc: false
        });
        
        priceProvider.setTokenConfig(tokens, configs);
        
        // Add token as collateral and borrow token
        IDebtManager.CollateralTokenConfig memory collateralConfig;
        collateralConfig.ltv = ltv;
        collateralConfig.liquidationThreshold = liquidationThreshold;
        collateralConfig.liquidationBonus = liquidationBonus;
        
        debtManager.supportCollateralToken(newToken, collateralConfig);
        debtManager.supportBorrowToken(newToken, differentApy, minShares);
        
        vm.stopPrank();
        
        // Warp forward
        uint256 timeElapsed = 30 days;
        vm.warp(block.timestamp + timeElapsed);
        
        // Get indices for both tokens
        uint256 usdcIndex = debtManager.getCurrentIndex(address(usdcScroll));
        uint256 newTokenIndex = debtManager.getCurrentIndex(newToken);
        
        // Calculate expected indices
        uint256 expectedUsdcInterest = PRECISION.mulDiv(borrowApyPerSecond * timeElapsed, HUNDRED_PERCENT);
        uint256 expectedNewTokenInterest = PRECISION.mulDiv(differentApy * timeElapsed, HUNDRED_PERCENT);
        
        uint256 expectedUsdcIndex = PRECISION + expectedUsdcInterest;
        uint256 expectedNewTokenIndex = PRECISION + expectedNewTokenInterest;
        
        // Verify different tokens have different indices based on their APYs
        assertEq(usdcIndex, expectedUsdcIndex);
        assertEq(newTokenIndex, expectedNewTokenIndex);
        
        // The new token should have approximately twice the interest of USDC
        assertEq(newTokenIndex - PRECISION, 2 * (usdcIndex - PRECISION));
    }
}