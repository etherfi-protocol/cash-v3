// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Vm.sol";

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

    // ------------------------------------------- write-time DVN validation (mirrors LZ UlnBase)

    // n sequential addresses (1, 2, ... n): inherently sorted-ascending and unique.
    function _seqAddrs(uint256 n) internal pure returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = address(uint160(i + 1));
        }
    }

    // Unsorted requiredDVNs are rejected at write time (LZ requires strict ascending order).
    function test_setPathwayConfig_reverts_onUnsortedRequiredDVNs() public {
        IOFTConfigRegistry.PathwayConfig memory cfg = _samplePathway(15);
        (cfg.requiredDVNs[0], cfg.requiredDVNs[1]) = (cfg.requiredDVNs[1], cfg.requiredDVNs[0]); // force descending
        vm.prank(configAdmin);
        vm.expectRevert(IOFTConfigRegistry.DVNsNotSortedOrUnique.selector);
        configRegistry.setPathwayConfig(DST_EID_OP, cfg);
    }

    // Duplicate requiredDVNs are rejected (the sorted-strictly-ascending check forbids equals).
    function test_setPathwayConfig_reverts_onDuplicateRequiredDVNs() public {
        IOFTConfigRegistry.PathwayConfig memory cfg = _samplePathway(15);
        cfg.requiredDVNs[1] = cfg.requiredDVNs[0]; // duplicate
        vm.prank(configAdmin);
        vm.expectRevert(IOFTConfigRegistry.DVNsNotSortedOrUnique.selector);
        configRegistry.setPathwayConfig(DST_EID_OP, cfg);
    }

    // A zero DVN address is rejected (address(0) can't exceed the address(0) sort floor).
    function test_setPathwayConfig_reverts_onZeroDVNAddress() public {
        IOFTConfigRegistry.PathwayConfig memory cfg = _samplePathway(15);
        cfg.requiredDVNs[0] = address(0);
        vm.prank(configAdmin);
        vm.expectRevert(IOFTConfigRegistry.DVNsNotSortedOrUnique.selector);
        configRegistry.setPathwayConfig(DST_EID_OP, cfg);
    }

    // More than MAX_DVN_COUNT (127) required DVNs is rejected — would overflow the on-chain uint8 count.
    function test_setPathwayConfig_reverts_onTooManyRequiredDVNs() public {
        IOFTConfigRegistry.PathwayConfig memory cfg = _samplePathway(15);
        cfg.requiredDVNs = _seqAddrs(128);
        vm.prank(configAdmin);
        vm.expectRevert(IOFTConfigRegistry.TooManyDVNs.selector);
        configRegistry.setPathwayConfig(DST_EID_OP, cfg);
    }

    // A non-zero optional threshold with no optional DVNs is rejected (LZ requires threshold == 0 then).
    function test_setPathwayConfig_reverts_onNonzeroThreshold_whenNoOptionalDVNs() public {
        IOFTConfigRegistry.PathwayConfig memory cfg = _samplePathway(15); // optionalDVNs empty
        cfg.optionalDVNThreshold = 1;
        vm.prank(configAdmin);
        vm.expectRevert(IOFTConfigRegistry.InvalidOptionalDVNThreshold.selector);
        configRegistry.setPathwayConfig(DST_EID_OP, cfg);
    }

    // A zero optional threshold WITH optional DVNs present is rejected (must be in (0, count]).
    function test_setPathwayConfig_reverts_onZeroThreshold_whenOptionalDVNsPresent() public {
        IOFTConfigRegistry.PathwayConfig memory cfg = _samplePathway(15);
        cfg.optionalDVNs = _seqAddrs(2);
        cfg.optionalDVNThreshold = 0;
        vm.prank(configAdmin);
        vm.expectRevert(IOFTConfigRegistry.InvalidOptionalDVNThreshold.selector);
        configRegistry.setPathwayConfig(DST_EID_OP, cfg);
    }

    // An optional threshold exceeding the optional DVN count is rejected.
    function test_setPathwayConfig_reverts_onThresholdAboveOptionalCount() public {
        IOFTConfigRegistry.PathwayConfig memory cfg = _samplePathway(15);
        cfg.optionalDVNs = _seqAddrs(2);
        cfg.optionalDVNThreshold = 3; // > 2
        vm.prank(configAdmin);
        vm.expectRevert(IOFTConfigRegistry.InvalidOptionalDVNThreshold.selector);
        configRegistry.setPathwayConfig(DST_EID_OP, cfg);
    }

    // Unsorted optional DVNs are rejected too (same invariant as required).
    function test_setPathwayConfig_reverts_onUnsortedOptionalDVNs() public {
        IOFTConfigRegistry.PathwayConfig memory cfg = _samplePathway(15);
        address[] memory opt = _seqAddrs(2);
        (opt[0], opt[1]) = (opt[1], opt[0]); // descending
        cfg.optionalDVNs = opt;
        cfg.optionalDVNThreshold = 1;
        vm.prank(configAdmin);
        vm.expectRevert(IOFTConfigRegistry.DVNsNotSortedOrUnique.selector);
        configRegistry.setPathwayConfig(DST_EID_OP, cfg);
    }

    // A well-formed config with valid optional DVNs + threshold is accepted and stored.
    function test_setPathwayConfig_acceptsValidOptionalDVNs() public {
        IOFTConfigRegistry.PathwayConfig memory cfg = _samplePathway(15);
        cfg.optionalDVNs = _seqAddrs(2);
        cfg.optionalDVNThreshold = 1; // in (0, 2]
        vm.prank(configAdmin);
        configRegistry.setPathwayConfig(DST_EID_OP, cfg);

        IOFTConfigRegistry.PathwayConfig memory got = configRegistry.getPathwayConfig(DST_EID_OP);
        assertEq(got.optionalDVNs.length, 2);
        assertEq(got.optionalDVNThreshold, 1);
        assertEq(configRegistry.configVersion(), 1);
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

    // Registering the same bridge twice is a no-op (set semantics), not a double-count,
    // and the second call emits no BridgeRegistered event.
    function test_registerBridge_isIdempotent() public {
        address bridge = address(new MockConfigurableOFT(address(configRegistry)));
        vm.startPrank(registrar);
        configRegistry.registerBridge(bridge);

        vm.recordLogs();
        configRegistry.registerBridge(bridge); // second add is ignored by the set
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IOFTConfigRegistry.BridgeRegistered.selector, "no event on duplicate register");
        }
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

    // ----------------------------------------------------------------- removePathway / deregisterBridge

    // Removing a pathway clears its config, drops it from activeDstEids, bumps the version, and emits.
    function test_removePathway_removesAndBumpsVersion() public {
        _setPathway(DST_EID_OP, 15); // v1, active = [OP]
        assertEq(configRegistry.activeDstEids().length, 1);

        vm.expectEmit(true, false, false, true);
        emit IOFTConfigRegistry.PathwayRemoved(DST_EID_OP, 2);
        vm.prank(configAdmin);
        configRegistry.removePathway(DST_EID_OP);

        assertEq(configRegistry.configVersion(), 2);
        assertEq(configRegistry.activeDstEids().length, 0);
        assertEq(configRegistry.getPathwayConfig(DST_EID_OP).sendLib, address(0)); // config cleared
    }

    // Removing a destination that was never configured reverts (fail loud on a likely typo).
    function test_removePathway_reverts_whenNotFound() public {
        vm.prank(configAdmin);
        vm.expectRevert(IOFTConfigRegistry.PathwayNotFound.selector);
        configRegistry.removePathway(DST_EID_OP);
    }

    // Only CONFIG_ADMIN_ROLE may remove a pathway.
    function test_removePathway_reverts_whenNotConfigAdmin() public {
        _setPathway(DST_EID_OP, 15);
        vm.prank(alice);
        vm.expectRevert(IOFTConfigRegistry.OnlyConfigAdmin.selector);
        configRegistry.removePathway(DST_EID_OP);
    }

    // Pathway removal is blocked while the registry is paused.
    function test_removePathway_reverts_whenPaused() public {
        _setPathway(DST_EID_OP, 15);
        vm.prank(pauser);
        configRegistry.pause();
        vm.prank(configAdmin);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        configRegistry.removePathway(DST_EID_OP);
    }

    // A removed destination can be re-listed by setting it again — it lands once in activeDstEids.
    function test_removePathway_thenReAdd_listsOnce() public {
        _setPathway(DST_EID_OP, 15);
        vm.prank(configAdmin);
        configRegistry.removePathway(DST_EID_OP);
        _setPathway(DST_EID_OP, 20); // re-add with new confirmations

        assertEq(configRegistry.activeDstEids().length, 1);
        assertEq(configRegistry.activeDstEids()[0], DST_EID_OP);
        assertEq(configRegistry.getPathwayConfig(DST_EID_OP).confirmations, 20);
    }

    // The admin can drop a bridge from the push set; it leaves the enumerable set and emits.
    function test_deregisterBridge_removesAndEmits() public {
        address bridge = address(new MockConfigurableOFT(address(configRegistry)));
        vm.prank(registrar);
        configRegistry.registerBridge(bridge);
        assertEq(configRegistry.numBridges(), 1);

        vm.expectEmit(true, false, false, false);
        emit IOFTConfigRegistry.BridgeDeregistered(bridge);
        vm.prank(configAdmin);
        configRegistry.deregisterBridge(bridge);

        assertEq(configRegistry.numBridges(), 0);
        assertEq(configRegistry.getBridges(0, 10).length, 0);
    }

    // Deregistering a bridge that was never registered reverts.
    function test_deregisterBridge_reverts_whenNotFound() public {
        vm.prank(configAdmin);
        vm.expectRevert(IOFTConfigRegistry.BridgeNotFound.selector);
        configRegistry.deregisterBridge(makeAddr("ghost"));
    }

    // Deregistration is an admin action — a registrar (the factory role) cannot deregister.
    function test_deregisterBridge_reverts_whenNotConfigAdmin() public {
        address bridge = address(new MockConfigurableOFT(address(configRegistry)));
        vm.prank(registrar);
        configRegistry.registerBridge(bridge);

        vm.prank(registrar); // holds REGISTRAR, not CONFIG_ADMIN
        vm.expectRevert(IOFTConfigRegistry.OnlyConfigAdmin.selector);
        configRegistry.deregisterBridge(bridge);
    }
}
