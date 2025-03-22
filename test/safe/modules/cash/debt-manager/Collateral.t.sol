// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { CashModuleTestSetup } from "../CashModuleTestSetup.t.sol";
import { Mode } from "../../../../../src/interfaces/ICashModule.sol";
import { CashVerificationLib } from "../../../../../src/libraries/CashVerificationLib.sol";
import { MockPriceProvider } from "../../../../../src/mocks/MockPriceProvider.sol";
import { PriceProvider, IAggregatorV3 } from "../../../../../src/oracle/PriceProvider.sol";
import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";
import { IDebtManager } from "../../../../../src/interfaces/IDebtManager.sol";
import { UpgradeableProxy } from "../../../../../src/utils/UpgradeableProxy.sol";

contract DebtManagerCollateralTest is CashModuleTestSetup {
    using SafeERC20 for IERC20;

    uint80 newLtv = 80e18;
    uint80 newLiquidationThreshold = 85e18;
    uint96 newLiquidationBonus = 10e18;
    uint256 mockWeETHPriceInUsd = 3000e6;

    function setUp() public override {
        super.setUp();

        deal(address(usdcScroll), owner, 1 ether);
        deal(address(weETHScroll), owner, 1000 ether);
    }

    function test_setCollateralTokenConfig_reverts_whenLtvGreaterThanLiquidationThreshold() public {
        IDebtManager.CollateralTokenConfig memory collateralTokenConfig;
        collateralTokenConfig.ltv = 90e18;
        collateralTokenConfig.liquidationThreshold = 80e18;

        vm.startPrank(owner);
        vm.expectRevert(
            IDebtManager.LtvCannotBeGreaterThanLiquidationThreshold.selector
        );
        debtManager.setCollateralTokenConfig(address(weETHScroll), collateralTokenConfig);
        vm.stopPrank();
    }

    function test_supportCollateralToken_succeeds_withValidToken() public {
        vm.startPrank(owner);
        address newCollateralToken = address(new MockERC20("CollToken", "CTK", 18));
        
        priceProvider = PriceProvider(
            address(new MockPriceProvider(mockWeETHPriceInUsd, address(usdcScroll)))
        );

        dataProvider.setPriceProvider(address(priceProvider));

        IDebtManager.CollateralTokenConfig memory collateralTokenConfig;
        collateralTokenConfig.ltv = newLtv;
        collateralTokenConfig.liquidationThreshold = newLiquidationThreshold;
        collateralTokenConfig.liquidationBonus = newLiquidationBonus;

        debtManager.supportCollateralToken(
            newCollateralToken,
            collateralTokenConfig
        );

        IDebtManager.CollateralTokenConfig memory configFromContract = debtManager
            .collateralTokenConfig(newCollateralToken);

        assertEq(configFromContract.ltv, newLtv);
        assertEq(configFromContract.liquidationThreshold, newLiquidationThreshold);
        assertEq(configFromContract.liquidationBonus, newLiquidationBonus);
        
        assertEq(debtManager.getCollateralTokens().length, 3);
        assertEq(debtManager.getCollateralTokens()[0], address(weETHScroll));
        assertEq(debtManager.getCollateralTokens()[1], address(usdcScroll));
        assertEq(debtManager.getCollateralTokens()[2], newCollateralToken);

        debtManager.unsupportCollateralToken(address(weETHScroll));
        assertEq(debtManager.getCollateralTokens().length, 2);
        assertEq(debtManager.getCollateralTokens()[0], newCollateralToken);
        assertEq(debtManager.getCollateralTokens()[1], address(usdcScroll));

        IDebtManager.CollateralTokenConfig memory configWethFromContract = debtManager
            .collateralTokenConfig(address(weETHScroll));
        assertEq(configWethFromContract.ltv, 0);
        assertEq(configWethFromContract.liquidationThreshold, 0);
        assertEq(configWethFromContract.liquidationBonus, 0);

        vm.stopPrank();
    }

    function test_supportCollateralToken_reverts_whenCallerNotAdmin() public {
        address newCollateralToken = address(usdcScroll);

        IDebtManager.CollateralTokenConfig memory collateralTokenConfig;
        collateralTokenConfig.ltv = newLtv;
        collateralTokenConfig.liquidationThreshold = newLiquidationThreshold;
        collateralTokenConfig.liquidationBonus = newLiquidationBonus;

        vm.startPrank(notOwner);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        debtManager.supportCollateralToken(newCollateralToken, collateralTokenConfig);
        vm.stopPrank();
    }

    function test_unsupportCollateralToken_reverts_whenCallerNotAdmin() public {
        // Second part of previously: test_OnlyAdminCanSupportOrUnsupportCollateral
        vm.startPrank(notOwner);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        debtManager.unsupportCollateralToken(address(weETHScroll));
        vm.stopPrank();
    }

    function test_unsupportCollateralToken_reverts_whenTokenIsBorrowToken() public {
        vm.startPrank(owner);
        vm.expectRevert(IDebtManager.BorrowTokenCannotBeRemovedFromCollateral.selector);
        debtManager.unsupportCollateralToken(address(usdcScroll));
        vm.stopPrank();
    }

    function test_supportCollateralToken_reverts_whenTokenAlreadySupported() public {
        IDebtManager.CollateralTokenConfig memory collateralTokenConfig;
        collateralTokenConfig.ltv = newLtv;
        collateralTokenConfig.liquidationThreshold = newLiquidationThreshold;
        collateralTokenConfig.liquidationBonus = newLiquidationBonus;

        vm.startPrank(owner);
        vm.expectRevert(IDebtManager.AlreadyCollateralToken.selector);
        debtManager.supportCollateralToken(address(weETHScroll), collateralTokenConfig);
        vm.stopPrank();
    }

    function test_supportCollateralToken_reverts_whenAddressZero() public {
        IDebtManager.CollateralTokenConfig memory collateralTokenConfig;
        collateralTokenConfig.ltv = newLtv;
        collateralTokenConfig.liquidationThreshold = newLiquidationThreshold;
        collateralTokenConfig.liquidationBonus = newLiquidationBonus;

        vm.startPrank(owner);
        vm.expectRevert(IDebtManager.InvalidValue.selector);
        debtManager.supportCollateralToken(address(0), collateralTokenConfig);
        vm.stopPrank();
    }

    function test_unsupportCollateralToken_reverts_whenTokenNotCollateral() public {
        vm.startPrank(owner);
        vm.expectRevert(IDebtManager.NotACollateralToken.selector);
        debtManager.unsupportCollateralToken(address(1));
        vm.stopPrank();
    }
    
    function test_unsupportCollateralToken_reverts_whenAddressZero() public {
        vm.startPrank(owner);
        vm.expectRevert(IDebtManager.InvalidValue.selector);
        debtManager.unsupportCollateralToken(address(0));
        vm.stopPrank();
    }

    function test_supportCollateralToken_reverts_whenOraclePriceZero() public {
        vm.startPrank(owner);
        
        address zeroValueToken = address(new MockERC20("ZeroToken", "ZTK", 18));
        
        // Create a mock price provider that returns zero for the token
        MockPriceProvider mockPriceProviderZero = new MockPriceProvider(0, address(usdcScroll));
        dataProvider.setPriceProvider(address(mockPriceProviderZero));
        
        IDebtManager.CollateralTokenConfig memory collateralTokenConfig;
        collateralTokenConfig.ltv = newLtv;
        collateralTokenConfig.liquidationThreshold = newLiquidationThreshold;
        collateralTokenConfig.liquidationBonus = newLiquidationBonus;
        
        vm.expectRevert(IDebtManager.OraclePriceZero.selector);
        debtManager.supportCollateralToken(zeroValueToken, collateralTokenConfig);
        
        vm.stopPrank();
    }

    function test_setCollateralTokenConfig_updatesConfig_forExistingToken() public {
        vm.startPrank(owner);
        
        IDebtManager.CollateralTokenConfig memory originalConfig = debtManager.collateralTokenConfig(address(weETHScroll));
        
        IDebtManager.CollateralTokenConfig memory newConfig;
        newConfig.ltv = newLtv; // 80e18
        newConfig.liquidationThreshold = newLiquidationThreshold; // 85e18
        newConfig.liquidationBonus = newLiquidationBonus; // 10e18

        debtManager.setCollateralTokenConfig(address(weETHScroll), newConfig);
        
        IDebtManager.CollateralTokenConfig memory updatedConfig = debtManager.collateralTokenConfig(address(weETHScroll));
        
        assertEq(updatedConfig.ltv, newLtv);
        assertEq(updatedConfig.liquidationThreshold, newLiquidationThreshold);
        assertEq(updatedConfig.liquidationBonus, newLiquidationBonus);
        
        assertTrue(updatedConfig.ltv != originalConfig.ltv);
        assertTrue(updatedConfig.liquidationThreshold != originalConfig.liquidationThreshold);
        assertTrue(updatedConfig.liquidationBonus != originalConfig.liquidationBonus);
        
        vm.stopPrank();
    }

    function test_setCollateralTokenConfig_reverts_whenThresholdPlusBonusGreaterThan100Percent() public {
        vm.startPrank(owner);
        
        IDebtManager.CollateralTokenConfig memory invalidConfig;
        invalidConfig.ltv = 50e18;
        invalidConfig.liquidationThreshold = 90e18;
        invalidConfig.liquidationBonus = 15e18; // This makes threshold + bonus = 105%, which exceeds 100%
        
        vm.expectRevert(IDebtManager.InvalidValue.selector);
        debtManager.setCollateralTokenConfig(address(weETHScroll), invalidConfig);
        
        vm.stopPrank();
    }
}