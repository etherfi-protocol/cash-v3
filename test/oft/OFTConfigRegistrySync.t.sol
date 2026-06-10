// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UlnConfig } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import { ILayerZeroEndpointV2 } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import { IOFTConfigRegistry } from "../../src/interfaces/IOFTConfigRegistry.sol";
import { OFTCrossChainSetup } from "./OFTCrossChainSetup.t.sol";

/**
 * @title OFTConfigRegistrySyncTest
 * @notice Exercises syncConfig against a LIVE LayerZero endpoint, which the
 *         recording mock could never validate. A well-formed pathway applies cleanly; malformed DVN
 *         arrays (unsorted, duplicated) are rejected by the real ULN; and syncing an unconfigured
 *         destination (empty pathway -> zero send library) is rejected rather than silently pushing
 *         an insecure no-DVN config.
 *
 *         Only the mainnet adapter (A_EID -> B_EID) is driven here, so the single shared registry of
 *         the one-EVM harness doesn't bleed OP-side bridges into these assertions.
 */
contract OFTConfigRegistrySyncTest is OFTCrossChainSetup {
    address internal configAdmin = makeAddr("configAdmin");

    function setUp() public override {
        super.setUp();
        _deployPair(8);
        // cache the role BEFORE the prank: reading it is a call that would otherwise consume the prank
        bytes32 configAdminRole = configRegistry.CONFIG_ADMIN_ROLE();
        vm.prank(owner);
        roleRegistry.grantRole(configAdminRole, configAdmin);
    }

    // Build a pathway pointing at the harness's REAL send/receive libraries for the adapter's chain.
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

    function _sortedDVNs() internal returns (address[] memory dvns) {
        dvns = new address[](2);
        dvns[0] = makeAddr("dvnA");
        dvns[1] = makeAddr("dvnB");
        if (dvns[0] > dvns[1]) (dvns[0], dvns[1]) = (dvns[1], dvns[0]);
    }

    function _setPathway(uint32 dstEid, IOFTConfigRegistry.PathwayConfig memory cfg) internal {
        vm.prank(configAdmin);
        configRegistry.setPathwayConfig(dstEid, cfg);
    }

    uint32 internal constant UNCONFIGURED_EID = 9999;
    uint32 internal constant CONFIG_TYPE_ULN = 2;

    // Read the ULN config the adapter has on its OWN endpoint rows for `dstEid` via `lib`.
    function _ulnOnEndpoint(address lib, uint32 dstEid) internal view returns (UlnConfig memory) {
        bytes memory raw = ILayerZeroEndpointV2(endpoints[A_EID]).getConfig(address(adapter), lib, dstEid, CONFIG_TYPE_ULN);
        return abi.decode(raw, (UlnConfig));
    }

    // A well-formed pathway with real libs + sorted DVNs is actually applied to the live endpoint —
    // proven by reading the config back, not just by the local version counter (which syncConfig
    // would bump even if it never called setConfig).
    function test_syncConfig_appliesWellFormedConfig() public {
        address[] memory dvns = _sortedDVNs();
        _setPathway(B_EID, _realPathway(15, dvns));

        // BEFORE: not synced; the endpoint serves the harness DEFAULT ULN (1 DVN, conf 100), NOT ours.
        assertEq(adapter.syncedConfigVersion(), 0, "precondition: already synced");
        UlnConfig memory beforeCfg = _ulnOnEndpoint(endpointSetup.sendLibs[0], B_EID);
        assertTrue(beforeCfg.requiredDVNs.length != 2 || beforeCfg.confirmations != 15, "precondition: our config already present");

        uint32[] memory eids = new uint32[](1);
        eids[0] = B_EID;
        adapter.syncConfig(eids); // permissionless pull; self-authorized on the endpoint

        // local bookkeeping advanced...
        assertEq(adapter.syncedConfigVersion(), configRegistry.configVersion());

        // ...AND the config genuinely landed on the endpoint's send + receive rows.
        UlnConfig memory sendUln = _ulnOnEndpoint(endpointSetup.sendLibs[0], B_EID);
        assertEq(sendUln.confirmations, 15, "confirmations not applied on send lib");
        assertEq(sendUln.requiredDVNs.length, 2, "DVN count not applied");
        assertEq(sendUln.requiredDVNs[0], dvns[0]);
        assertEq(sendUln.requiredDVNs[1], dvns[1]);

        UlnConfig memory recvUln = _ulnOnEndpoint(endpointSetup.receiveLibs[0], B_EID);
        assertEq(recvUln.requiredDVNs.length, 2, "DVN config not applied on receive lib");
    }

    // Unsorted requiredDVNs are rejected by the real ULN (LZ requires strict ascending order).
    function test_syncConfig_reverts_onUnsortedDVNs() public {
        address[] memory dvns = _sortedDVNs();
        (dvns[0], dvns[1]) = (dvns[1], dvns[0]); // force descending
        _setPathway(B_EID, _realPathway(15, dvns));

        UlnConfig memory beforeCfg = _ulnOnEndpoint(endpointSetup.sendLibs[0], B_EID);

        uint32[] memory eids = new uint32[](1);
        eids[0] = B_EID;
        vm.expectRevert(); // LZ_ULN_Unsorted (ULN-internal)
        adapter.syncConfig(eids);

        // atomic rollback: nothing synced and the endpoint config is unchanged from before the attempt
        assertEq(adapter.syncedConfigVersion(), 0, "synced version advanced despite revert");
        _assertUlnUnchanged(beforeCfg, _ulnOnEndpoint(endpointSetup.sendLibs[0], B_EID));
    }

    // Duplicate requiredDVNs are rejected by the real ULN.
    function test_syncConfig_reverts_onDuplicateDVNs() public {
        address[] memory dvns = new address[](2);
        dvns[0] = makeAddr("dup");
        dvns[1] = dvns[0];
        _setPathway(B_EID, _realPathway(15, dvns));

        UlnConfig memory beforeCfg = _ulnOnEndpoint(endpointSetup.sendLibs[0], B_EID);

        uint32[] memory eids = new uint32[](1);
        eids[0] = B_EID;
        vm.expectRevert();
        adapter.syncConfig(eids);

        assertEq(adapter.syncedConfigVersion(), 0, "synced version advanced despite revert");
        _assertUlnUnchanged(beforeCfg, _ulnOnEndpoint(endpointSetup.sendLibs[0], B_EID));
    }

    /// @dev Confirmations + DVN count unchanged — i.e. the attempted (bad) config was not applied.
    function _assertUlnUnchanged(UlnConfig memory before, UlnConfig memory got) internal pure {
        assertEq(got.confirmations, before.confirmations, "confirmations changed despite revert");
        assertEq(got.requiredDVNs.length, before.requiredDVNs.length, "DVN set changed despite revert");
    }

    // Syncing an unconfigured destination resolves to an empty pathway (zero send lib); the real
    // endpoint rejects setConfig against the zero library, so no insecure no-DVN config is applied.
    function test_syncConfig_reverts_onUnconfiguredEid() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = UNCONFIGURED_EID;
        vm.expectRevert();
        adapter.syncConfig(eids);

        assertEq(adapter.syncedConfigVersion(), 0, "synced version advanced despite revert");
    }
}
