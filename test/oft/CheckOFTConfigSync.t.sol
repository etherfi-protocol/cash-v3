// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CheckOFTConfigSync } from "../../scripts/CheckOFTConfigSync.s.sol";
import { IOFTConfigRegistry } from "../../src/interfaces/IOFTConfigRegistry.sol";
import { OFTCrossChainSetup } from "./OFTCrossChainSetup.t.sol";

/**
 * @title CheckOFTConfigSyncTest
 * @notice Drives the off-chain staleness checker against the LIVE LayerZero endpoint harness:
 *         a configured-but-not-pushed pathway reads STALE (the endpoint still serves the harness
 *         default ULN), and the same pathway reads IN SYNC once the registry pushes it. Scoped to
 *         the mainnet adapter (A_EID -> B_EID) so the one-EVM harness's shared registry doesn't
 *         bleed the OP-side bridge into the assertions (same scoping rationale as the sync test).
 */
contract CheckOFTConfigSyncTest is OFTCrossChainSetup {
    CheckOFTConfigSync internal checker;
    address internal configAdmin = makeAddr("configAdmin");

    function setUp() public override {
        super.setUp();
        _deployPair(8);
        checker = new CheckOFTConfigSync();
        // cache the role BEFORE the prank: reading it is a call that would otherwise consume the prank
        bytes32 configAdminRole = configRegistry.CONFIG_ADMIN_ROLE();
        vm.prank(owner);
        roleRegistry.grantRole(configAdminRole, configAdmin);
    }

    function _realPathway(uint64 confirmations, address[] memory dvns) internal view returns (IOFTConfigRegistry.PathwayConfig memory) {
        return IOFTConfigRegistry.PathwayConfig({
            sendLib: endpointSetup.sendLibs[0], // A_EID == 1 -> index 0
            receiveLib: endpointSetup.receiveLibs[0],
            confirmations: confirmations,
            optionalDVNThreshold: 0,
            requiredDVNs: dvns,
            optionalDVNs: new address[](0)
        });
    }

    function _sortedDVNs() internal returns (address[] memory) {
        address[] memory dvns = new address[](2);
        dvns[0] = makeAddr("dvnA");
        dvns[1] = makeAddr("dvnB");
        if (dvns[0] > dvns[1]) (dvns[0], dvns[1]) = (dvns[1], dvns[0]);
        return dvns;
    }

    function test_pathwayStatus_staleBeforePush_inSyncAfterPush() public {
        // Canonical config exists but the adapter has not pulled it yet.
        vm.prank(configAdmin);
        configRegistry.setPathwayConfig(B_EID, _realPathway(15, _sortedDVNs()));

        (bool readOk, bool inSync) = checker.pathwayStatus(configRegistry, address(adapter), B_EID);
        assertTrue(readOk, "endpoint rows should be readable");
        assertFalse(inSync, "endpoint still serves the harness default ULN -> STALE");

        // Registry pushes the config to the adapter's own endpoint rows.
        address[] memory targets = new address[](1);
        targets[0] = address(adapter);
        uint32[] memory eids = new uint32[](1);
        eids[0] = B_EID;
        vm.prank(configAdmin);
        configRegistry.pushTo(targets, eids);

        (readOk, inSync) = checker.pathwayStatus(configRegistry, address(adapter), B_EID);
        assertTrue(readOk, "endpoint rows should be readable after push");
        assertTrue(inSync, "applied config now matches canonical -> IN SYNC");
    }

    function test_pathwayStatus_staleAgainAfterCanonicalEdit() public {
        address[] memory targets = new address[](1);
        targets[0] = address(adapter);
        uint32[] memory eids = new uint32[](1);
        eids[0] = B_EID;

        vm.prank(configAdmin);
        configRegistry.setPathwayConfig(B_EID, _realPathway(15, _sortedDVNs()));
        vm.prank(configAdmin);
        configRegistry.pushTo(targets, eids);

        (, bool inSync) = checker.pathwayStatus(configRegistry, address(adapter), B_EID);
        assertTrue(inSync, "synced");

        // Editing the canonical config (without re-pushing) must surface as STALE.
        vm.prank(configAdmin);
        configRegistry.setPathwayConfig(B_EID, _realPathway(30, _sortedDVNs()));

        (, inSync) = checker.pathwayStatus(configRegistry, address(adapter), B_EID);
        assertFalse(inSync, "canonical changed, bridge not re-pushed -> STALE");
    }
}
