// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EtherFiSpokeInstance } from "../../../../../src/aave-v4/EtherFiSpokeInstance.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title GatedBorrowTest
 * @notice Proves the whitelabel gating invariant on the real in-test Aave v4 instance: only ether.fi safes
 *         can be the position owner of a borrow, while supply/withdraw/liquidation stay permissionless.
 */
contract GatedBorrowTest is CashGatewayTestSetup {
    address internal outsider = makeAddr("outsider");
    address internal liquidator = makeAddr("liquidator");

    function test_directBorrow_byNonSafe_reverts() public {
        deal(address(weETH), outsider, 10 ether);
        vm.startPrank(outsider);
        weETH.approve(address(spoke), 10 ether);
        spoke.supply(weethReserveId, 10 ether, outsider); // public supply must work
        spoke.setUsingAsCollateral(weethReserveId, true, outsider);
        vm.expectRevert(abi.encodeWithSelector(EtherFiSpokeInstance.OnlyEtherFiSafe.selector, outsider));
        spoke.borrow(usdcReserveId, 100e6, outsider);
        vm.stopPrank();
    }

    function test_positionManagerBorrow_forNonSafe_reverts() public {
        address pm = makeAddr("thirdPartyPm");
        _activateAavePositionManager(pm);
        vm.prank(outsider);
        spoke.setUserPositionManager(pm, true);

        vm.prank(pm);
        vm.expectRevert(abi.encodeWithSelector(EtherFiSpokeInstance.OnlyEtherFiSafe.selector, outsider));
        spoke.borrow(usdcReserveId, 100e6, outsider);
    }

    function test_safeBorrow_viaGateway_succeeds() public {
        uint256 before = usdc.balanceOf(recipient);
        _buildGatewayPosition(address(safe), address(weETH), 5 ether, address(usdc), 500e6);
        assertEq(usdc.balanceOf(recipient), before + 500e6, "gateway borrow delivered");
    }

    function test_safeBorrow_directSelfService_succeeds() public {
        _supplyToGateway(address(safe), address(weETH), 5 ether);
        uint256 before = usdc.balanceOf(address(safe));
        vm.prank(address(safe));
        spoke.borrow(usdcReserveId, 100e6, address(safe));
        assertEq(usdc.balanceOf(address(safe)), before + 100e6, "safe borrowed directly");
    }

    function test_publicSupplyAndWithdraw_unaffected() public {
        deal(address(usdc), outsider, 1_000e6);
        vm.startPrank(outsider);
        usdc.approve(address(spoke), 1_000e6);
        spoke.supply(usdcReserveId, 1_000e6, outsider);
        spoke.withdraw(usdcReserveId, 1_000e6, outsider);
        vm.stopPrank();
        assertEq(usdc.balanceOf(outsider), 1_000e6, "LP round-trips freely");
    }

    function test_liquidation_byRandomAddress_succeeds() public {
        _buildGatewayPosition(address(safe), address(weETH), 5 ether, address(usdc), 5_000e6);
        _setAaveCollateralFactor(address(weETH), 1000); // crash LTV so the position is underwater

        deal(address(usdc), liquidator, 10_000e6);
        vm.startPrank(liquidator);
        usdc.approve(address(spoke), 10_000e6);
        spoke.liquidationCall(weethReserveId, usdcReserveId, address(safe), 1_000e6, false);
        vm.stopPrank();
        assertGt(weETH.balanceOf(liquidator), 0, "liquidator seized collateral");
    }
}
