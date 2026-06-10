// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IConfigurableOFT } from "../../src/interfaces/IConfigurableOFT.sol";
import { IOFTConfigRegistry } from "../../src/interfaces/IOFTConfigRegistry.sol";
import { OFTConfigRegistry } from "../../src/oft/OFTConfigRegistry.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { MockConfigurableOFT, OFTTestSetup } from "./OFTTestSetup.t.sol";

/**
 *  A bridge whose syncConfig always reverts — used to prove pushToAll is all-or-nothing.
 */
contract RevertingBridge is IConfigurableOFT {
    address public immutable configRegistry;
    error SyncFailed();

    constructor(address r) {
        configRegistry = r;
    }

    function syncConfig(uint32[] calldata) external pure override {
        revert SyncFailed();
    }
}

/**
 * @title OFTConfigRegistryRobustnessTest
 * @notice Registry-level robustness: version skew/resync, the atomic all-or-nothing semantics of
 *         pushToAll when a bridge reverts, and the UUPS upgrade gate. Real-endpoint DVN validation
 *         lives in OFTConfigRegistrySync (it needs the live harness).
 */
contract OFTConfigRegistryRobustnessTest is OFTTestSetup {
    function _setPathway(uint32 dstEid, uint64 confirmations) internal {
        vm.prank(configAdmin);
        configRegistry.setPathwayConfig(dstEid, _samplePathway(confirmations));
    }

    function _registerMock() internal returns (MockConfigurableOFT m) {
        m = new MockConfigurableOFT(address(configRegistry));
        vm.prank(registrar);
        configRegistry.registerBridge(address(m));
    }

    // ----------------------------------------------------------------- version skew / resync

    /**
     * A bridge synced once can fall behind as the registry advances, then catch up with a later
     * push — the registry re-invokes syncConfig and the bridge re-pulls, no revert. (The bridge
     * keeps no version state of its own; sync history is observable via the ConfigSynced event.)
     */
    function test_versionSkew_resync_reinvokesSync() public {
        _setPathway(DST_EID_OP, 15); // v1
        MockConfigurableOFT m = _registerMock();

        uint32[] memory eids = new uint32[](1);
        eids[0] = DST_EID_OP;

        address[] memory targets = new address[](1);
        targets[0] = address(m);

        vm.prank(configAdmin);
        configRegistry.pushTo(targets, eids);
        assertEq(m.syncCallCount(), 1, "did not sync on first push");

        // registry moves on; the bridge is now stale while the registry is at v3
        _setPathway(DST_EID_OP, 20); // v2
        _setPathway(DST_EID_OP, 25); // v3
        assertEq(configRegistry.configVersion(), 3);
        assertEq(m.syncCallCount(), 1, "bridge re-synced without a push");

        // resync catches it up, no revert
        vm.prank(configAdmin);
        configRegistry.pushTo(targets, eids);
        assertEq(m.syncCallCount(), 2, "resync did not re-invoke syncConfig");
        assertEq(m.lastDstEids(0), DST_EID_OP, "resync pushed wrong dstEid");
    }

    // ----------------------------------------------------------------- pushToAll atomicity

    /**
     * pushToAll iterates every registered bridge in one transaction; if any bridge's syncConfig
     * reverts, the WHOLE batch reverts and earlier bridges' syncs roll back. Operators must use
     * pushTo / pushToRange to route around a wedged bridge.
     */
    function test_pushToAll_revertsAtomically_whenOneBridgeReverts() public {
        _setPathway(DST_EID_OP, 15);

        MockConfigurableOFT first = _registerMock(); // index 0 — syncs before the bad one
        RevertingBridge bad = new RevertingBridge(address(configRegistry));
        vm.prank(registrar);
        configRegistry.registerBridge(address(bad)); // index 1 — reverts
        MockConfigurableOFT third = _registerMock(); // index 2 — never reached

        uint32[] memory eids = new uint32[](1);
        eids[0] = DST_EID_OP;

        vm.prank(configAdmin);
        vm.expectRevert(RevertingBridge.SyncFailed.selector);
        configRegistry.pushToAll(eids);

        // the whole call rolled back: even the bridge that synced first shows no effect
        assertEq(first.syncCallCount(), 0, "first bridge's sync not rolled back");
        assertEq(third.syncCallCount(), 0);
    }

    /**
     * The escape hatch: pushTo can still configure the healthy bridges individually, skipping the
     * wedged one.
     */
    function test_pushTo_routesAroundRevertingBridge() public {
        _setPathway(DST_EID_OP, 15);
        MockConfigurableOFT first = _registerMock();
        RevertingBridge bad = new RevertingBridge(address(configRegistry));
        vm.prank(registrar);
        configRegistry.registerBridge(address(bad));

        address[] memory healthy = new address[](1);
        healthy[0] = address(first);
        uint32[] memory eids = new uint32[](1);
        eids[0] = DST_EID_OP;

        vm.prank(configAdmin);
        configRegistry.pushTo(healthy, eids); // skips `bad`
        assertEq(first.syncCallCount(), 1);
    }

    // ----------------------------------------------------------------- UUPS upgrade gate

    // Only an account with the upgrader role may upgrade the registry implementation.
    function test_registryUpgrade_reverts_whenNotUpgrader() public {
        address newImpl = address(new OFTConfigRegistry());
        vm.prank(alice);
        vm.expectRevert(RoleRegistry.OnlyUpgrader.selector);
        configRegistry.upgradeToAndCall(newImpl, "");
    }

    // The owner can upgrade — the impl slot actually changes — and state survives the upgrade.
    function test_registryUpgrade_succeeds_forOwner_statePreserved() public {
        _setPathway(DST_EID_OP, 15);
        assertEq(configRegistry.configVersion(), 1);

        address oldImpl = _implOf(address(configRegistry));
        address newImpl = address(new OFTConfigRegistry());
        assertTrue(newImpl != oldImpl, "test setup: new impl identical to old");

        vm.prank(owner);
        configRegistry.upgradeToAndCall(newImpl, "");

        // the proxy now points at the new implementation (proves the upgrade actually happened)...
        assertEq(_implOf(address(configRegistry)), newImpl, "impl slot not updated");
        // ...and version + pathway persist across the upgrade
        assertEq(configRegistry.configVersion(), 1);
        assertEq(configRegistry.getPathwayConfig(DST_EID_OP).confirmations, 15);
    }

    /// @dev Reads the ERC-1967 implementation slot of a proxy.
    function _implOf(address proxy) internal view returns (address) {
        bytes32 EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
    }
}
