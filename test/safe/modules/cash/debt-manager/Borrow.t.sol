// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { CashModuleTestSetup } from "../CashModuleTestSetup.t.sol";
import { Mode } from "../../../../../src/interfaces/ICashModule.sol";
import { CashVerificationLib } from "../../../../../src/libraries/CashVerificationLib.sol";
import { PriceProvider, IAggregatorV3 } from "../../../../../src/oracle/PriceProvider.sol";
import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";
import { IDebtManager } from "../../../../../src/interfaces/IDebtManager.sol";
import { IEtherFiDataProvider } from "../../../../../src/interfaces/IEtherFiDataProvider.sol";
import { UpgradeableProxy } from "../../../../../src/utils/UpgradeableProxy.sol";
import { MockPriceProvider } from "../../../../../src/mocks/MockPriceProvider.sol";

contract DebtManagerBorrowTest is CashModuleTestSetup {
    using SafeERC20 for IERC20;
    using MessageHashUtils for bytes32;

    uint256 collateralAmount = 0.01 ether;
    uint256 collateralValueInUsdc;

    function setUp() public override {
        super.setUp();

        collateralValueInUsdc = debtManager.convertCollateralTokenToUsd(address(weETHScroll), collateralAmount);

        deal(address(weETHScroll), address(safe), collateralAmount);
        deal(address(usdcScroll), address(debtManager), 1 ether);

        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 msgHash = keccak256(
            abi.encodePacked(
                CashVerificationLib.SET_MODE_METHOD,
                block.chainid,
                address(safe),
                nonce,
                abi.encode(Mode.Credit)
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            owner1Pk,
            msgHash.toEthSignedMessageHash()
        );

        bytes memory signature = abi.encodePacked(r, s, v);
        cashModule.setMode(address(safe), Mode.Credit, owner1, signature);
        vm.warp(cashModule.incomingCreditModeStartTime(address(safe)) + 1);
    }

    // Borrow token support related tests
    function test_supportBorrowToken_succeeds_whenTokenIsValid() public {
        address newBorrowToken = address(new MockERC20("abc", "ABC", 12));
        uint64 borrowApy = 1000;
        uint128 _minShares = 1e12;
        
        vm.startPrank(owner);
        address[] memory _tokens = new address[](1);
        _tokens[0] = address(newBorrowToken);
        
        PriceProvider.Config[] memory _configs = new PriceProvider.Config[](1); 
        _configs[0] = PriceProvider.Config({
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
        priceProvider.setTokenConfig(_tokens, _configs);
        
        IDebtManager.CollateralTokenConfig memory collateralTokenConfig;
        collateralTokenConfig.ltv = ltv;
        collateralTokenConfig.liquidationThreshold = liquidationThreshold;
        collateralTokenConfig.liquidationBonus = liquidationBonus;
        debtManager.supportCollateralToken(
            address(newBorrowToken),
            collateralTokenConfig
        );

        debtManager.supportBorrowToken(newBorrowToken, borrowApy, _minShares);

        assertEq(debtManager.borrowApyPerSecond(newBorrowToken), borrowApy);

        assertEq(debtManager.getBorrowTokens().length, 2);
        assertEq(debtManager.getBorrowTokens()[0], address(usdcScroll));
        assertEq(debtManager.getBorrowTokens()[1], newBorrowToken);

        debtManager.unsupportBorrowToken(newBorrowToken);
        assertEq(debtManager.getBorrowTokens().length, 1);
        assertEq(debtManager.getBorrowTokens()[0], address(usdcScroll));

        vm.stopPrank();
    }

    function test_unsupportBorrowToken_reverts_whenTokenStillInUse() public {
        vm.startPrank(owner);
        vm.expectRevert(IDebtManager.BorrowTokenStillInTheSystem.selector);
        debtManager.unsupportBorrowToken(address(usdcScroll));
        
        vm.stopPrank();
    }

    function test_supportBorrowToken_reverts_whenCallerNotAdmin() public {
        address newBorrowToken = address(new MockERC20("abc", "ABC", 12));

        vm.startPrank(notOwner);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        debtManager.supportBorrowToken(newBorrowToken, 1, 1);

        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        debtManager.unsupportBorrowToken(address(weETHScroll));
        vm.stopPrank();
    }

    function test_supportBorrowToken_reverts_whenTokenAlreadySupported() public {
        vm.startPrank(owner);
        vm.expectRevert(IDebtManager.AlreadyBorrowToken.selector);
        debtManager.supportBorrowToken(address(usdcScroll), 1, 1);
        vm.stopPrank();
    }

    function test_unsupportBorrowToken_reverts_whenTokenNotBorrowToken() public {
        vm.startPrank(owner);
        vm.expectRevert(IDebtManager.NotABorrowToken.selector);
        debtManager.unsupportBorrowToken(address(weETHScroll));
        vm.stopPrank();
    }

    function test_unsupportBorrowToken_reverts_whenLastBorrowToken() public {
        deal(address(usdcScroll), address(debtManager), 0);
        vm.startPrank(owner);
        vm.expectRevert(IDebtManager.NoBorrowTokenLeft.selector);
        debtManager.unsupportBorrowToken(address(usdcScroll));
        vm.stopPrank();
    }

    // Borrow APY related tests
    function test_setBorrowApy_succeeds_whenValidValue() public {
        uint64 apy = 1;
        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true);
        emit IDebtManager.BorrowApySet(address(usdcScroll), borrowApyPerSecond, apy);
        debtManager.setBorrowApy(address(usdcScroll), apy);

        IDebtManager.BorrowTokenConfig memory config = debtManager.borrowTokenConfig(address(usdcScroll));
        assertEq(config.borrowApy, apy);
        vm.stopPrank();
    }

    function test_setBorrowApy_reverts_whenCallerNotAdmin() public {
        vm.startPrank(notOwner);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        debtManager.setBorrowApy(address(usdcScroll), 1);
        vm.stopPrank();
    }

    function test_setBorrowApy_reverts_whenApyIsZero() public {
        vm.startPrank(owner);
        vm.expectRevert(IDebtManager.InvalidValue.selector);
        debtManager.setBorrowApy(address(usdcScroll), 0);
        vm.stopPrank();
    }

    function test_setBorrowApy_reverts_whenTokenNotSupported() public {
        vm.startPrank(owner);
        vm.expectRevert(IDebtManager.UnsupportedBorrowToken.selector);
        debtManager.setBorrowApy(address(weETHScroll), 1);
        vm.stopPrank();
    }

    // Min shares related tests
    function test_setMinBorrowTokenShares_succeeds_whenValidValue() public {
        uint128 shares = 100;
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IDebtManager.MinSharesOfBorrowTokenSet(address(usdcScroll), minShares, shares);
        debtManager.setMinBorrowTokenShares(address(usdcScroll), shares);

        IDebtManager.BorrowTokenConfig memory config = debtManager.borrowTokenConfig(address(usdcScroll));
        assertEq(config.minShares, shares);
    }

    function test_setMinBorrowTokenShares_reverts_whenCallerNotAdmin() public {
        vm.startPrank(notOwner);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        debtManager.setMinBorrowTokenShares(address(usdcScroll), 1);
        vm.stopPrank();
    }

    function test_setMinBorrowTokenShares_reverts_whenSharesIsZero() public {
        vm.startPrank(owner);
        vm.expectRevert(IDebtManager.InvalidValue.selector);
        debtManager.setMinBorrowTokenShares(address(usdcScroll), 0);
        vm.stopPrank();
    }

    function test_setMinBorrowTokenShares_reverts_whenTokenNotSupported() public {
        vm.startPrank(owner);
        vm.expectRevert(IDebtManager.UnsupportedBorrowToken.selector);
        debtManager.setMinBorrowTokenShares(address(weETHScroll), 1);
        vm.stopPrank();
    }

    // Borrow functionality tests
    function test_borrow_succeeds_whenValidAmount() public {
        uint256 totalCanBorrow = debtManager.remainingBorrowingCapacityInUSD(address(safe));
        uint256 borrowAmt = totalCanBorrow / 2;

        (, uint256 totalBorrowingAmountBefore) = debtManager.totalBorrowingAmounts();
        assertEq(totalBorrowingAmountBefore, 0);

        bool isUserLiquidatableBefore = debtManager.liquidatable(address(safe));
        assertEq(isUserLiquidatableBefore, false);

        (, uint256 borrowingOfUserBefore) = debtManager.borrowingOf(address(safe));
        assertEq(borrowingOfUserBefore, 0);

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = borrowAmt;

        vm.startPrank(etherFiWallet);
        cashModule.spend(address(safe), address(0), address(0), txId, spendTokens, spendAmounts, false);

        uint256 borrowInUsdc = debtManager.borrowingOf(address(safe), address(usdcScroll));
        assertApproxEqAbs(borrowInUsdc, borrowAmt, 1);

        (, uint256 totalBorrowingAmountAfter) = debtManager.totalBorrowingAmounts();
        assertApproxEqAbs(totalBorrowingAmountAfter, borrowAmt, 1);

        bool isUserLiquidatableAfter = debtManager.liquidatable(address(safe));
        assertEq(isUserLiquidatableAfter, false);

        (, uint256 borrowingOfUserAfter) = debtManager.borrowingOf(address(safe));
        assertApproxEqAbs(borrowingOfUserAfter, borrowAmt, 1);
    }

    function test_borrow_accumulatesInterest_overTime() public {
        uint256 borrowAmt = debtManager.remainingBorrowingCapacityInUSD(
            address(safe)
        ) / 2;

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = borrowAmt;

        vm.startPrank(etherFiWallet);
        cashModule.spend(address(safe), address(0), address(0), txId, spendTokens, spendAmounts, false);
        vm.stopPrank();

        assertApproxEqAbs(debtManager.borrowingOf(address(safe), address(usdcScroll)), borrowAmt, 1);

        uint256 timeElapsed = 10;

        vm.warp(block.timestamp + timeElapsed);
        uint256 expectedInterest = (borrowAmt * borrowApyPerSecond * timeElapsed) / 1e20;

        assertApproxEqAbs(
            debtManager.borrowingOf(address(safe), address(usdcScroll)),
            borrowAmt + expectedInterest,
            1
        );
    }

    function test_borrow_succeeds_withNonStandardDecimals() public {
        MockERC20 newToken = new MockERC20("mockToken", "MTK", 12);
        deal(address(newToken), address(debtManager), 1 ether);
        uint64 borrowApy = 1000;

        vm.startPrank(owner);

        address[] memory _tokens = new address[](1);
        _tokens[0] = address(newToken);

        PriceProvider.Config[] memory _configs = new PriceProvider.Config[](1); 
        _configs[0] = PriceProvider.Config({
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
        priceProvider.setTokenConfig(_tokens, _configs);
        
        IDebtManager.CollateralTokenConfig memory collateralTokenConfig;
        collateralTokenConfig.ltv = ltv;
        collateralTokenConfig.liquidationThreshold = liquidationThreshold;
        collateralTokenConfig.liquidationBonus = liquidationBonus;
        debtManager.supportCollateralToken(
            address(newToken),
            collateralTokenConfig
        );
        debtManager.supportBorrowToken(address(newToken), borrowApy, 1);

        vm.stopPrank();

        uint256 remainingBorrowCapacityInUsdc = debtManager.remainingBorrowingCapacityInUSD(address(safe));
        (, uint256 totalBorrowingsOfAliceSafe) = debtManager.borrowingOf(address(safe));
        assertEq(totalBorrowingsOfAliceSafe, 0);

        uint256 borrowInToken = (remainingBorrowCapacityInUsdc * 1e12) / 1e6;
        uint256 debtManagerBalBefore = newToken.balanceOf(address(debtManager));

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(newToken);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = remainingBorrowCapacityInUsdc;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), address(0), address(0),  txId, spendTokens, spendAmounts, false);

        (, totalBorrowingsOfAliceSafe) = debtManager.borrowingOf(address(safe));
        assertEq(totalBorrowingsOfAliceSafe, remainingBorrowCapacityInUsdc);
        
        uint256 debtManagerBalAfter = newToken.balanceOf(address(debtManager));
        assertEq(debtManagerBalBefore - debtManagerBalAfter, borrowInToken);
    }

    function test_borrow_addsInterest_onSubsequentBorrows() public {
        uint256 borrowAmt = debtManager.remainingBorrowingCapacityInUSD(
            address(safe)
        ) / 4;

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = borrowAmt;

        vm.startPrank(etherFiWallet);
        cashModule.spend(address(safe), address(0), address(0), txId, spendTokens, spendAmounts, false);

        assertApproxEqAbs(debtManager.borrowingOf(address(safe), address(usdcScroll)), borrowAmt, 1);

        uint256 timeElapsed = 10;

        vm.warp(block.timestamp + timeElapsed);
        uint256 expectedInterest = (borrowAmt *
            borrowApyPerSecond *
            timeElapsed) / 1e20;

        uint256 expectedTotalBorrowWithInterest = borrowAmt + expectedInterest;

        assertApproxEqAbs(
            debtManager.borrowingOf(address(safe), address(usdcScroll)),
            expectedTotalBorrowWithInterest,
            2
        );

        cashModule.spend(address(safe), address(0), address(0), keccak256("newTxId"), spendTokens, spendAmounts, false);

        assertApproxEqAbs(
            debtManager.borrowingOf(address(safe), address(usdcScroll)),
            expectedTotalBorrowWithInterest + borrowAmt,
            2
        );

        vm.stopPrank();
    }

    function test_borrow_reverts_whenTokenNotSupported() public {
        vm.prank(address(safe));        
        vm.expectRevert(IDebtManager.UnsupportedBorrowToken.selector);
        debtManager.borrow(address(weETHScroll), 1);
    }

    function test_borrow_reverts_whenDebtExceedsThreshold() public {
        uint256 totalCanBorrow = debtManager.remainingBorrowingCapacityInUSD(address(safe));
        
        vm.startPrank(address(safe));
        debtManager.borrow(address(usdcScroll), totalCanBorrow);

        vm.expectRevert(IDebtManager.AccountUnhealthy.selector);
        debtManager.borrow(address(usdcScroll), totalCanBorrow);

        vm.stopPrank();
    }

    function test_borrow_reverts_whenInsufficientLiquidity() public {
        deal(address(usdcScroll), address(debtManager), 0);
        vm.startPrank(address(safe));
        vm.expectRevert(IDebtManager.InsufficientLiquidity.selector);
        debtManager.borrow(address(usdcScroll), 10);
        vm.stopPrank();
    }

    function test_borrow_reverts_whenNoCollateral() public {
        deal(address(weETHScroll), address(safe), 0);
        vm.startPrank(address(safe));
        vm.expectRevert(IDebtManager.AccountUnhealthy.selector);
        debtManager.borrow(address(usdcScroll), 10);
        vm.stopPrank();
    }

    function test_borrow_reverts_whenCallerNotSafe() public {
        vm.expectRevert(IDebtManager.OnlyEtherFiSafe.selector);
        debtManager.borrow(address(usdcScroll), 1);
    }

    function test_borrow_reverts_whenAmountIsZero() public {
        vm.startPrank(address(safe));
        vm.expectRevert(IDebtManager.BorrowAmountZero.selector);
        debtManager.borrow(address(usdcScroll), 0);
        vm.stopPrank();
    }

    function test_borrow_succeeds_atExactMaxCapacity() public {
        uint256 maxBorrowCapacity = debtManager.remainingBorrowingCapacityInUSD(address(safe));
        
        vm.startPrank(address(safe));
        debtManager.borrow(address(usdcScroll), maxBorrowCapacity);
        
        // Should be zero remaining capacity
        assertApproxEqAbs(debtManager.remainingBorrowingCapacityInUSD(address(safe)), 0, 1);
        
        // Should not be liquidatable yet
        assertFalse(debtManager.liquidatable(address(safe)));
        vm.stopPrank();
    }

    function test_borrow_accumulatesInterest_overLongPeriod() public {
        uint256 borrowAmt = debtManager.remainingBorrowingCapacityInUSD(address(safe)) / 2;

        vm.startPrank(address(safe));
        debtManager.borrow(address(usdcScroll), borrowAmt);
        vm.stopPrank();

        // Warp one year into the future
        uint256 oneYear = 365 days;
        vm.warp(block.timestamp + oneYear);
        
        // Calculate expected interest over a year
        uint256 expectedInterest = (borrowAmt * borrowApyPerSecond * oneYear) / 1e20;
        
        assertApproxEqAbs(
            debtManager.borrowingOf(address(safe), address(usdcScroll)),
            borrowAmt + expectedInterest,
            10 // Allow for some rounding error
        );
    }

    function test_borrow_multipleUsers_succeeds() public {
        // Setup a second safe
        address safe2 = address(0x456);
        vm.startPrank(owner);
        vm.mockCall(
            address(dataProvider),
            abi.encodeWithSelector(IEtherFiDataProvider.isEtherFiSafe.selector, safe2),
            abi.encode(true)
        );
        vm.stopPrank();
        
        // Give both safes collateral
        deal(address(weETHScroll), address(safe), collateralAmount);
        deal(address(weETHScroll), safe2, collateralAmount);
        
        uint256 maxBorrow1 = debtManager.remainingBorrowingCapacityInUSD(address(safe)) / 2;
        uint256 maxBorrow2 = debtManager.remainingBorrowingCapacityInUSD(safe2) / 2;
        
        // First safe borrows
        vm.prank(address(safe));
        debtManager.borrow(address(usdcScroll), maxBorrow1);
        
        // Second safe borrows
        vm.prank(safe2);
        debtManager.borrow(address(usdcScroll), maxBorrow2);
        
        // Verify both borrowings are tracked correctly
        assertApproxEqAbs(debtManager.borrowingOf(address(safe), address(usdcScroll)), maxBorrow1, 1);
        assertApproxEqAbs(debtManager.borrowingOf(safe2, address(usdcScroll)), maxBorrow2, 1);
        
        // Verify total borrow amount
        (, uint256 totalBorrowingAmount) = debtManager.totalBorrowingAmounts();
        assertApproxEqAbs(totalBorrowingAmount, maxBorrow1 + maxBorrow2, 2);
    }


    function test_borrow_whenCollateralPriceChanges() public {
        priceProvider = PriceProvider(address(new MockPriceProvider(3000e6, address(usdcScroll))));
        
        vm.startPrank(owner);
        dataProvider.setPriceProvider(address(priceProvider));
        vm.stopPrank();

        uint256 initialPrice = priceProvider.price(address(weETHScroll));
        uint256 initialBorrowCapacity = debtManager.remainingBorrowingCapacityInUSD(address(safe));
        
        // Decrease collateral price by 20%
        uint256 newPrice = (initialPrice * 80) / 100;
        MockPriceProvider(address(priceProvider)).setPrice(newPrice);
        
        // Check new capacity is also reduced by approximately 20%
        uint256 expectedNewCapacity = (initialBorrowCapacity * 80) / 100;
        uint256 actualNewCapacity = debtManager.remainingBorrowingCapacityInUSD(address(safe));
        assertApproxEqRel(actualNewCapacity, expectedNewCapacity, 0.01e18); // 1% tolerance
        
        // Try borrowing at the new capacity
        vm.prank(address(safe));
        debtManager.borrow(address(usdcScroll), actualNewCapacity);
        
        // Verify the borrow succeeded
        assertApproxEqAbs(debtManager.borrowingOf(address(safe), address(usdcScroll)), actualNewCapacity, 1);
        
        // Should have close to zero remaining capacity
        assertLe(debtManager.remainingBorrowingCapacityInUSD(address(safe)), 1);
    }
}
