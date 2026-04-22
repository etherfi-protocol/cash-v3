// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { RecoveryModule } from "../../src/modules/recovery/RecoveryModule.sol";
import { TopUpDispatcher } from "../../src/top-up/TopUpDispatcher.sol";
import { TopUpV2 } from "../../src/top-up/TopUpV2.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { RecoveryDeployConfig, RecoveryDeployHelper } from "./RecoveryDeployConfig.sol";

/**
 * @title VerifyRecoveryDeployment
 * @notice Post-deployment invariant verifier for the Fund Recovery Module.
 *         Reverts with `require()` on any mismatch so CI can trust the exit code.
 *
 * Run modes (per chain):
 *   - Optimism: set RECOVERY_MODULE_OP, verifies the OP-side module.
 *   - Dest chain: set DISPATCHER, optionally TOPUP_V2_IMPL + BEACON, verifies that chain.
 *
 * Usage (foundry):
 *   RECOVERY_MODULE_OP=0x... forge script scripts/recovery/VerifyRecoveryDeployment.s.sol --rpc-url $OP_RPC
 *   DISPATCHER=0x... TOPUP_V2_IMPL=0x... BEACON=0x... forge script scripts/recovery/VerifyRecoveryDeployment.s.sol --rpc-url $DEST_RPC
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
        address moduleProxy = vm.envAddress("RECOVERY_MODULE_OP");
        console.log("RecoveryModule proxy: %s", moduleProxy);

        // 1. Proxy has code
        require(moduleProxy.code.length > 0, "module proxy has no code");

        // 2. EIP-1967 impl slot matches CREATE3-predicted impl
        address expectedImpl = _predictImpl(RecoveryDeployConfig.SALT_RECOVERY_MODULE_IMPL);
        address actualImpl = address(uint160(uint256(
            vm.load(moduleProxy, RecoveryDeployConfig.EIP1967_IMPL_SLOT)
        )));
        require(actualImpl == expectedImpl, "RecoveryModule impl mismatch - possible hijack");
        require(actualImpl.code.length > 0, "RecoveryModule impl has no code");
        console.log("  [OK] impl at predicted address: %s", actualImpl);

        // 3. Initialized
        uint256 initSlot = uint256(vm.load(moduleProxy, RecoveryDeployConfig.OZ_INIT_SLOT));
        require(initSlot > 0, "module not initialized");
        console.log("  [OK] initialized (v=%s)", initSlot);

        // 4. Owner is the operating safe
        address moduleOwner = RecoveryModule(moduleProxy).owner();
        require(moduleOwner == RecoveryDeployConfig.OPERATING_SAFE, "module owner != OPERATING_SAFE");
        console.log("  [OK] owner == operating safe");

        // 5. Timelock is 3 days
        require(uint256(RecoveryModule(moduleProxy).TIMELOCK()) == 3 days, "timelock != 3 days");
        console.log("  [OK] TIMELOCK == 3 days");

        // 6. Optional: module whitelisted on the data provider (only checkable after 3CP sign-off)
        try vm.envAddress("ETHER_FI_DATA_PROVIDER") returns (address dp) {
            // The dataProvider's module-approval accessor name varies across impls; just check
            // the happy-path view exposed by the provider interface used by ModuleBase.
            bool approved = EtherFiDataProvider(dp).isWhitelistedModule(moduleProxy);
            require(approved, "module not whitelisted on data provider");
            console.log("  [OK] whitelisted on DataProvider");
        } catch {
            console.log("  [SKIP] DataProvider whitelist check (no ETHER_FI_DATA_PROVIDER env)");
        }
    }

    function _verifyDestChain() internal view {
        address dispatcherProxy = vm.envAddress("DISPATCHER");
        console.log("TopUpDispatcher proxy: %s", dispatcherProxy);

        // 1. Proxy has code
        require(dispatcherProxy.code.length > 0, "dispatcher proxy has no code");

        // 2. EIP-1967 impl slot matches CREATE3-predicted impl
        address expectedImpl = _predictImpl(RecoveryDeployConfig.SALT_TOPUP_DISPATCHER_IMPL);
        address actualImpl = address(uint160(uint256(
            vm.load(dispatcherProxy, RecoveryDeployConfig.EIP1967_IMPL_SLOT)
        )));
        require(actualImpl == expectedImpl, "TopUpDispatcher impl mismatch - possible hijack");
        require(actualImpl.code.length > 0, "TopUpDispatcher impl has no code");
        console.log("  [OK] impl at predicted address: %s", actualImpl);

        // 3. Initialized
        uint256 initSlot = uint256(vm.load(dispatcherProxy, RecoveryDeployConfig.OZ_INIT_SLOT));
        require(initSlot > 0, "dispatcher not initialized");
        console.log("  [OK] initialized (v=%s)", initSlot);

        // 4. Owner is the operating safe
        address dispatcherOwner = TopUpDispatcher(dispatcherProxy).owner();
        require(dispatcherOwner == RecoveryDeployConfig.OPERATING_SAFE, "dispatcher owner != OPERATING_SAFE");
        console.log("  [OK] owner == operating safe");

        // 5. SOURCE_EID is OP
        require(
            uint256(TopUpDispatcher(dispatcherProxy).SOURCE_EID()) == uint256(RecoveryDeployConfig.OP_EID),
            "dispatcher SOURCE_EID != 30111"
        );
        console.log("  [OK] SOURCE_EID == 30111 (Optimism)");

        // 6. TopUpV2 impl checks (optional — only after beacon upgrade is signed)
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
