// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { CashModuleTestSetup } from "../CashModuleTestSetup.t.sol";
import { UpgradeableProxy } from "../../../../../src/utils/UpgradeableProxy.sol";
import { SettlementDispatcherV2 } from "../../../../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { BinSponsor } from "../../../../../src/interfaces/ICashModule.sol";

contract SettlementDispatcherV2Test is CashModuleTestSetup {
    address alice = makeAddr("alice");
    SettlementDispatcherV2 v2;

    function setUp() public override {
        super.setUp();

        // Upgrade to V2
        address settlementDispatcherV2Impl = address(new SettlementDispatcherV2(BinSponsor.Reap, address(dataProvider)));
        vm.prank(owner);
        UUPSUpgradeable(address(settlementDispatcherReap)).upgradeToAndCall(settlementDispatcherV2Impl, "");
        
        v2 = SettlementDispatcherV2(payable(address(settlementDispatcherReap)));
    }

    function test_v2_setRefundWallet_succeeds() public {
        address newWallet = makeAddr("newWallet");
        
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcherV2.RefundWalletSet(newWallet);
        v2.setRefundWallet(newWallet);
        
        assertEq(v2.getRefundWallet(), newWallet);
    }

    function test_v2_getRefundWallet_fallsBackToDataProvider() public {
        assertEq(v2.getRefundWallet(), refundWallet);
        
        address customWallet = makeAddr("customWallet");
        vm.prank(owner);
        v2.setRefundWallet(customWallet);
        assertEq(v2.getRefundWallet(), customWallet);
        
        vm.prank(owner);
        v2.setRefundWallet(address(0));
        assertEq(v2.getRefundWallet(), refundWallet);
    }

    function test_v2_setRefundWallet_reverts_whenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(UpgradeableProxy.OnlyRoleRegistryOwner.selector);
        v2.setRefundWallet(makeAddr("newWallet"));
    }
}

