// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";

/// @title VerifyReservedAddresses
/// @notice Post-deployment verification for reserved RoleRegistry + SafeFactory addresses.
///         Run against live RPC AFTER broadcast txs have confirmed.
///
/// Usage:
///   forge script scripts/VerifyReservedAddresses.s.sol --rpc-url <RPC>
contract VerifyReservedAddresses is Script {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant OWNER = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    bytes32 constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant OZ_INIT_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 constant ROLE_REGISTRY_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;

    bytes32 constant SALT_ROLE_REGISTRY_PROXY = 0x6cae761c5315d96c88fdeb2bdf7f689cb66abc92a4e823b7954d41f88321bd0e;
    bytes32 constant SALT_SAFE_FACTORY_PROXY  = 0x4039d84c2c2b96cb1babbf2ca5c0b7be213be8ad0110e70d6e2d570741ef168b;

    // Impl salts (must match ReserveAddresses.s.sol)
    bytes32 constant SALT_ROLE_REGISTRY_IMPL  = keccak256("ReserveAddresses.RoleRegistryImpl");
    bytes32 constant SALT_PLACEHOLDER_IMPL    = keccak256("ReserveAddresses.EtherFiPlaceholderImpl");

    function run() public view {
        address roleRegistry = CREATE3.predictDeterministicAddress(SALT_ROLE_REGISTRY_PROXY, NICKS_FACTORY);
        address safeFactory = CREATE3.predictDeterministicAddress(SALT_SAFE_FACTORY_PROXY, NICKS_FACTORY);

        console.log("==========================================");
        console.log("  Verify Reserved Addresses (Post-Deploy)");
        console.log("==========================================");
        console.log("Chain ID:", block.chainid);
        console.log("RoleRegistry:", roleRegistry);
        console.log("SafeFactory: ", safeFactory);
        console.log("");

        // ── 1. Contract existence ──
        console.log("--- 1. Contract existence ---");
        _checkCode("RoleRegistry", roleRegistry);
        _checkCode("SafeFactory", safeFactory);

        // ── 2. EIP-1967 impl addresses ──
        address expectedRRImpl = CREATE3.predictDeterministicAddress(SALT_ROLE_REGISTRY_IMPL, NICKS_FACTORY);
        address expectedPHImpl = CREATE3.predictDeterministicAddress(SALT_PLACEHOLDER_IMPL, NICKS_FACTORY);

        console.log("");
        console.log("--- 2. Impl addresses ---");
        _checkImpl("RoleRegistry", roleRegistry, expectedRRImpl);
        _checkImpl("SafeFactory", safeFactory, expectedPHImpl);

        // ── 3. Initialization ──
        console.log("");
        console.log("--- 3. Initialization ---");
        _checkInit("RoleRegistry", roleRegistry);
        _checkInit("SafeFactory", safeFactory);

        // ── 4. RoleRegistry ownership ──
        console.log("");
        console.log("--- 4. Ownership ---");
        if (roleRegistry.code.length > 0) {
            address owner = RoleRegistry(roleRegistry).owner();
            if (owner == OWNER) {
                console.log("  [OK] RoleRegistry owner =", owner);
            } else {
                console.log("  [FAIL] RoleRegistry owner mismatch");
                console.log("    actual:  ", owner);
                console.log("    expected:", OWNER);
            }
        }

        // ── 5. SafeFactory points to our RoleRegistry ──
        console.log("");
        console.log("--- 5. SafeFactory roleRegistry ref ---");
        if (safeFactory.code.length > 0) {
            address storedRR = address(uint160(uint256(vm.load(safeFactory, ROLE_REGISTRY_SLOT))));
            if (storedRR == roleRegistry) {
                console.log("  [OK] SafeFactory -> RoleRegistry");
            } else {
                console.log("  [FAIL] SafeFactory wrong roleRegistry");
                console.log("    stored:  ", storedRR);
                console.log("    expected:", roleRegistry);
            }
        }

        // ── 6. Upgrade authorization ──
        console.log("");
        console.log("--- 6. Upgrade auth ---");
        if (roleRegistry.code.length > 0) {
            try RoleRegistry(roleRegistry).onlyUpgrader(OWNER) {
                console.log("  [OK] OWNER can upgrade SafeFactory");
            } catch {
                console.log("  [FAIL] OWNER cannot upgrade");
            }
        }

        console.log("");
        console.log("==========================================");
    }

    function _checkCode(string memory name, address addr) internal view {
        if (addr.code.length > 0) {
            console.log(string.concat("  [OK] ", name));
        } else {
            console.log(string.concat("  [FAIL] ", name, " - no code"));
        }
    }

    function _checkImpl(string memory name, address proxy, address expectedImpl) internal view {
        if (proxy.code.length == 0) return;
        address impl = address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
        if (impl == expectedImpl && impl.code.length > 0) {
            console.log(string.concat("  [OK] ", name, " impl="), impl);
        } else if (impl != expectedImpl) {
            console.log(string.concat("  [FAIL] ", name, " impl mismatch"));
            console.log("    actual:  ", impl);
            console.log("    expected:", expectedImpl);
        } else {
            console.log(string.concat("  [FAIL] ", name, " impl has no code"));
        }
    }

    function _checkInit(string memory name, address proxy) internal view {
        if (proxy.code.length == 0) return;
        uint256 v = uint256(vm.load(proxy, OZ_INIT_SLOT));
        if (v > 0) {
            console.log(string.concat("  [OK] ", name, " initialized (v=", vm.toString(v), ")"));
        } else {
            console.log(string.concat("  [FAIL] ", name, " - NOT initialized"));
        }
    }
}
