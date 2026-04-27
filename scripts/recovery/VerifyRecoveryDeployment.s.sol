// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { RecoveryModule } from "../../src/modules/recovery/RecoveryModule.sol";
import { RecoveryDispatcher } from "../../src/top-up/RecoveryDispatcher.sol";
import { TopUpV2 } from "../../src/top-up/TopUpV2.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { RecoveryDeployConfig, RecoveryDeployHelper } from "./RecoveryDeployConfig.sol";

/**
 * @title VerifyRecoveryDeployment
 * @notice Post-deployment invariant verifier for the Fund Recovery Module.
 *         Reverts with `require()` on any mismatch so CI can trust the exit code.
 *
 * Run modes (per chain):
 *   - Optimism: set RECOVERY_MODULE_OP, LZ_ENDPOINT, ETHER_FI_DATA_PROVIDER; verifies the OP-side module.
 *   - Dest chain: set DISPATCHER, LZ_ENDPOINT, ROLE_REGISTRY; optionally TOPUP_V2_IMPL + BEACON; verifies that chain.
 *
 * LZ_ENDPOINT, ETHER_FI_DATA_PROVIDER (OP), and ROLE_REGISTRY (dest) are *required* because the
 * CREATE3 helper is idempotent — without them a prior bad deploy with wrong endpoint/registry
 * immutables would still pass the owner/timelock checks while breaking `lzReceive`,
 * `onlyEtherFiSafe`, or pause/unpause in production.
 *
 * Usage (foundry):
 *   RECOVERY_MODULE_OP=0x... LZ_ENDPOINT=0x... ETHER_FI_DATA_PROVIDER=0x... \
 *     forge script scripts/recovery/VerifyRecoveryDeployment.s.sol --rpc-url $OP_RPC
 *   DISPATCHER=0x... LZ_ENDPOINT=0x... ROLE_REGISTRY=0x... TOPUP_V2_IMPL=0x... BEACON=0x... \
 *     forge script scripts/recovery/VerifyRecoveryDeployment.s.sol --rpc-url $DEST_RPC
 */
contract VerifyRecoveryDeployment is Script, RecoveryDeployHelper {
    function run() external view {
        console.log("=== Verify Fund Recovery Deployment ===");
        console.log("Chain ID: %s", block.chainid);

        if (block.chainid == 10) {
            _verifyOptimism();
        } else {
            _verifyDestChain();
        }
    }

    function _verifyOptimism() internal view {
        address module = vm.envAddress("RECOVERY_MODULE_OP");
        console.log("RecoveryModule: %s", module);

        // 1. Module has code at the CREATE3-predicted address
        address expected = _predictImpl(RecoveryDeployConfig.SALT_RECOVERY_MODULE);
        require(module == expected, "RecoveryModule address mismatch - wrong salt or stale CREATE3");
        require(module.code.length > 0, "RecoveryModule has no code");
        console.log("  [OK] at predicted CREATE3 address: %s", module);

        // 2. Owner is the operating safe (set by constructor — non-upgradable)
        address moduleOwner = RecoveryModule(module).owner();
        require(moduleOwner == RecoveryDeployConfig.OPERATING_SAFE, "module owner != OPERATING_SAFE");
        console.log("  [OK] owner == operating safe");

        // 3. LayerZero endpoint immutable matches expected endpoint (required — catches stale CREATE3 reuse)
        address expectedEndpoint = vm.envAddress("LZ_ENDPOINT");
        address moduleEndpoint = address(RecoveryModule(module).endpoint());
        require(moduleEndpoint == expectedEndpoint, "RecoveryModule.endpoint != LZ_ENDPOINT - wrong-endpoint risk");
        console.log("  [OK] endpoint == LZ_ENDPOINT");

        // 4. DataProvider immutable matches expected provider (required — catches wrong onlyEtherFiSafe registry)
        address expectedDp = vm.envAddress("ETHER_FI_DATA_PROVIDER");
        address moduleDp = address(RecoveryModule(module).etherFiDataProvider());
        require(moduleDp == expectedDp, "RecoveryModule.etherFiDataProvider != ETHER_FI_DATA_PROVIDER - wrong-registry risk");
        console.log("  [OK] etherFiDataProvider == ETHER_FI_DATA_PROVIDER");

        // 5. Module whitelisted on the data provider — only true AFTER the operating safe's
        //    first 3CP sign-off (`configureModules`). Pre-signing this is expected to be
        //    false, so the assertion is gated on `EXPECT_WHITELISTED=1`. Without that env,
        //    we just log the current state.
        bool approved = EtherFiDataProvider(expectedDp).isWhitelistedModule(module);
        if (_expectWhitelisted()) {
            require(approved, "module not whitelisted on data provider");
            console.log("  [OK] whitelisted on DataProvider");
        } else {
            console.log("  [INFO] DataProvider whitelist status: %s (set EXPECT_WHITELISTED=1 to assert)", approved ? "true" : "false");
        }
    }

    function _expectWhitelisted() internal view returns (bool) {
        try vm.envBool("EXPECT_WHITELISTED") returns (bool v) {
            return v;
        } catch {
            return false;
        }
    }

    function _verifyDestChain() internal view {
        address dispatcherProxy = vm.envAddress("DISPATCHER");
        console.log("RecoveryDispatcher proxy: %s", dispatcherProxy);

        // 1. Proxy has code
        require(dispatcherProxy.code.length > 0, "dispatcher proxy has no code");

        // 2. EIP-1967 impl slot matches CREATE3-predicted impl
        address expectedImpl = _predictImpl(RecoveryDeployConfig.SALT_RECOVERY_DISPATCHER_IMPL);
        address actualImpl = address(uint160(uint256(
            vm.load(dispatcherProxy, RecoveryDeployConfig.EIP1967_IMPL_SLOT)
        )));
        require(actualImpl == expectedImpl, "RecoveryDispatcher impl mismatch - possible hijack");
        require(actualImpl.code.length > 0, "RecoveryDispatcher impl has no code");
        console.log("  [OK] impl at predicted address: %s", actualImpl);

        // 3. Initialized
        uint256 initSlot = uint256(vm.load(dispatcherProxy, RecoveryDeployConfig.OZ_INIT_SLOT));
        require(initSlot > 0, "dispatcher not initialized");
        console.log("  [OK] initialized (v=%s)", initSlot);

        // 4. Owner is the operating safe
        address dispatcherOwner = RecoveryDispatcher(dispatcherProxy).owner();
        require(dispatcherOwner == RecoveryDeployConfig.OPERATING_SAFE, "dispatcher owner != OPERATING_SAFE");
        console.log("  [OK] owner == operating safe");

        // 5. SOURCE_EID is OP
        require(
            uint256(RecoveryDispatcher(dispatcherProxy).SOURCE_EID()) == uint256(RecoveryDeployConfig.OP_EID),
            "dispatcher SOURCE_EID != 30111"
        );
        console.log("  [OK] SOURCE_EID == 30111 (Optimism)");

        // 6. LayerZero endpoint immutable matches expected endpoint (required — catches stale CREATE3 reuse)
        address expectedEndpoint = vm.envAddress("LZ_ENDPOINT");
        address dispatcherEndpoint = address(RecoveryDispatcher(dispatcherProxy).endpoint());
        require(dispatcherEndpoint == expectedEndpoint, "RecoveryDispatcher.endpoint != LZ_ENDPOINT - wrong-endpoint risk");
        console.log("  [OK] endpoint == LZ_ENDPOINT");

        // 7. ROLE_REGISTRY immutable matches expected registry (required — wrong registry disables pause/unpause)
        address expectedRoleRegistry = vm.envAddress("ROLE_REGISTRY");
        address dispatcherRoleRegistry = address(RecoveryDispatcher(dispatcherProxy).ROLE_REGISTRY());
        require(dispatcherRoleRegistry == expectedRoleRegistry, "RecoveryDispatcher.ROLE_REGISTRY != ROLE_REGISTRY - pause gate misconfigured");
        console.log("  [OK] ROLE_REGISTRY == ROLE_REGISTRY env");

        // 8. TopUpV2 impl checks (optional — only after beacon upgrade is signed)
        try vm.envAddress("TOPUP_V2_IMPL") returns (address topUpImpl) {
            require(topUpImpl.code.length > 0, "TopUpV2 impl has no code");
            address topUpDispatcherSeen = TopUpV2(payable(topUpImpl)).DISPATCHER();
            require(topUpDispatcherSeen == dispatcherProxy, "TopUpV2.DISPATCHER != dispatcher proxy");
            console.log("  [OK] TopUpV2 impl at %s, DISPATCHER matches", topUpImpl);

            // Optional: if beacon address supplied, verify it points at this impl.
            try vm.envAddress("BEACON") returns (address beacon) {
                (bool ok, bytes memory data) = beacon.staticcall(abi.encodeWithSignature("implementation()"));
                require(ok && data.length == 32, "beacon.implementation() call failed");
                address beaconImpl = abi.decode(data, (address));
                require(beaconImpl == topUpImpl, "beacon impl != TopUpV2 impl");
                console.log("  [OK] beacon impl == TopUpV2 impl");
            } catch {
                console.log("  [SKIP] beacon check (no BEACON env)");
            }
        } catch {
            console.log("  [SKIP] TopUpV2 impl check (no TOPUP_V2_IMPL env)");
        }
    }
}
