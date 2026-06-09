// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import { IConfigurableOFT } from "../../src/interfaces/IConfigurableOFT.sol";
import { IOFTAdapterFactory } from "../../src/interfaces/IOFTAdapterFactory.sol";
import { IOFTConfigRegistry } from "../../src/interfaces/IOFTConfigRegistry.sol";
import { IShadowOFTFactory } from "../../src/interfaces/IShadowOFTFactory.sol";
import { EtherFiOFTAdapter } from "../../src/oft/EtherFiOFTAdapter.sol";
import { EtherFiShadowOFT } from "../../src/oft/EtherFiShadowOFT.sol";
import { OFTTestSetup } from "./OFTTestSetup.t.sol";

contract OFTFactoriesTest is OFTTestSetup {
    // helper: set the OP pathway config (so activeDstEids is non-empty for auto-sync tests)
    function _setPathwayOP() internal {
        vm.prank(configAdmin);
        configRegistry.setPathwayConfig(DST_EID_OP, _samplePathway(15));
    }

    // helper: deploy an adapter via the factory as the factory admin
    function _deployAdapter(address token) internal returns (address) {
        vm.prank(factoryAdmin);
        return adapterFactory.deployAdapter(keccak256(abi.encode(token)), token, delegate);
    }

    // ----------------------------------------------------------------- adapter auto-sync

    // With a pathway already configured, deploying an adapter auto-registers it AND auto-pulls
    // the DVN config (this is the Step-4 auto-sync feature working end to end).
    function test_deployAdapter_autoRegistersAndSyncs_whenPathwaySet() public {
        _setPathwayOP(); // version -> 1, one active dstEid (OP)

        address adapter = _deployAdapter(address(token6));

        // registered in the registry's bridge set
        assertEq(configRegistry.numBridges(), 1);
        assertEq(configRegistry.getBridges(0, 10)[0], adapter);

        // pulled config: the bridge configured ITSELF on the endpoint. syncConfig calls setConfig
        // once for the send lib and once for the receive lib -> 2 recorded calls for one dstEid.
        assertEq(endpoint.configCallCount(), 2);
        (address oapp,, uint32 eid,) = endpoint.configCalls(0);
        assertEq(oapp, adapter); // it configured its own rows (address(this))
        assertEq(eid, DST_EID_OP);

        // recorded the registry version it synced to
        assertEq(IConfigurableOFT(adapter).syncedConfigVersion(), configRegistry.configVersion());
    }

    // With NO pathway configured yet, deploy still registers the bridge, but syncConfig is a
    // harmless no-op (activeDstEids is empty) — a later pushToAll will configure it.
    function test_deployAdapter_autoRegisters_butNoConfigCalls_whenNoPathways() public {
        address adapter = _deployAdapter(address(token6));

        assertEq(configRegistry.numBridges(), 1); // still registered
        assertEq(endpoint.configCallCount(), 0); // no destinations -> nothing to configure
        assertEq(IConfigurableOFT(adapter).syncedConfigVersion(), 0);
    }

    // Fail-hard: if the factory lacks CONFIG_REGISTRAR_ROLE, the registerBridge call inside deploy
    // reverts and the WHOLE deploy reverts — no half-configured bridge is ever left behind.
    function test_deployAdapter_failsHard_whenFactoryLacksRegistrarRole() public {
        // cache the role BEFORE the prank: vm.prank applies to the next call, and reading
        // configRegistry.CONFIG_REGISTRAR_ROLE() is itself a call that would consume the prank.
        bytes32 registrarRole = configRegistry.CONFIG_REGISTRAR_ROLE();
        vm.prank(owner);
        roleRegistry.revokeRole(registrarRole, address(adapterFactory));

        vm.prank(factoryAdmin);
        vm.expectRevert(IOFTConfigRegistry.OnlyRegistrar.selector); // bubbles up from registerBridge
        adapterFactory.deployAdapter(keccak256(abi.encode(address(token6))), address(token6), delegate);

        // the revert rolled everything back: no adapter recorded, no bridge registered
        assertEq(adapterFactory.numAdaptersDeployed(), 0);
        assertEq(configRegistry.numBridges(), 0);
    }

    // deploy records both directions of the underlying<->adapter mapping.
    function test_deployAdapter_setsMappings() public {
        address adapter = _deployAdapter(address(token6));
        assertEq(adapterFactory.adapterOf(address(token6)), adapter);
        assertEq(adapterFactory.underlyingOf(adapter), address(token6));
        assertEq(EtherFiOFTAdapter(adapter).token(), address(token6));
    }

    // Only the factory admin role may deploy.
    function test_deployAdapter_reverts_whenNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(IOFTAdapterFactory.OnlyAdmin.selector);
        adapterFactory.deployAdapter(keccak256("x"), address(token6), delegate);
    }

    // A zero underlying token is rejected.
    function test_deployAdapter_reverts_onZeroUnderlying() public {
        vm.prank(factoryAdmin);
        vm.expectRevert(IOFTAdapterFactory.InvalidUnderlying.selector);
        adapterFactory.deployAdapter(keccak256("x"), address(0), delegate);
    }

    // One adapter per underlying: a second deploy for the same token reverts (even with a new salt).
    function test_deployAdapter_reverts_whenUnderlyingAlreadyHasAdapter() public {
        _deployAdapter(address(token6));
        vm.prank(factoryAdmin);
        vm.expectRevert(IOFTAdapterFactory.AdapterAlreadyExists.selector);
        adapterFactory.deployAdapter(keccak256("different-salt"), address(token6), delegate);
    }

    // Deploy is blocked while the factory is paused.
    function test_deployAdapter_reverts_whenPaused() public {
        vm.prank(pauser);
        adapterFactory.pause();
        vm.prank(factoryAdmin);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        adapterFactory.deployAdapter(keccak256("x"), address(token6), delegate);
    }

    // ----------------------------------------------------------------- shadow factory

    // Deploying a shadow OFT threads the `decimals` arg into the iTOKEN AND auto-registers/syncs
    // it (the shadow-side equivalent of the adapter auto-sync test).
    function test_deployShadowOFT_threadsDecimals_andAutoSyncs() public {
        _setPathwayOP();

        vm.prank(factoryAdmin);
        address shadow = shadowFactory.deployShadowOFT(keccak256("iWBTC"), "EtherFi WBTC", "iWBTC", 8, delegate);

        assertEq(EtherFiShadowOFT(shadow).decimals(), 8); // decimals threaded through to the iTOKEN
        assertEq(configRegistry.numBridges(), 1);
        assertEq(endpoint.configCallCount(), 2); // send + receive lib
        assertEq(IConfigurableOFT(shadow).syncedConfigVersion(), configRegistry.configVersion());
    }

    // Only the factory admin role may deploy a shadow OFT.
    function test_deployShadowOFT_reverts_whenNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(IShadowOFTFactory.OnlyAdmin.selector);
        shadowFactory.deployShadowOFT(keccak256("iUSDC"), "EtherFi USDC", "iUSDC", 6, delegate);
    }

    // The shadow factory dedupes by predicted CREATE3 address, so reusing a salt reverts.
    function test_deployShadowOFT_reverts_onDuplicateSalt() public {
        vm.startPrank(factoryAdmin);
        shadowFactory.deployShadowOFT(keccak256("iUSDC"), "EtherFi USDC", "iUSDC", 6, delegate);
        vm.expectRevert(IShadowOFTFactory.ShadowOFTAlreadyExists.selector);
        shadowFactory.deployShadowOFT(keccak256("iUSDC"), "EtherFi USDC", "iUSDC", 6, delegate); // same salt
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- pagination (returns empty past end)

    // getDeployedAdapters follows the pagination contract: full list, empty at/after the end, clamp.
    function test_getDeployedAdapters_returnsEmpty_whenStartPastEnd() public {
        _deployAdapter(address(token6));
        _deployAdapter(address(token8));
        assertEq(adapterFactory.getDeployedAdapters(0, 10).length, 2);
        assertEq(adapterFactory.getDeployedAdapters(2, 5).length, 0); // start == length -> empty
        assertEq(adapterFactory.getDeployedAdapters(99, 5).length, 0); // start past end -> empty
        assertEq(adapterFactory.getDeployedAdapters(1, 10).length, 1); // over-long count clamps to remaining
    }

    // getDeployedShadowOFTs follows the same pagination contract.
    function test_getDeployedShadowOFTs_returnsEmpty_whenStartPastEnd() public {
        vm.startPrank(factoryAdmin);
        shadowFactory.deployShadowOFT(keccak256("iUSDC"), "EtherFi USDC", "iUSDC", 6, delegate);
        shadowFactory.deployShadowOFT(keccak256("iWBTC"), "EtherFi WBTC", "iWBTC", 8, delegate);
        vm.stopPrank();
        assertEq(shadowFactory.getDeployedShadowOFTs(0, 10).length, 2);
        assertEq(shadowFactory.getDeployedShadowOFTs(2, 5).length, 0);
        assertEq(shadowFactory.getDeployedShadowOFTs(99, 5).length, 0);
        assertEq(shadowFactory.getDeployedShadowOFTs(1, 10).length, 1);
    }
}
