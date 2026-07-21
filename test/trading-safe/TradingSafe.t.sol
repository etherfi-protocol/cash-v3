// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TradingSafe } from "../../src/trading-safe/TradingSafe.sol";
import { TradingSafeFactory } from "../../src/trading-safe/TradingSafeFactory.sol";
import { TradingSafeTestBase } from "./TradingSafeTestBase.t.sol";

/// @dev TradingSafe manages ownership and recovery locally on its own chain; there is no
///      cross-chain owner synchronization. These tests cover deploy-time ownership state
///      and the factory-gated `redirectToTopUp` executor. Signed multisig/recovery flows
///      are exercised against a concrete safe in the `test/safe` suite.
contract TradingSafeTest is TradingSafeTestBase {
    TradingSafeFactory public factory;
    TradingSafe public safe;
    address public ownerA = makeAddr("ownerA");
    address public stranger = makeAddr("stranger");

    function setUp() public {
        _setupCore();

        vm.startPrank(owner);
        factory = _deployFactory();
        _initDataProvider(address(factory));
        roleRegistry.grantRole(factory.TRADING_SAFE_FACTORY_ADMIN_ROLE(), owner);

        address[] memory initialOwners = new address[](1);
        initialOwners[0] = ownerA;
        safe = _deployTradingSafe(factory, makeAddr("sourceSafe"), initialOwners, 1);
        vm.stopPrank();
    }

    // ---- Deploy-time ownership ----

    function test_deploy_setsInitialOwnerAndThreshold() public view {
        assertTrue(safe.isOwner(ownerA));
        assertEq(safe.getThreshold(), 1);
    }

    // ---- redirectToTopUp is factory-gated ----

    function test_redirectToTopUp_revertsWhen_notFactory() public {
        vm.expectRevert(TradingSafe.OnlyTradingSafeFactory.selector);
        vm.prank(stranger);
        safe.redirectToTopUp(makeAddr("token"), makeAddr("topUp"), 1);
    }
}
