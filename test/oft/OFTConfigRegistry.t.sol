// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import { IOFTConfigRegistry } from "../../src/interfaces/IOFTConfigRegistry.sol";
import { OFTConfigRegistry } from "../../src/oft/OFTConfigRegistry.sol";
import { MockConfigurableOFT, OFTTestSetup } from "./OFTTestSetup.t.sol";

contract OFTConfigRegistryTest is OFTTestSetup {
    // helper: set a pathway as the config admin (the only role allowed to)
    function _setPathway(uint32 dstEid, uint64 confirmations) internal {
        vm.prank(configAdmin);
        configRegistry.setPathwayConfig(dstEid, _samplePathway(confirmations));
    }

    // ----------------------------------------------------------------- setPathwayConfig

    // Setting a pathway stores the config, bumps the version 0 -> 1, and lists the destination.
    function test_setPathwayConfig_storesAndBumpsVersion() public {
        assertEq(configRegistry.configVersion(), 0);

        // event carries the new version (1)
        vm.expectEmit(true, false, false, true);
        emit IOFTConfigRegistry.PathwayConfigSet(DST_EID_OP, 1);
        _setPathway(DST_EID_OP, 15);

        assertEq(configRegistry.configVersion(), 1);

        IOFTConfigRegistry.PathwayConfig memory got = configRegistry.getPathwayConfig(DST_EID_OP);
        assertEq(got.confirmations, 15);
        assertEq(got.requiredDVNs.length, 2);
        assertTrue(got.sendLib != address(0));
        assertTrue(got.receiveLib != address(0));

        uint32[] memory active = configRegistry.activeDstEids();
        assertEq(active.length, 1);
        assertEq(active[0], DST_EID_OP);
    }

    // A second, distinct destination is appended to activeDstEids and bumps the version again.
    function test_setPathwayConfig_secondEid_appendsToActiveList_andBumpsVersion() public {
        _setPathway(DST_EID_OP, 15);
        _setPathway(DST_EID_ETH, 20);

        assertEq(configRegistry.configVersion(), 2);
        uint32[] memory active = configRegistry.activeDstEids();
        assertEq(active.length, 2);
        assertEq(active[0], DST_EID_OP);
        assertEq(active[1], DST_EID_ETH);
    }

    // Re-configuring an existing destination updates it + bumps version, but must NOT duplicate it
    // in activeDstEids (the EnumerableSet dedups).
    function test_setPathwayConfig_sameEidTwice_doesNotDuplicateActive_butBumpsVersion() public {
        _setPathway(DST_EID_OP, 15);
        _setPathway(DST_EID_OP, 25); // overwrite same dstEid with new confirmations

        assertEq(configRegistry.configVersion(), 2); // version bumps on every edit...
        assertEq(configRegistry.activeDstEids().length, 1); // ...but the destination is listed once
        assertEq(configRegistry.getPathwayConfig(DST_EID_OP).confirmations, 25); // latest config wins
    }

    // Only CONFIG_ADMIN_ROLE may set config.
    function test_setPathwayConfig_reverts_whenNotConfigAdmin() public {
        vm.prank(alice);
        vm.expectRevert(IOFTConfigRegistry.OnlyConfigAdmin.selector);
        configRegistry.setPathwayConfig(DST_EID_OP, _samplePathway(15));
    }

    // A zero send library is rejected — can't configure an incomplete pathway.
    function test_setPathwayConfig_reverts_onZeroSendLib() public {
        IOFTConfigRegistry.PathwayConfig memory cfg = _samplePathway(15);
        cfg.sendLib = address(0);
        vm.prank(configAdmin);
        vm.expectRevert(IOFTConfigRegistry.InvalidInput.selector);
        configRegistry.setPathwayConfig(DST_EID_OP, cfg);
    }

    // A pathway with no required DVNs is rejected — zero verifiers would be insecure.
    function test_setPathwayConfig_reverts_onEmptyRequiredDVNs() public {
        IOFTConfigRegistry.PathwayConfig memory cfg = _samplePathway(15);
        cfg.requiredDVNs = new address[](0);
        vm.prank(configAdmin);
        vm.expectRevert(IOFTConfigRegistry.InvalidInput.selector);
        configRegistry.setPathwayConfig(DST_EID_OP, cfg);
    }

    // ----------------------------------------------------------------- registerBridge / enumeration

    // The registrar can add a bridge; it lands in the enumerable set and emits.
    function test_registerBridge_addsToSet_andEmits() public {
        address bridge = address(new MockConfigurableOFT(address(configRegistry)));

        vm.expectEmit(true, false, false, false);
        emit IOFTConfigRegistry.BridgeRegistered(bridge);
        vm.prank(registrar);
        configRegistry.registerBridge(bridge);

        assertEq(configRegistry.numBridges(), 1);
        address[] memory got = configRegistry.getBridges(0, 10);
        assertEq(got.length, 1);
        assertEq(got[0], bridge);
    }

    // Only CONFIG_REGISTRAR_ROLE may register bridges.
    function test_registerBridge_reverts_whenNotRegistrar() public {
        address bridge = address(new MockConfigurableOFT(address(configRegistry)));
        vm.prank(alice);
        vm.expectRevert(IOFTConfigRegistry.OnlyRegistrar.selector);
        configRegistry.registerBridge(bridge);
    }

    // Zero bridge address is rejected.
    function test_registerBridge_reverts_onZeroAddress() public {
        vm.prank(registrar);
        vm.expectRevert(IOFTConfigRegistry.InvalidInput.selector);
        configRegistry.registerBridge(address(0));
    }

    // Registering the same bridge twice is a no-op (set semantics), not a double-count.
    function test_registerBridge_isIdempotent() public {
        address bridge = address(new MockConfigurableOFT(address(configRegistry)));
        vm.startPrank(registrar);
        configRegistry.registerBridge(bridge);
        configRegistry.registerBridge(bridge); // second add is ignored by the set
        vm.stopPrank();
        assertEq(configRegistry.numBridges(), 1);
    }

    // getBridges returns the requested window, clamps an over-long count to what's left, and
    // returns empty when start is past the end (the pagination contract).
    function test_getBridges_paginates() public {
        address[] memory bridges = new address[](5);
        vm.startPrank(registrar);
        for (uint256 i; i < 5; ++i) {
            bridges[i] = address(new MockConfigurableOFT(address(configRegistry)));
            configRegistry.registerBridge(bridges[i]);
        }
        vm.stopPrank();

        assertEq(configRegistry.numBridges(), 5);

        // a normal window [1,3)
        address[] memory page = configRegistry.getBridges(1, 2);
        assertEq(page.length, 2);
        assertEq(page[0], bridges[1]);
        assertEq(page[1], bridges[2]);

        // count over-asks past the end -> clamps to the 2 remaining (indices 3,4)
        address[] memory tail = configRegistry.getBridges(3, 100);
        assertEq(tail.length, 2);

        // start == length -> empty, no revert
        assertEq(configRegistry.getBridges(5, 1).length, 0);
    }

    // ----------------------------------------------------------------- push*

    // helper: deploy n fake bridges (MockConfigurableOFT records syncConfig calls) and register them
    function _deployAndRegisterMocks(uint256 n) internal returns (MockConfigurableOFT[] memory mocks) {
        mocks = new MockConfigurableOFT[](n);
        vm.startPrank(registrar);
        for (uint256 i; i < n; ++i) {
            mocks[i] = new MockConfigurableOFT(address(configRegistry));
            configRegistry.registerBridge(address(mocks[i]));
        }
        vm.stopPrank();
    }

    // pushToAll triggers syncConfig on EVERY registered bridge; each mock records that it was
    // called once, with which dstEids.
    function test_pushToAll_callsSyncOnEveryBridge() public {
        _setPathway(DST_EID_OP, 15);
        MockConfigurableOFT[] memory mocks = _deployAndRegisterMocks(3);

        uint32[] memory eids = new uint32[](1);
        eids[0] = DST_EID_OP;

        vm.prank(configAdmin);
        configRegistry.pushToAll(eids);

        for (uint256 i; i < 3; ++i) {
            assertEq(mocks[i].syncCallCount(), 1); // called exactly once
            assertEq(mocks[i].lastDstEidsLength(), 1);
            assertEq(mocks[i].lastDstEids(0), DST_EID_OP, "synced with wrong dstEid"); // with the dstEid we pushed
        }
    }

    // pushTo triggers syncConfig ONLY on the explicitly listed bridges (here: just mocks[1]).
    function test_pushTo_callsSyncOnSelectedBridges() public {
        _setPathway(DST_EID_OP, 15);
        MockConfigurableOFT[] memory mocks = _deployAndRegisterMocks(3);

        address[] memory targets = new address[](1);
        targets[0] = address(mocks[1]);
        uint32[] memory eids = new uint32[](1);
        eids[0] = DST_EID_OP;

        vm.prank(configAdmin);
        configRegistry.pushTo(targets, eids);

        assertEq(mocks[0].syncCallCount(), 0);
        assertEq(mocks[1].syncCallCount(), 1); // only the targeted one
        assertEq(mocks[2].syncCallCount(), 0);
    }

    // pushToRange triggers syncConfig ONLY on the [start, start+count) window (here: indices 1,2).
    function test_pushToRange_paginatesSync() public {
        _setPathway(DST_EID_OP, 15);
        MockConfigurableOFT[] memory mocks = _deployAndRegisterMocks(5);

        uint32[] memory eids = new uint32[](1);
        eids[0] = DST_EID_OP;

        vm.prank(configAdmin);
        configRegistry.pushToRange(1, 2, eids); // indices 1,2 only

        assertEq(mocks[0].syncCallCount(), 0);
        assertEq(mocks[1].syncCallCount(), 1);
        assertEq(mocks[2].syncCallCount(), 1);
        assertEq(mocks[3].syncCallCount(), 0);
        assertEq(mocks[4].syncCallCount(), 0);
    }

    // Only CONFIG_ADMIN_ROLE may trigger a push.
    function test_pushToAll_reverts_whenNotConfigAdmin() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = DST_EID_OP;
        vm.prank(alice);
        vm.expectRevert(IOFTConfigRegistry.OnlyConfigAdmin.selector);
        configRegistry.pushToAll(eids);
    }

    // ----------------------------------------------------------------- pause

    // Config edits are blocked while the registry is paused.
    function test_setPathwayConfig_reverts_whenPaused() public {
        vm.prank(pauser);
        configRegistry.pause();

        vm.prank(configAdmin);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        configRegistry.setPathwayConfig(DST_EID_OP, _samplePathway(15));
    }

    // Bridge registration is blocked while the registry is paused.
    function test_registerBridge_reverts_whenPaused() public {
        vm.prank(pauser);
        configRegistry.pause();

        vm.prank(registrar);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        configRegistry.registerBridge(makeAddr("bridge"));
    }
}
