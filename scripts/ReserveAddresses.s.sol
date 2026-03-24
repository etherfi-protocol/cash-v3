// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { UUPSProxy } from "../src/UUPSProxy.sol";
import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";
import { EtherFiPlaceholder } from "../src/utils/EtherFiPlaceholder.sol";

/// @title ReserveAddresses
/// @notice Deploys RoleRegistry + SafeFactory placeholder at deterministic addresses to reserve
///         prod CREATE3 salts on chains where the protocol is not yet deployed.
///
/// Usage:
///   PRIVATE_KEY=0x... forge script scripts/ReserveAddresses.s.sol --rpc-url <RPC> --broadcast
contract ReserveAddresses is Script {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant OWNER = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    bytes32 constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant OZ_INIT_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 constant ROLE_REGISTRY_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;

    // Prod proxy salts (fetched from Scroll mainnet Nick's factory calls)
    bytes32 constant SALT_ROLE_REGISTRY_PROXY = 0x6cae761c5315d96c88fdeb2bdf7f689cb66abc92a4e823b7954d41f88321bd0e;
    bytes32 constant SALT_SAFE_FACTORY_PROXY  = 0x4039d84c2c2b96cb1babbf2ca5c0b7be213be8ad0110e70d6e2d570741ef168b;

    // Impl salts (random, just for deterministic deployment so verification can check impl addresses)
    bytes32 constant SALT_ROLE_REGISTRY_IMPL  = keccak256("ReserveAddresses.RoleRegistryImpl");
    bytes32 constant SALT_PLACEHOLDER_IMPL    = keccak256("ReserveAddresses.EtherFiPlaceholderImpl");

    function deployCreate3(bytes memory creationCode, bytes32 salt) internal returns (address deployed) {
        deployed = CREATE3.predictDeterministicAddress(salt, NICKS_FACTORY);

        if (deployed.code.length > 0) {
            console.log("  [SKIP] already deployed at", deployed);
            return deployed;
        }

        address proxy = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", NICKS_FACTORY, salt, CREATE3.PROXY_INITCODE_HASH)))));

        bool ok;
        if (proxy.code.length == 0) {
            (ok,) = NICKS_FACTORY.call(abi.encodePacked(salt, hex"67363d3d37363d34f03d5260086018f3"));
            require(ok, "CREATE3 proxy deploy failed");
        }

        (ok,) = proxy.call(creationCode);
        require(ok, "CREATE3 contract deploy failed");

        require(deployed.code.length > 0, "CREATE3 deployment verification failed");
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("=== Reserve Addresses ===");
        console.log("Chain ID:", block.chainid);
        console.log("Owner:", OWNER);

        require(NICKS_FACTORY.code.length > 0, "Nick's factory not deployed on this chain");

        address predictedRoleRegistry = CREATE3.predictDeterministicAddress(SALT_ROLE_REGISTRY_PROXY, NICKS_FACTORY);
        address predictedSafeFactory = CREATE3.predictDeterministicAddress(SALT_SAFE_FACTORY_PROXY, NICKS_FACTORY);
        console.log("Predicted RoleRegistry:", predictedRoleRegistry);
        console.log("Predicted SafeFactory: ", predictedSafeFactory);

        vm.startBroadcast(deployerPrivateKey);

        // ── 1. Deploy RoleRegistry (real impl, OWNER as owner) ──
        // NOTE: etherFiDataProvider is address(0) because this is a placeholder impl for address reservation only.
        //       A new impl with the real etherFiDataProvider must be deployed when upgrading to production.
        console.log("1. Deploying RoleRegistry...");
        address roleRegistryImpl = deployCreate3(
            abi.encodePacked(type(RoleRegistry).creationCode, abi.encode(address(0))),
            SALT_ROLE_REGISTRY_IMPL
        );
        address roleRegistry = deployCreate3(
            abi.encodePacked(
                type(UUPSProxy).creationCode,
                abi.encode(roleRegistryImpl, abi.encodeCall(RoleRegistry.initialize, (OWNER)))
            ),
            SALT_ROLE_REGISTRY_PROXY
        );
        console.log("  RoleRegistry impl: ", roleRegistryImpl);
        console.log("  RoleRegistry proxy:", roleRegistry);

        // ── 2. Deploy SafeFactory placeholder (upgradeable, controlled by RoleRegistry) ──
        console.log("2. Deploying SafeFactory placeholder...");
        address placeholderImpl = deployCreate3(
            abi.encodePacked(type(EtherFiPlaceholder).creationCode),
            SALT_PLACEHOLDER_IMPL
        );
        address safeFactory = deployCreate3(
            abi.encodePacked(
                type(UUPSProxy).creationCode,
                abi.encode(placeholderImpl, abi.encodeCall(EtherFiPlaceholder.initialize, (predictedRoleRegistry)))
            ),
            SALT_SAFE_FACTORY_PROXY
        );
        console.log("  Placeholder impl:  ", placeholderImpl);
        console.log("  SafeFactory proxy: ", safeFactory);

        vm.stopBroadcast();

        // ── 3. Verification ──
        console.log("");
        console.log("=== Verification ===");
        _verify(roleRegistry, safeFactory);
    }

    function _verify(address roleRegistry, address safeFactory) internal view {
        address expectedRRImpl = CREATE3.predictDeterministicAddress(SALT_ROLE_REGISTRY_IMPL, NICKS_FACTORY);
        address expectedPHImpl = CREATE3.predictDeterministicAddress(SALT_PLACEHOLDER_IMPL, NICKS_FACTORY);

        // RoleRegistry checks
        require(roleRegistry.code.length > 0, "RoleRegistry has no code");
        address rrImpl = address(uint160(uint256(vm.load(roleRegistry, EIP1967_IMPL_SLOT))));
        require(rrImpl == expectedRRImpl, "RoleRegistry impl address mismatch");
        require(rrImpl.code.length > 0, "RoleRegistry impl has no code");
        require(uint256(vm.load(roleRegistry, OZ_INIT_SLOT)) > 0, "RoleRegistry not initialized");
        require(RoleRegistry(roleRegistry).owner() == OWNER, "RoleRegistry wrong owner");
        console.log("[OK] RoleRegistry proxy:", roleRegistry);
        console.log("     impl:", rrImpl);
        console.log("     owner:", OWNER);

        // SafeFactory checks
        require(safeFactory.code.length > 0, "SafeFactory has no code");
        address sfImpl = address(uint160(uint256(vm.load(safeFactory, EIP1967_IMPL_SLOT))));
        require(sfImpl == expectedPHImpl, "SafeFactory impl address mismatch");
        require(sfImpl.code.length > 0, "SafeFactory impl has no code");
        require(uint256(vm.load(safeFactory, OZ_INIT_SLOT)) > 0, "SafeFactory not initialized");
        address storedRR = address(uint160(uint256(vm.load(safeFactory, ROLE_REGISTRY_SLOT))));
        require(storedRR == roleRegistry, "SafeFactory wrong roleRegistry");
        console.log("[OK] SafeFactory proxy:", safeFactory);
        console.log("     impl:", sfImpl);
        console.log("     roleRegistry:", storedRR);

        // Upgrade auth check
        try RoleRegistry(roleRegistry).onlyUpgrader(OWNER) {
            console.log("[OK] OWNER is authorized upgrader");
        } catch {
            revert("OWNER cannot upgrade");
        }
    }
}
