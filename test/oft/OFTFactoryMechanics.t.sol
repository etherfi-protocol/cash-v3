// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CREATE3 } from "solady/utils/CREATE3.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { BeaconFactory } from "../../src/beacon-factory/BeaconFactory.sol";
import { EtherFiOFTAdapter } from "../../src/oft/EtherFiOFTAdapter.sol";
import { EtherFiShadowOFT } from "../../src/oft/EtherFiShadowOFT.sol";
import { OFTAdapterFactory } from "../../src/oft/OFTAdapterFactory.sol";
import { UpgradeableProxy } from "../../src/utils/UpgradeableProxy.sol";
import { OFTTestSetup } from "./OFTTestSetup.t.sol";

/**
 * Beacon-impl V2s: same storage layout, plus a probe so we can confirm a beacon upgrade swaps the
 * logic seen by EXISTING proxies while their per-proxy storage is preserved.
 */
contract EtherFiOFTAdapterV2 is EtherFiOFTAdapter {
    constructor(address ep, address reg) EtherFiOFTAdapter(ep, reg) { }

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract EtherFiShadowOFTV2 is EtherFiShadowOFT {
    constructor(address ep, address reg) EtherFiShadowOFT(ep, reg) { }

    function version() external pure returns (uint256) {
        return 2;
    }
}

/**
 * @title OFTFactoryMechanicsTest
 * @notice CREATE3 determinism (predicted == deployed, deployer-scoped, salt-collision reverts)
 *         and beacon upgrade mechanics (existing proxies pick up new logic, per-proxy storage
 *         survives, upgrade is gated to the RoleRegistry owner).
 */
contract OFTFactoryMechanicsTest is OFTTestSetup {
    function _deployAdapter(bytes32 salt, address token) internal returns (address) {
        vm.prank(factoryAdmin);
        return adapterFactory.deployAdapter(salt, token, delegate);
    }

    // ----------------------------------------------------------------- CREATE3 determinism

    // The deployed adapter lands exactly at the address the factory predicts for its salt.
    function test_create3_predictedEqualsDeployed() public {
        bytes32 salt = keccak256("usdc-adapter");
        address predicted = adapterFactory.getDeterministicAddress(salt);
        address deployed = _deployAdapter(salt, address(token6));
        assertEq(deployed, predicted);
    }

    // CREATE3 addresses are scoped to the deploying factory: the SAME salt on a second factory
    // instance predicts a DIFFERENT address (so two chains' factories don't have to collide).
    function test_create3_sameSaltDifferentFactory_differentAddress() public {
        bytes32 salt = keccak256("shared-salt");

        // a second, independent adapter factory instance
        vm.startPrank(owner);
        address factoryImpl = address(new OFTAdapterFactory());
        OFTAdapterFactory factory2 = OFTAdapterFactory(address(new UUPSProxy(factoryImpl, abi.encodeWithSelector(OFTAdapterFactory.initialize.selector, address(roleRegistry), adapterImpl))));
        vm.stopPrank();

        assertTrue(adapterFactory.getDeterministicAddress(salt) != factory2.getDeterministicAddress(salt), "CREATE3 address not scoped to deployer");
    }

    // Reusing a salt within one factory (for a different underlying) collides at the CREATE3 slot
    // and reverts — no silent overwrite of an existing proxy.
    function test_create3_saltCollision_reverts() public {
        bytes32 salt = keccak256("collide");
        _deployAdapter(salt, address(token6));

        vm.prank(factoryAdmin);
        vm.expectRevert(CREATE3.DeploymentFailed.selector);
        adapterFactory.deployAdapter(salt, address(token8), delegate); // same salt, new underlying
    }

    // ----------------------------------------------------------------- beacon upgrade

    // Upgrading the adapter beacon impl swaps logic for EXISTING proxies while preserving their
    // per-proxy ERC-7201 storage (underlying + conversion rate).
    function test_beaconUpgrade_adapter_newLogic_storagePreserved() public {
        address adapter = _deployAdapter(keccak256("wbtc"), address(token8));
        assertEq(EtherFiOFTAdapter(adapter).token(), address(token8));
        assertEq(EtherFiOFTAdapter(adapter).conversionRate(), 100); // 10**(8-6)

        // BEFORE: V1 impl has no version() — the call finds no selector and reverts.
        (bool okBefore,) = adapter.staticcall(abi.encodeWithSignature("version()"));
        assertFalse(okBefore, "version() existed before the upgrade - logic did not actually change");

        address implV2 = address(new EtherFiOFTAdapterV2(address(endpoint), address(configRegistry)));
        vm.prank(owner); // RoleRegistry owner
        adapterFactory.upgradeBeaconImplementation(implV2);

        // AFTER: the existing proxy now runs V2 logic that did not exist before...
        (bool okAfter, bytes memory ret) = adapter.staticcall(abi.encodeWithSignature("version()"));
        assertTrue(okAfter, "version() missing after the upgrade");
        assertEq(abi.decode(ret, (uint256)), 2);
        // ...with its storage intact
        assertEq(EtherFiOFTAdapter(adapter).token(), address(token8));
        assertEq(EtherFiOFTAdapter(adapter).conversionRate(), 100);
    }

    function test_beaconUpgrade_shadow_newLogic_storagePreserved() public {
        vm.prank(factoryAdmin);
        address shadow = shadowFactory.deployShadowOFT(keccak256("iWBTC"), "EtherFi WBTC", "iWBTC", 8, delegate);
        assertEq(EtherFiShadowOFT(shadow).decimals(), 8);

        // BEFORE: V1 impl has no version().
        (bool okBefore,) = shadow.staticcall(abi.encodeWithSignature("version()"));
        assertFalse(okBefore, "version() existed before the upgrade - logic did not actually change");

        address implV2 = address(new EtherFiShadowOFTV2(address(endpoint), address(configRegistry)));
        vm.prank(owner);
        shadowFactory.upgradeBeaconImplementation(implV2);

        // AFTER: V2 logic is live on the existing proxy...
        (bool okAfter, bytes memory ret) = shadow.staticcall(abi.encodeWithSignature("version()"));
        assertTrue(okAfter, "version() missing after the upgrade");
        assertEq(abi.decode(ret, (uint256)), 2);
        // ...with storage preserved
        assertEq(EtherFiShadowOFT(shadow).decimals(), 8);
        assertEq(EtherFiShadowOFT(shadow).conversionRate(), 100);
    }

    // Only the RoleRegistry owner may upgrade a beacon impl.
    function test_beaconUpgrade_reverts_whenNotRoleRegistryOwner() public {
        address implV2 = address(new EtherFiOFTAdapterV2(address(endpoint), address(configRegistry)));
        vm.prank(alice);
        vm.expectRevert(UpgradeableProxy.OnlyRoleRegistryOwner.selector);
        adapterFactory.upgradeBeaconImplementation(implV2);
    }

    // A zero implementation is rejected.
    function test_beaconUpgrade_reverts_onZeroImpl() public {
        vm.prank(owner);
        vm.expectRevert(BeaconFactory.InvalidInput.selector);
        adapterFactory.upgradeBeaconImplementation(address(0));
    }
}
