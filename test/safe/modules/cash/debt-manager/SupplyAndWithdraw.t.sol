// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { CashModuleTestSetup } from "../CashModuleTestSetup.t.sol";
import { Mode, BinSponsor, Cashback } from "../../../../../src/interfaces/ICashModule.sol";
import { CashVerificationLib } from "../../../../../src/libraries/CashVerificationLib.sol";
import { MockPriceProvider } from "../../../../../src/mocks/MockPriceProvider.sol";
import { PriceProvider, IAggregatorV3 } from "../../../../../src/oracle/PriceProvider.sol";
import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";
import { IDebtManager } from "../../../../../src/interfaces/IDebtManager.sol";
import { UpgradeableProxy } from "../../../../../src/utils/UpgradeableProxy.sol";

contract DebtManagerSupplyAndWithdrawTest is CashModuleTestSetup {
    using SafeERC20 for IERC20;
    using MessageHashUtils for bytes32;

    uint256 collateralAmt = 0.01 ether;
    IERC20 weth;

    function setUp() public override {
        super.setUp();

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
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        weth = IERC20(chainConfig.weth);

        deal(address(weETHScroll), address(safe), collateralAmt);

        // remove all supplies from debt manager
        vm.startPrank(owner);
        debtManager.withdrawBorrowToken(address(usdcScroll), debtManager.supplierBalance(owner, address(usdcScroll)));
        vm.stopPrank();
    }

    function test_view_functions() public {
        uint128 minSharesWeETH = 0.000001 ether;
        // support weETH as borrow token 
        vm.prank(owner);
        debtManager.supportBorrowToken(address(weETHScroll), borrowApyPerSecond, minSharesWeETH);
        
        deal(address(usdcScroll), notOwner, 1 ether);
        deal(address(weETHScroll), notOwner, 1 ether);

        uint256 principle = 0.01 ether;

        vm.startPrank(notOwner);
        usdcScroll.approve(address(debtManager), 1 ether);
        weETHScroll.approve(address(debtManager), 1 ether);
        debtManager.supply(notOwner, address(usdcScroll), principle);
        debtManager.supply(notOwner, address(weETHScroll), principle);
        vm.stopPrank();

        assertApproxEqAbs(debtManager.supplierBalance(notOwner, address(usdcScroll)), principle, 1);
        assertApproxEqAbs(debtManager.supplierBalance(notOwner, address(weETHScroll)), principle, 1);

        assertApproxEqAbs(debtManager.totalSupplies(address(usdcScroll)), principle, 1);
        assertApproxEqAbs(debtManager.totalSupplies(address(weETHScroll)), principle, 1);

        assertEq(debtManager.borrowTokenMinShares(address(usdcScroll)), minShares);
        assertEq(debtManager.borrowTokenMinShares(address(weETHScroll)), minSharesWeETH);

        (IDebtManager.TokenData[] memory tokenData, uint256 totalSuppliesInUsd) = debtManager.supplierBalance(notOwner);

        assertEq(tokenData.length, 2);
        assertEq(tokenData[0].token, address(usdcScroll));
        assertApproxEqAbs(tokenData[0].amount, principle, 1);
        assertEq(tokenData[1].token, address(weETHScroll));
        assertApproxEqAbs(tokenData[1].amount, principle, 1);

        uint256 totalSupplied = debtManager.convertCollateralTokenToUsd(address(usdcScroll), principle) + debtManager.convertCollateralTokenToUsd(address(weETHScroll), principle);

        assertApproxEqAbs(totalSuppliesInUsd, totalSupplied, 1);

        assertEq(debtManager.getDebtManagerAdmin(), debtManagerAdminImpl);   
        
        (IDebtManager.TokenData[] memory borrowings, uint256 totalBorrowingsInUsd, IDebtManager.TokenData[] memory totalLiquidStableAmounts) = debtManager.getCurrentState();
        assertEq(borrowings.length, 0);
        assertEq(totalBorrowingsInUsd, 0);
        assertEq(totalLiquidStableAmounts.length, 2);
        assertEq(totalLiquidStableAmounts[0].token, address(usdcScroll));
        assertApproxEqAbs(totalLiquidStableAmounts[0].amount, principle, 1);
        assertEq(totalLiquidStableAmounts[1].token, address(weETHScroll));
        assertApproxEqAbs(totalLiquidStableAmounts[1].amount, principle, 1);

        Cashback[] memory cashbacks;

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = 1e6;

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);


        (borrowings, totalBorrowingsInUsd, totalLiquidStableAmounts) = debtManager.getCurrentState();
        assertEq(borrowings.length, 1);
        assertEq(borrowings[0].token, spendTokens[0]);
        assertApproxEqAbs(borrowings[0].amount, spendAmounts[0], 1);
        assertApproxEqAbs(totalBorrowingsInUsd, spendAmounts[0], 1);

        assertEq(totalLiquidStableAmounts.length, 2);
        assertEq(totalLiquidStableAmounts[0].token, address(usdcScroll));
        assertApproxEqAbs(totalLiquidStableAmounts[0].amount, principle - spendAmounts[0], 1);
        assertEq(totalLiquidStableAmounts[1].token, address(weETHScroll));
        assertApproxEqAbs(totalLiquidStableAmounts[1].amount, principle, 1);
    }

    function test_supply_andWithdraw_succeeds() public {
        deal(address(usdcScroll), notOwner, 1 ether);
        uint256 principle = 0.01 ether;

        vm.startPrank(notOwner);
        IERC20(address(usdcScroll)).forceApprove(address(debtManager), principle);

        vm.expectEmit(true, true, true, true);
        emit IDebtManager.Supplied(notOwner, notOwner, address(usdcScroll), principle);
        debtManager.supply(notOwner, address(usdcScroll), principle);
        vm.stopPrank();

        assertApproxEqAbs(debtManager.supplierBalance(notOwner, address(usdcScroll)), principle, 1);

        uint256 earnings = _borrowAndRepay();

        assertApproxEqAbs(debtManager.supplierBalance(notOwner, address(usdcScroll)), principle + earnings, 1);

        vm.prank(notOwner);
        debtManager.withdrawBorrowToken(address(usdcScroll), principle + earnings);

        assertEq(debtManager.supplierBalance(notOwner, address(usdcScroll)), 0);
    }

    function test_withdrawBorrowToken_reverts_whenWithdrawingLessThanMinShares() public {
        deal(address(usdcScroll), notOwner, 1 ether);
        uint256 principle = debtManager.borrowTokenConfig(address(usdcScroll)).minShares;

        vm.startPrank(notOwner);
        IERC20(address(usdcScroll)).forceApprove(address(debtManager), principle);
 
        vm.expectEmit(true, true, true, true);
        emit IDebtManager.Supplied(notOwner, notOwner, address(usdcScroll), principle);
        debtManager.supply(notOwner, address(usdcScroll), principle);
        vm.stopPrank();

        assertEq(
            debtManager.supplierBalance(notOwner, address(usdcScroll)),
            principle
        );

        vm.prank(notOwner);
        vm.expectRevert(IDebtManager.SharesCannotBeLessThanMinShares.selector);
        debtManager.withdrawBorrowToken(address(usdcScroll), principle - 1);
    }

    function test_supply_succeeds_with18DecimalTokenMultipleSuppliers() public {
        address[] memory borrowTokens = new address[](1);
        borrowTokens[0] = address(usdcScroll);

        vm.startPrank(owner);
        address[] memory _tokens = new address[](1);
        _tokens[0] = address(weth);
            
        PriceProvider.Config[] memory _configs = new PriceProvider.Config[](1); 
        _configs[0] = PriceProvider.Config({
            oracle: ethUsdcOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(ethUsdcOracle).decimals(),
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
            address(weth),
            collateralTokenConfig
        );

        debtManager.supportBorrowToken(
            address(weth), 
            borrowApyPerSecond, 
            uint128(1 * 10 ** IERC20Metadata(address(weth)).decimals())
        );
        vm.stopPrank();

        uint256 principle = 1 ether;
        deal(address(weth), notOwner, principle);

        vm.startPrank(notOwner);
        IERC20(address(weth)).forceApprove(address(debtManager), principle);

        vm.expectEmit(true, true, true, true);
        emit IDebtManager.Supplied(notOwner, notOwner, address(weth), principle);
        debtManager.supply(notOwner, address(weth), principle);
        vm.stopPrank();

        address newSupplier = makeAddr("newSupplier");

        deal(address(weth), newSupplier, principle);
        
        vm.startPrank(newSupplier);
        IERC20(address(weth)).forceApprove(address(debtManager), principle);

        vm.expectEmit(true, true, true, true);
        emit IDebtManager.Supplied(newSupplier, newSupplier, address(weth), principle);
        debtManager.supply(newSupplier, address(weth), principle);
        vm.stopPrank();
    }

    function test_supply_succeeds_withMultipleSuppliers() public {
        deal(address(usdcScroll), notOwner, 1 ether);
        uint256 principle = 0.01 ether;
        vm.startPrank(notOwner);
        IERC20(address(usdcScroll)).forceApprove(address(debtManager), principle);

        vm.expectEmit(true, true, true, true);
        emit IDebtManager.Supplied(notOwner, notOwner, address(usdcScroll), principle);
        debtManager.supply(notOwner, address(usdcScroll), principle);
        vm.stopPrank();

        address newSupplier = makeAddr("newSupplier");

        deal(address(usdcScroll), newSupplier, principle);
        
        vm.startPrank(newSupplier);
        IERC20(address(usdcScroll)).forceApprove(address(debtManager), principle);

        vm.expectEmit(true, true, true, true);
        emit IDebtManager.Supplied(newSupplier, newSupplier, address(usdcScroll), principle);
        debtManager.supply(newSupplier, address(usdcScroll), principle);
        vm.stopPrank();
    }

    function test_supply_reverts_whenTokenNotBorrowToken() public {
        vm.prank(notOwner);
        vm.expectRevert(IDebtManager.UnsupportedBorrowToken.selector);
        debtManager.supply(owner, address(weETHScroll), 1);
    }

    function test_supply_reverts_whenCallerIsEtherFiSafe() public {
        vm.prank(address(safe));
        vm.expectRevert(IDebtManager.EtherFiSafeCannotSupplyDebtTokens.selector);
        debtManager.supply(address(safe), address(usdcScroll), 1);
    }

    function test_withdrawBorrowToken_reverts_whenTokenNotSupplied() public {
        vm.prank(notOwner);
        vm.expectRevert(IDebtManager.ZeroTotalBorrowTokens.selector);
        debtManager.withdrawBorrowToken(address(weETHScroll), 1 ether);
    }

    function test_withdrawBorrowToken_reverts_whenAmountIsZero() public {
        deal(address(usdcScroll), notOwner, 1 ether);
        uint256 principle = 0.01 ether;
        
        vm.startPrank(notOwner);
        IERC20(address(usdcScroll)).forceApprove(address(debtManager), principle);
        debtManager.supply(notOwner, address(usdcScroll), principle);
        
        vm.expectRevert(IDebtManager.SharesCannotBeZero.selector); 
        debtManager.withdrawBorrowToken(address(usdcScroll), 0);
        vm.stopPrank();
    }

    function test_withdrawBorrowToken_reverts_whenWithdrawingMoreThanSupplied() public {
        deal(address(usdcScroll), notOwner, 1 ether);
        uint256 principle = 0.01 ether;
        
        vm.startPrank(notOwner);
        IERC20(address(usdcScroll)).forceApprove(address(debtManager), principle);
        debtManager.supply(notOwner, address(usdcScroll), principle);
        
        // Try to withdraw more than supplied
        vm.expectRevert(IDebtManager.InsufficientBorrowShares.selector);
        debtManager.withdrawBorrowToken(address(usdcScroll), principle * 2);
        vm.stopPrank();
    }

    function test_supply_onBehalfOfOtherUser_succeeds() public {
        address beneficiary = makeAddr("beneficiary");
        deal(address(usdcScroll), notOwner, 1 ether);
        uint256 principle = 0.01 ether;
        
        vm.startPrank(notOwner);
        IERC20(address(usdcScroll)).forceApprove(address(debtManager), principle);
        
        vm.expectEmit(true, true, true, true);
        emit IDebtManager.Supplied(notOwner, beneficiary, address(usdcScroll), principle);
        debtManager.supply(beneficiary, address(usdcScroll), principle);
        vm.stopPrank();
        
        // Verify beneficiary received the supplied tokens, not the sender
        assertApproxEqAbs(debtManager.supplierBalance(beneficiary, address(usdcScroll)), principle, 1);
        assertEq(debtManager.supplierBalance(notOwner, address(usdcScroll)), 0);
    }

    function test_multipleSuppliers_receiveProportionalInterest() public {
        // Setup two suppliers with different amounts
        address supplier1 = makeAddr("supplier1");
        address supplier2 = makeAddr("supplier2");
        uint256 amount1 = 0.01 ether;
        uint256 amount2 = 2 * amount1; // Supplier2 adds twice as much
        
        deal(address(usdcScroll), supplier1, amount1);
        deal(address(usdcScroll), supplier2, amount2);
        
        // Supplier 1 adds funds
        vm.startPrank(supplier1);
        IERC20(address(usdcScroll)).forceApprove(address(debtManager), amount1);
        debtManager.supply(supplier1, address(usdcScroll), amount1);
        vm.stopPrank();
        
        // Supplier 2 adds funds
        vm.startPrank(supplier2);
        IERC20(address(usdcScroll)).forceApprove(address(debtManager), amount2);
        debtManager.supply(supplier2, address(usdcScroll), amount2);
        vm.stopPrank();
        
        // Record initial balances
        uint256 initialBalance1 = debtManager.supplierBalance(supplier1, address(usdcScroll));
        uint256 initialBalance2 = debtManager.supplierBalance(supplier2, address(usdcScroll));
        
        // Generate some interest by borrowing and repaying
        _borrowAndRepay();
        
        // Check final balances
        uint256 finalBalance1 = debtManager.supplierBalance(supplier1, address(usdcScroll));
        uint256 finalBalance2 = debtManager.supplierBalance(supplier2, address(usdcScroll));
        
        uint256 earned1 = finalBalance1 - initialBalance1;
        uint256 earned2 = finalBalance2 - initialBalance2;
        
        // Supplier2 should earn twice as much interest as supplier1
        assertApproxEqRel(earned2, earned1 * 2, 0.01e18); // 1% tolerance
    }

    function _borrowAndRepay() internal returns (uint256) {
        vm.startPrank(etherFiWallet);

        uint256 borrowAmt = debtManager.remainingBorrowingCapacityInUSD(address(safe)) / 2;
        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = borrowAmt;

        Cashback[] memory cashbacks;

        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        // 1 day after, there should be some interest accumulated
        vm.warp(block.timestamp + 24 * 60 * 60);
        uint256 repayAmt = debtManager.borrowingOf(address(safe), address(usdcScroll));
        deal(address(usdcScroll), address(safe), repayAmt);
        cashModule.repay(address(safe), address(usdcScroll), repayAmt);
        vm.stopPrank();

        return repayAmt - borrowAmt;
    }
}