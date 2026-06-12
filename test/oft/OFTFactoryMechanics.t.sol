// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CREATE3 } from "solady/utils/CREATE3.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { BeaconFactory } from "../../src/beacon-factory/BeaconFactory.sol";
import { EtherFiOFTAdapter } from "../../src/oft/EtherFiOFTAdapter.sol";
import { EtherFiShadowOFT } from "../../src/oft/EtherFiShadowOFT.sol";
import { OFTAdapterFactory } from "../../src/oft/OFTAdapterFactory.sol";
import { PairwiseRateLimiter } from "../../src/oft/PairwiseRateLimiter.sol";
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

    // The rate-limit state lives in its own ERC-7201 namespaced region, so a beacon upgrade that
    // swaps logic must leave it intact (the upgrade must not reset or shift configured caps).
    function test_beaconUpgrade_preservesRateLimitState() public {
        skip(10_000); // make the lastUpdated checkpoint unambiguously non-zero
        address adapter = _deployAdapter(keccak256("rl-wbtc"), address(token8));

        PairwiseRateLimiter.RateLimitConfig[] memory cfg = new PairwiseRateLimiter.RateLimitConfig[](1);
        cfg[0] = PairwiseRateLimiter.RateLimitConfig({ peerEid: DST_EID_OP, limit: 1234e8, window: 2 hours });
        vm.prank(delegate); // delegate == OApp owner
        PairwiseRateLimiter(adapter).setOutboundRateLimits(cfg);

        PairwiseRateLimiter.RateLimit memory before = PairwiseRateLimiter(adapter).outboundRateLimit(DST_EID_OP);
        assertEq(before.limit, 1234e8);
        assertEq(before.window, 2 hours);
        assertGt(before.lastUpdated, 0);

        // BEFORE: V1 has no version(), so the call finds no selector and reverts. This proves the
        // upgrade (not code that was already there) is what makes version() callable afterwards.
        (bool okBefore,) = adapter.staticcall(abi.encodeWithSignature("version()"));
        assertFalse(okBefore, "version() existed before the upgrade - logic did not actually change");

        address implV2 = address(new EtherFiOFTAdapterV2(address(endpoint), address(configRegistry)));
        vm.prank(owner); // RoleRegistry owner
        adapterFactory.upgradeBeaconImplementation(implV2);

        // V2 logic is live AND the namespaced rate-limit region is byte-for-byte preserved.
        (bool okAfter,) = adapter.staticcall(abi.encodeWithSignature("version()"));
        assertTrue(okAfter, "logic did not change");
        PairwiseRateLimiter.RateLimit memory afterUpg = PairwiseRateLimiter(adapter).outboundRateLimit(DST_EID_OP);
        assertEq(afterUpg.limit, before.limit, "limit not preserved across upgrade");
        assertEq(afterUpg.window, before.window, "window not preserved across upgrade");
        assertEq(afterUpg.lastUpdated, before.lastUpdated, "lastUpdated not preserved across upgrade");
    }

    // Same guarantee on the shadow (mint/burn) side: a beacon upgrade swaps logic while the
    // namespaced rate-limit region on existing iTOKEN proxies is preserved.
    function test_beaconUpgrade_shadow_preservesRateLimitState() public {
        skip(10_000); // make the lastUpdated checkpoint unambiguously non-zero
        vm.prank(factoryAdmin);
        address shadow = shadowFactory.deployShadowOFT(keccak256("rl-iWBTC"), "EtherFi WBTC", "iWBTC", 8, delegate);

        // Cap the inbound (receive-from-Ethereum) pathway.
        PairwiseRateLimiter.RateLimitConfig[] memory cfg = new PairwiseRateLimiter.RateLimitConfig[](1);
        cfg[0] = PairwiseRateLimiter.RateLimitConfig({ peerEid: DST_EID_ETH, limit: 1234e8, window: 2 hours });
        vm.prank(delegate); // delegate == OApp owner
        PairwiseRateLimiter(shadow).setInboundRateLimits(cfg);

        PairwiseRateLimiter.RateLimit memory before = PairwiseRateLimiter(shadow).inboundRateLimit(DST_EID_ETH);
        assertEq(before.limit, 1234e8);
        assertEq(before.window, 2 hours);
        assertGt(before.lastUpdated, 0);

        // BEFORE: V1 has no version(), so the call reverts — proving the upgrade is what adds it.
        (bool okBefore,) = shadow.staticcall(abi.encodeWithSignature("version()"));
        assertFalse(okBefore, "version() existed before the upgrade - logic did not actually change");

        address implV2 = address(new EtherFiShadowOFTV2(address(endpoint), address(configRegistry)));
        vm.prank(owner); // RoleRegistry owner
        shadowFactory.upgradeBeaconImplementation(implV2);

        // V2 logic is live AND the namespaced rate-limit region is byte-for-byte preserved.
        (bool okAfter,) = shadow.staticcall(abi.encodeWithSignature("version()"));
        assertTrue(okAfter, "logic did not change");
        PairwiseRateLimiter.RateLimit memory afterUpg = PairwiseRateLimiter(shadow).inboundRateLimit(DST_EID_ETH);
        assertEq(afterUpg.limit, before.limit, "limit not preserved across upgrade");
        assertEq(afterUpg.window, before.window, "window not preserved across upgrade");
        assertEq(afterUpg.lastUpdated, before.lastUpdated, "lastUpdated not preserved across upgrade");
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

    // Pause state lives in PausableUpgradeable's own ERC-7201 region, so a beacon upgrade that
    // swaps logic must leave a paused proxy paused (the upgrade must not reset the pause flag).
    function test_beaconUpgrade_preservesPauseState() public {
        address adapter = _deployAdapter(keccak256("pause-wbtc"), address(token8));
        assertFalse(EtherFiOFTAdapter(adapter).paused());

        // Pause the bridge directly (PAUSER-gated via the shared RoleRegistry).
        vm.prank(pauser);
        EtherFiOFTAdapter(adapter).pauseBridge();
        assertTrue(EtherFiOFTAdapter(adapter).paused());

        address implV2 = address(new EtherFiOFTAdapterV2(address(endpoint), address(configRegistry)));
        vm.prank(owner); // RoleRegistry owner
        adapterFactory.upgradeBeaconImplementation(implV2);

        // V2 logic is live AND the pause flag is preserved across the upgrade.
        (bool okAfter,) = adapter.staticcall(abi.encodeWithSignature("version()"));
        assertTrue(okAfter, "logic did not change");
        assertTrue(EtherFiOFTAdapter(adapter).paused(), "pause flag not preserved across upgrade");

        // And it can still be unpaused after the upgrade.
        vm.prank(unpauser);
        EtherFiOFTAdapter(adapter).unpauseBridge();
        assertFalse(EtherFiOFTAdapter(adapter).paused());
    }
}
