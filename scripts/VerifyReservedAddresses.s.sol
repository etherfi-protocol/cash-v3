// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";

/// @title VerifyReservedAddresses
/// @notice Post-deployment verification for reserved RoleRegistry + SafeFactory addresses.
///         Reverts on any failed check so CI/scripts can rely on exit code.
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

        address expectedRRImpl = CREATE3.predictDeterministicAddress(SALT_ROLE_REGISTRY_IMPL, NICKS_FACTORY);
        address expectedPHImpl = CREATE3.predictDeterministicAddress(SALT_PLACEHOLDER_IMPL, NICKS_FACTORY);

        // ── 1. Contract existence ──
        console.log("--- 1. Contract existence ---");
        require(roleRegistry.code.length > 0, "RoleRegistry has no code");
        console.log("  [OK] RoleRegistry");
        require(safeFactory.code.length > 0, "SafeFactory has no code");
        console.log("  [OK] SafeFactory");

        // ── 2. EIP-1967 impl addresses ──
        console.log("");
        console.log("--- 2. Impl addresses ---");

        address rrImpl = address(uint160(uint256(vm.load(roleRegistry, EIP1967_IMPL_SLOT))));
        require(rrImpl == expectedRRImpl, "RoleRegistry impl mismatch — possible hijack");
        require(rrImpl.code.length > 0, "RoleRegistry impl has no code");
        console.log("  [OK] RoleRegistry impl=", rrImpl);

        address sfImpl = address(uint160(uint256(vm.load(safeFactory, EIP1967_IMPL_SLOT))));
        require(sfImpl == expectedPHImpl, "SafeFactory impl mismatch — possible hijack");
        require(sfImpl.code.length > 0, "SafeFactory impl has no code");
        console.log("  [OK] SafeFactory impl=", sfImpl);

        // ── 3. Initialization ──
        console.log("");
        console.log("--- 3. Initialization ---");

        uint256 rrInit = uint256(vm.load(roleRegistry, OZ_INIT_SLOT));
        require(rrInit > 0, "RoleRegistry NOT initialized");
        console.log("  [OK] RoleRegistry initialized (v=", vm.toString(rrInit), ")");

        uint256 sfInit = uint256(vm.load(safeFactory, OZ_INIT_SLOT));
        require(sfInit > 0, "SafeFactory NOT initialized");
        console.log("  [OK] SafeFactory initialized (v=", vm.toString(sfInit), ")");

        // ── 4. RoleRegistry ownership ──
        console.log("");
        console.log("--- 4. Ownership ---");

        address owner = RoleRegistry(roleRegistry).owner();
        require(owner == OWNER, "RoleRegistry wrong owner — possible hijack");
        console.log("  [OK] RoleRegistry owner =", owner);

        // ── 5. SafeFactory points to our RoleRegistry ──
        console.log("");
        console.log("--- 5. SafeFactory roleRegistry ref ---");

        address storedRR = address(uint160(uint256(vm.load(safeFactory, ROLE_REGISTRY_SLOT))));
        require(storedRR == roleRegistry, "SafeFactory wrong roleRegistry — possible hijack");
        console.log("  [OK] SafeFactory -> RoleRegistry");

        // ── 6. Upgrade authorization ──
        console.log("");
        console.log("--- 6. Upgrade auth ---");

        RoleRegistry(roleRegistry).onlyUpgrader(OWNER); // reverts internally if not authorized
        console.log("  [OK] OWNER can upgrade");

        console.log("");
        console.log("==========================================");
        console.log("  ALL CHECKS PASSED");
        console.log("==========================================");
    }
}
