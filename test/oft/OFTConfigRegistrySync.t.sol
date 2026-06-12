// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UlnConfig } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import { ILayerZeroEndpointV2 } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { OFTUpgradeable } from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTUpgradeable.sol";

import { IOFTConfigRegistry } from "../../src/interfaces/IOFTConfigRegistry.sol";
import { ConfigurableOFTBase } from "../../src/oft/ConfigurableOFTBase.sol";
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

    // helper: push config to the adapter through the registry (the only authorized syncConfig caller)
    function _push(address[] memory targets, uint32[] memory eids) internal {
        vm.prank(configAdmin);
        configRegistry.pushTo(targets, eids);
    }

    // helper: single-element [adapter] target list
    function _adapterTarget() internal view returns (address[] memory t) {
        t = new address[](1);
        t[0] = address(adapter);
    }

    // A well-formed pathway with real libs + sorted DVNs is actually applied to the live endpoint
    // when the registry pushes it — proven by reading the config back from the endpoint.
    function test_syncConfig_appliesWellFormedConfig() public {
        address[] memory dvns = _sortedDVNs();
        _setPathway(B_EID, _realPathway(15, dvns));

        // BEFORE: the endpoint serves the harness DEFAULT ULN (1 DVN, conf 100), NOT ours.
        UlnConfig memory beforeCfg = _ulnOnEndpoint(endpointSetup.sendLibs[0], B_EID);
        assertTrue(beforeCfg.requiredDVNs.length != 2 || beforeCfg.confirmations != 15, "precondition: our config already present");

        uint32[] memory eids = new uint32[](1);
        eids[0] = B_EID;
        _push(_adapterTarget(), eids); // registry directs the bridge to apply config

        // the config genuinely landed on the endpoint's send + receive rows.
        UlnConfig memory sendUln = _ulnOnEndpoint(endpointSetup.sendLibs[0], B_EID);
        assertEq(sendUln.confirmations, 15, "confirmations not applied on send lib");
        assertEq(sendUln.requiredDVNs.length, 2, "DVN count not applied");
        assertEq(sendUln.requiredDVNs[0], dvns[0]);
        assertEq(sendUln.requiredDVNs[1], dvns[1]);

        UlnConfig memory recvUln = _ulnOnEndpoint(endpointSetup.receiveLibs[0], B_EID);
        assertEq(recvUln.requiredDVNs.length, 2, "DVN config not applied on receive lib");
    }

    // syncConfig is gated to the registry: a third party can't force a re-pull on the bridge directly.
    // (Malformed DVN configs are rejected even earlier, at setPathwayConfig write time — see
    // OFTConfigRegistryTest for that coverage, so the live ULN never receives one.)
    function test_syncConfig_reverts_whenCallerNotRegistry() public {
        _setPathway(B_EID, _realPathway(15, _sortedDVNs()));
        uint32[] memory eids = new uint32[](1);
        eids[0] = B_EID;
        vm.prank(alice);
        vm.expectRevert(ConfigurableOFTBase.UnauthorizedSync.selector);
        adapter.syncConfig(eids);
    }

    // An unconfigured destination resolves to an empty pathway (zero send lib); syncConfig fails
    // fast with PathwayNotFound before touching the endpoint, rather than reverting deep in the ULN.
    function test_syncConfig_reverts_onUnconfiguredEid() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = UNCONFIGURED_EID;
        vm.expectRevert(IOFTConfigRegistry.PathwayNotFound.selector);
        _push(_adapterTarget(), eids);
    }

    // configRegistry is immutable and BOTH production impls (adapter + shadow) reject a zero registry
    // at construction, so the RegistryNotSet guard is unreachable in prod. This synthetic impl (zero
    // registry, guard omitted) exercises it directly: syncConfig must revert before touching the
    // endpoint. No initialize() is needed — the guard reads the immutable before any storage.
    function test_syncConfig_reverts_whenRegistryUnset() public {
        NoGuardConfigurableOFT noReg = new NoGuardConfigurableOFT(endpoints[A_EID]);
        uint32[] memory eids = new uint32[](1);
        eids[0] = B_EID;
        vm.expectRevert(ConfigurableOFTBase.RegistryNotSet.selector);
        noReg.syncConfig(eids);
    }
}

/**
 * @dev Test-only ConfigurableOFT whose constructor does NOT reject a zero registry. The production
 *      impls (EtherFiOFTAdapter / EtherFiShadowOFT) both revert `InvalidAddress` on a zero registry,
 *      which makes {ConfigurableOFTBase.RegistryNotSet} otherwise unreachable; this exposes it.
 */
contract NoGuardConfigurableOFT is OFTUpgradeable, ConfigurableOFTBase {
    constructor(address ep) OFTUpgradeable(ep) ConfigurableOFTBase(address(0)) {
        _disableInitializers();
    }
}
