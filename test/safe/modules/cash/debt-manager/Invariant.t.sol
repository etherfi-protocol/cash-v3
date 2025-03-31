// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { CashModuleTestSetup, IERC20 } from "../CashModuleTestSetup.t.sol"; // Assuming a base test file exists;
import { IDebtManager } from "../../../../../src/interfaces/IDebtManager.sol";
import { IEtherFiSafe } from "../../../../../src/interfaces/IEtherFiSafe.sol";
import { IAggregatorV3 } from "../../../../../src/interfaces/IAggregatorV3.sol";
import { Mode } from "../../../../../src/interfaces/ICashModule.sol";
import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";
import { PriceProvider } from "../../../../../src/oracle/PriceProvider.sol";
import { CashVerificationLib } from "../../../../../src/libraries/CashVerificationLib.sol";

contract DebtManagerInvariantTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;

    IEtherFiSafe[] public safes;
    address public borrowToken;
    uint256 public constant INITIAL_COLLATERAL_IN_WEETH = 10 ether;
    uint256 public constant BORROW_AMOUNT = 1000e6; // 1000 USDC (6 decimals)
    
    function setUp() public override {
        super.setUp();
        
        for (uint256 i = 0; i < 5; i++) {
            address[] memory owners = new address[](1);
            owners[0] = owner1;

            address[] memory modules = new address[](1);
            modules[0] = address(cashModule);

            bytes[] memory modulesSetupData = new bytes[](1);
            modulesSetupData[0] = abi.encode(dailyLimitInUsd, monthlyLimitInUsd, timezoneOffset);

            threshold = 1;
            bytes32 salt = keccak256(abi.encodePacked("borrower", i));

            vm.startPrank(owner);
            safeFactory.deployEtherFiSafe(salt, owners, modules, modulesSetupData, threshold);
            vm.stopPrank();

            address deployedSafe = safeFactory.getDeterministicAddress(salt);
            safes.push(IEtherFiSafe(deployedSafe));
            
            // Setup borrower with sufficient collateral
            deal(address(weETHScroll), deployedSafe, INITIAL_COLLATERAL_IN_WEETH);
            
            uint256 nonce = cashModule.getNonce(address(deployedSafe));
            bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.SET_MODE_METHOD, block.chainid, address(deployedSafe), nonce, abi.encode(Mode.Credit))).toEthSignedMessageHash();

            (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
            bytes memory signature = abi.encodePacked(r, s, v);

            cashModule.setMode(address(deployedSafe), Mode.Credit, owner1, signature);
        }
        
        // warp the time forward so everyone is in the credit mode
        ( , , uint64 modeDelay) = cashModule.getDelays();
        vm.warp(block.timestamp + modeDelay + 1);
        
        borrowToken = address(usdcScroll);
        deal(borrowToken, address(debtManager), 1 ether); 
    }
    
    function test_invariant_totalBorrowEqualsUserBorrows() public {
        // This test checks that the total borrowed amount always equals the sum of all user's borrowed amounts
        // even as interest accrues and as users borrow at different times
        
        // Have each user borrow with different time gaps between borrows
        for (uint256 i = 0; i < safes.length; i++) {
            vm.startPrank(address(safes[i]));
            debtManager.borrow(borrowToken, BORROW_AMOUNT);
            vm.stopPrank();
            
            // Fast forward time between borrows to accrue interest differently
            vm.warp(block.timestamp + (i + 1) * 1 days);
        }
        
        // Fast forward more time to ensure interest has accrued significantly
        vm.warp(block.timestamp + 30 days);
        
        // Calculate the sum of all individual borrowings
        uint256 sumOfUserBorrows = 0;
        for (uint256 i = 0; i < safes.length; i++) {
            uint256 userBorrow = debtManager.borrowingOf(address(safes[i]), borrowToken);
            sumOfUserBorrows += userBorrow;
        }
        
        // Get the total borrowing amount from the contract
        uint256 totalBorrowed = debtManager.totalBorrowingAmount(borrowToken);
        
        // Verify the invariant: total borrowed equals sum of user borrows
        assertApproxEqAbs(totalBorrowed, sumOfUserBorrows, safes.length, "Total borrow amount should equal sum of all user borrows");
        
        // Additional verification: try an extra borrow after significant time has passed
        vm.startPrank(address(safes[0]));
        debtManager.borrow(borrowToken, BORROW_AMOUNT);
        vm.stopPrank();
        
        // Recalculate and verify the invariant again
        sumOfUserBorrows = 0;
        for (uint256 i = 0; i < safes.length; i++) {
            uint256 userBorrow = debtManager.borrowingOf(address(safes[i]), borrowToken);
            sumOfUserBorrows += userBorrow;
        }
        
        totalBorrowed = debtManager.totalBorrowingAmount(borrowToken);
        assertApproxEqAbs(totalBorrowed, sumOfUserBorrows, safes.length, "Total borrow amount should equal sum of all user borrows after additional borrow");
    }
    
    function test_invariant_totalBorrowEqualsUserBorrows_withRepayments() public {
        // This test is similar to the previous one but includes repayments
        
        // First have each user borrow
        for (uint256 i = 0; i < safes.length; i++) {
            vm.startPrank(address(safes[i]));
            debtManager.borrow(borrowToken, BORROW_AMOUNT);
            vm.stopPrank();
            
            // Fast forward time between borrows
            vm.warp(block.timestamp + (i + 1) * 1 days);
        }
        
        // Fast forward more time
        vm.warp(block.timestamp + 10 days);
        
        // Have some users repay partial amounts
        for (uint256 i = 0; i < 3; i++) {
            // Mint tokens to the user for repayment
            deal(borrowToken, address(safes[i]), BORROW_AMOUNT / 2);
            
            vm.startPrank(address(safes[i]));
            IERC20(borrowToken).approve(address(debtManager), BORROW_AMOUNT / 2);
            debtManager.repay(address(safes[i]), borrowToken, BORROW_AMOUNT / 2);
            vm.stopPrank();
            
            // Fast forward time between repayments
            vm.warp(block.timestamp + 5 days);
        }
        
        // Calculate the sum of all individual borrowings
        uint256 sumOfUserBorrows = 0;
        for (uint256 i = 0; i < safes.length; i++) {
            uint256 userBorrow = debtManager.borrowingOf(address(safes[i]), borrowToken);
            sumOfUserBorrows += userBorrow;
        }
        
        // Get the total borrowing amount from the contract
        uint256 totalBorrowed = debtManager.totalBorrowingAmount(borrowToken);
        
        // Verify the invariant: total borrowed equals sum of user borrows
        assertApproxEqAbs(totalBorrowed, sumOfUserBorrows, safes.length, "Total borrow amount should equal sum of all user borrows after repayments");
    }
    
    function test_invariant_totalBorrowEqualsUserBorrows_withMultipleTokens() public {
        // This test checks the invariant across multiple borrow tokens
        
        // Add a second borrow token
        MockERC20 secondToken = new MockERC20("Second Token", "ST2", 18);

        _configureSecondToken(secondToken);

        deal(address(secondToken), address(debtManager), 1000_000 ether);

        uint256 secondTokenBorrowAmt = 1 ether;
        
        // For each borrower, borrow both tokens at different times
        for (uint256 i = 0; i < safes.length; i++) {
            vm.startPrank(address(safes[i]));
            
            // Borrow first token
            debtManager.borrow(borrowToken, BORROW_AMOUNT);
            
            // Warp time
            vm.warp(block.timestamp + 1 days);
            
            // Borrow second token
            debtManager.borrow(address(secondToken), secondTokenBorrowAmt); // Different amount
            
            vm.stopPrank();
            
            // Fast forward time between address(safes
            vm.warp(block.timestamp + 5 days);
        }
        
        // Fast forward more time
        vm.warp(block.timestamp + 30 days);
        
        // Check invariant for first token
        uint256 sumOfUserBorrowsToken1 = 0;
        for (uint256 i = 0; i < safes.length; i++) {
            uint256 userBorrow = debtManager.borrowingOf(address(safes[i]), borrowToken);
            sumOfUserBorrowsToken1 += userBorrow;
        }
        
        uint256 totalBorrowedToken1 = debtManager.totalBorrowingAmount(borrowToken);
        assertApproxEqAbs(totalBorrowedToken1, sumOfUserBorrowsToken1, safes.length, "Total borrow amount for token 1 should equal sum of all user borrows");
        
        // Check invariant for second token
        uint256 sumOfUserBorrowsToken2 = 0;
        for (uint256 i = 0; i < safes.length; i++) {
            uint256 userBorrow = debtManager.borrowingOf(address(safes[i]), address(secondToken));
            sumOfUserBorrowsToken2 += userBorrow;
        }
        
        uint256 totalBorrowedToken2 = debtManager.totalBorrowingAmount(address(secondToken));
        assertApproxEqAbs(totalBorrowedToken2, sumOfUserBorrowsToken2, safes.length, "Total borrow amount for token 2 should equal sum of all user borrows");
    }

    function _configureSecondToken(MockERC20 token) internal {
        vm.startPrank(owner);
        PriceProvider.Config memory priceConfig = PriceProvider.Config({
            oracle: usdcUsdOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(usdcUsdOracle).decimals(),
            maxStaleness: type(uint24).max,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: true,
            isBaseTokenBtc: false
        });
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);

        PriceProvider.Config[] memory configs = new PriceProvider.Config[](1);
        configs[0] = priceConfig;

        priceProvider.setTokenConfig(tokens, configs);

        IDebtManager.CollateralTokenConfig memory collateralConfig = IDebtManager.CollateralTokenConfig({
            ltv: ltv,
            liquidationThreshold: liquidationThreshold,
            liquidationBonus: liquidationBonus
        });

        debtManager.supportCollateralToken(address(token),  collateralConfig);
        debtManager.supportBorrowToken(address(token),  borrowApyPerSecond,  uint128(10 * 10 ** token.decimals()));
        vm.stopPrank();
    }
}