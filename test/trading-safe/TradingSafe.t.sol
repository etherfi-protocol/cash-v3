// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TradingSafe } from "../../src/trading-safe/TradingSafe.sol";
import { TradingSafeFactory } from "../../src/trading-safe/TradingSafeFactory.sol";
import { TradingOwnerBridgeReceiver } from "../../src/trading-safe/TradingOwnerBridgeReceiver.sol";
import { TradingSafeTestBase } from "./TradingSafeTestBase.t.sol";

contract TradingSafeTest is TradingSafeTestBase {
    TradingSafeFactory public factory;
    TradingSafe public safe;
    address public bridgeReceiver = makeAddr("bridgeReceiver");
    address public ownerA = makeAddr("ownerA");
    address public ownerB = makeAddr("ownerB");
    address public stranger = makeAddr("stranger");

    function setUp() public {
        _setupCore();

        vm.startPrank(owner);
        factory = _deployFactory(bridgeReceiver);
        _initDataProvider(address(factory));
        roleRegistry.grantRole(factory.TRADING_SAFE_FACTORY_ADMIN_ROLE(), owner);

        address[] memory initialOwners = new address[](1);
        initialOwners[0] = ownerA;
        safe = _deployTradingSafe(factory, makeAddr("sourceSafe"), initialOwners, 1);
        vm.stopPrank();
    }

    // ---- BRIDGE_RECEIVER wiring ----

    function test_BRIDGE_RECEIVER_isImmutable() public view {
        assertEq(safe.BRIDGE_RECEIVER(), bridgeReceiver);
    }

    // ---- applyBridgeConfigureOwners ----

    function test_applyBridgeConfigureOwners_addsOwner_andRetainsExisting() public {
        address[] memory toChange = new address[](1);
        toChange[0] = ownerB;
        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;

        vm.prank(bridgeReceiver);
        safe.applyBridgeConfigureOwners(toChange, shouldAdd, 2);

        assertTrue(safe.isOwner(ownerA));
        assertTrue(safe.isOwner(ownerB));
        assertEq(safe.getThreshold(), 2);

        // Admin role mirrors owner additions.
        assertTrue(roleRegistry.isSafeAdmin(address(safe), ownerB));
    }

    function test_applyBridgeConfigureOwners_removesOwner() public {
        // First add ownerB so we have two owners to play with.
        address[] memory addB = new address[](1);
        addB[0] = ownerB;
        bool[] memory addBFlags = new bool[](1);
        addBFlags[0] = true;
        vm.prank(bridgeReceiver);
        safe.applyBridgeConfigureOwners(addB, addBFlags, 2);

        // Now remove ownerA and drop threshold back to 1.
        address[] memory removeA = new address[](1);
        removeA[0] = ownerA;
        bool[] memory removeAFlags = new bool[](1);
        removeAFlags[0] = false;
        vm.prank(bridgeReceiver);
        safe.applyBridgeConfigureOwners(removeA, removeAFlags, 1);

        assertFalse(safe.isOwner(ownerA));
        assertTrue(safe.isOwner(ownerB));
        assertEq(safe.getThreshold(), 1);
        assertFalse(roleRegistry.isSafeAdmin(address(safe), ownerA));
    }

    function test_applyBridgeConfigureOwners_revertsWhen_notBridgeReceiver() public {
        address[] memory toChange = new address[](1);
        toChange[0] = ownerB;
        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;

        vm.expectRevert(TradingOwnerBridgeReceiver.OnlyBridgeReceiver.selector);
        vm.prank(stranger);
        safe.applyBridgeConfigureOwners(toChange, shouldAdd, 2);
    }

    // ---- applyBridgeSetThreshold ----

    function test_applyBridgeSetThreshold_updatesThreshold() public {
        // Need at least 2 owners to set threshold to 2.
        address[] memory addB = new address[](1);
        addB[0] = ownerB;
        bool[] memory addBFlags = new bool[](1);
        addBFlags[0] = true;
        vm.prank(bridgeReceiver);
        safe.applyBridgeConfigureOwners(addB, addBFlags, 1);

        vm.prank(bridgeReceiver);
        safe.applyBridgeSetThreshold(2);
        assertEq(safe.getThreshold(), 2);
    }

    function test_applyBridgeSetThreshold_revertsWhen_notBridgeReceiver() public {
        vm.expectRevert(TradingOwnerBridgeReceiver.OnlyBridgeReceiver.selector);
        vm.prank(stranger);
        safe.applyBridgeSetThreshold(1);
    }

    // ---- applyBridgeRecover ----

    function test_applyBridgeRecover_setsIncomingOwnerAndStartTime() public {
        address newOwner = makeAddr("newOwner");
        uint256 effectiveAt = block.timestamp + 7 days;

        vm.prank(bridgeReceiver);
        safe.applyBridgeRecover(newOwner, effectiveAt);

        assertEq(safe.getIncomingOwner(), newOwner);
        assertEq(safe.getIncomingOwnerStartTime(), effectiveAt);
    }

    function test_applyBridgeRecover_revertsWhen_notBridgeReceiver() public {
        vm.expectRevert(TradingOwnerBridgeReceiver.OnlyBridgeReceiver.selector);
        vm.prank(stranger);
        safe.applyBridgeRecover(makeAddr("newOwner"), block.timestamp + 7 days);
    }

    // ---- applyBridgeCancelRecovery ----

    function test_applyBridgeCancelRecovery_clearsIncomingOwner() public {
        address newOwner = makeAddr("newOwner");
        uint256 effectiveAt = block.timestamp + 7 days;
        vm.prank(bridgeReceiver);
        safe.applyBridgeRecover(newOwner, effectiveAt);
        assertEq(safe.getIncomingOwner(), newOwner);

        vm.prank(bridgeReceiver);
        safe.applyBridgeCancelRecovery();

        assertEq(safe.getIncomingOwner(), address(0));
        assertEq(safe.getIncomingOwnerStartTime(), 0);
    }

    function test_applyBridgeCancelRecovery_revertsWhen_notBridgeReceiver() public {
        vm.expectRevert(TradingOwnerBridgeReceiver.OnlyBridgeReceiver.selector);
        vm.prank(stranger);
        safe.applyBridgeCancelRecovery();
    }
}
