// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiPlaceholder } from "../../src/utils/EtherFiPlaceholder.sol";
import { TradingAccountCreate3, TradingAccountProdConfig as C } from "./TradingAccountProdConfig.sol";

/// @title ReserveTradingSafeFactoryAddress
/// @notice Reserves the production `TradingSafeFactory` CREATE3 address on every chain the protocol may
///         expand to, so the factory keeps a single cross-chain address the way `TopUpSourceFactory` does.
///
/// Reuses `SALT_TRADING_SAFE_FACTORY_PROXY`, so the reserved address matches the live Ethereum factory.
/// Everything is idempotent: chains that already hold the reservation (or the real factory) are no-ops.
///
/// Usage:
///   PRIVATE_KEY=0x... forge script scripts/trading-account/ReserveTradingSafeFactoryAddress.s.sol \
///     --rpc-url <RPC> --broadcast
///   forge script scripts/trading-account/ReserveTradingSafeFactoryAddress.s.sol --sig 'verify()' --rpc-url <RPC>
contract ReserveTradingSafeFactoryAddress is Script, TradingAccountCreate3 {
    /// @dev Salts shared with `scripts/ReserveAddresses.s.sol`, which reserved the top-up factory slot.
    ///      Reusing them keeps the placeholder and RoleRegistry impl addresses identical across chains.
    bytes32 private constant SALT_RESERVED_ROLE_REGISTRY_PROXY = 0x6cae761c5315d96c88fdeb2bdf7f689cb66abc92a4e823b7954d41f88321bd0e;
    bytes32 private constant SALT_RESERVED_ROLE_REGISTRY_IMPL = keccak256("ReserveAddresses.RoleRegistryImpl");
    bytes32 private constant SALT_RESERVED_PLACEHOLDER_IMPL = keccak256("ReserveAddresses.EtherFiPlaceholderImpl");

    bytes32 private constant OZ_INIT_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 private constant ROLE_REGISTRY_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;

    /// @dev HyperEVM's reserved RoleRegistry predates the shared reservation and is owned by a separate
    ///      multisig; `C.OPERATING_SAFE` is not an upgrader there.
    uint256 private constant HYPEREVM_CHAIN_ID = 999;
    address private constant HYPEREVM_ROLE_REGISTRY_OWNER = 0xf27128a5b064e8d97EDaa60D24bFa2FD1eeC26eB;

    function run() external {
        _requireSupportedChain();
        require(C.NICKS_FACTORY.code.length > 0, "Nick's factory not deployed on this chain");

        address reservation = _predict(C.SALT_TRADING_SAFE_FACTORY_PROXY);
        console2.log("=== Reserve TradingSafeFactory address ===");
        console2.log("Chain ID:           ", block.chainid);
        console2.log("TradingSafeFactory: ", reservation);

        if (reservation.code.length > 0) {
            console2.log("[SKIP] address already occupied on this chain");
            _verify();
            return;
        }

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        address roleRegistry = _ensureReservedRoleRegistry();
        _requireRegistryControlsUpgrades(roleRegistry);

        address placeholderImpl = _deployCreate3(type(EtherFiPlaceholder).creationCode, SALT_RESERVED_PLACEHOLDER_IMPL);
        address deployed = _deployProxy(C.SALT_TRADING_SAFE_FACTORY_PROXY, placeholderImpl, abi.encodeCall(EtherFiPlaceholder.initialize, (roleRegistry)));
        require(deployed == reservation, "TradingSafeFactory prediction mismatch");

        vm.stopBroadcast();

        console2.log("  RoleRegistry:     ", roleRegistry);
        console2.log("  Placeholder impl: ", placeholderImpl);

        _verify();
    }

    /// @notice Read-only post-deployment verification. Reverts on any failed check so CI can use the exit code.
    function verify() external view {
        _requireSupportedChain();
        _verify();
    }

    /// @dev Deploys the shared reservation RoleRegistry if this chain does not have it yet. Only Arbitrum
    ///      still lacks it; every other target chain received it from `scripts/ReserveAddresses.s.sol`.
    function _ensureReservedRoleRegistry() private returns (address roleRegistry) {
        roleRegistry = _predict(SALT_RESERVED_ROLE_REGISTRY_PROXY);
        if (roleRegistry.code.length > 0) return roleRegistry;

        // address(0) data provider matches ReserveAddresses.s.sol, so the impl address stays identical
        // across chains. A real data provider requires a fresh impl at upgrade time.
        address impl = _deployCreate3(abi.encodePacked(type(RoleRegistry).creationCode, abi.encode(address(0))), SALT_RESERVED_ROLE_REGISTRY_IMPL);
        address deployed = _deployProxy(SALT_RESERVED_ROLE_REGISTRY_PROXY, impl, abi.encodeCall(RoleRegistry.initialize, (C.OPERATING_SAFE)));
        require(deployed == roleRegistry, "RoleRegistry prediction mismatch");
    }

    /// @dev `UpgradeableProxy._authorizeUpgrade` calls `roleRegistry.onlyUpgrader`, which returns nothing, so
    ///      Solidity emits no extcodesize check. Against a code-less registry that call silently succeeds and
    ///      anyone could upgrade the reservation, so the registry must be verified before the proxy is deployed.
    function _requireRegistryControlsUpgrades(address roleRegistry) private view {
        require(roleRegistry.code.length > 0, "reserved RoleRegistry has no code");
        require(uint256(vm.load(roleRegistry, OZ_INIT_SLOT)) > 0, "reserved RoleRegistry not initialized");

        address expectedOwner = _expectedRoleRegistryOwner();
        require(RoleRegistry(roleRegistry).owner() == expectedOwner, "reserved RoleRegistry has unexpected owner");
        RoleRegistry(roleRegistry).onlyUpgrader(expectedOwner);
    }

    function _verify() private view {
        address reservation = _predict(C.SALT_TRADING_SAFE_FACTORY_PROXY);
        address placeholderImpl = _predict(SALT_RESERVED_PLACEHOLDER_IMPL);

        require(reservation.code.length > 0, "TradingSafeFactory address not reserved");
        require(uint256(vm.load(reservation, OZ_INIT_SLOT)) > 0, "reservation not initialized");

        address impl = address(uint160(uint256(vm.load(reservation, C.EIP1967_IMPL_SLOT))));
        require(impl.code.length > 0, "reservation impl has no code");

        address roleRegistry = address(uint160(uint256(vm.load(reservation, ROLE_REGISTRY_SLOT))));
        require(roleRegistry.code.length > 0, "reservation roleRegistry has no code");

        if (impl == placeholderImpl) {
            require(roleRegistry == _predict(SALT_RESERVED_ROLE_REGISTRY_PROXY), "reservation points at unexpected RoleRegistry");
            _requireRegistryControlsUpgrades(roleRegistry);
            console2.log("[OK] placeholder reservation held, upgradeable by", _expectedRoleRegistryOwner());
        } else {
            // Chains where the real factory shipped keep their own RoleRegistry, so only assert the
            // address is a live, upgrade-controlled proxy rather than pinning the placeholder impl.
            require(RoleRegistry(roleRegistry).owner() != address(0), "reservation roleRegistry has no owner");
            console2.log("[OK] real deployment held at reserved address, impl", impl);
        }
    }

    function _expectedRoleRegistryOwner() private view returns (address) {
        return block.chainid == HYPEREVM_CHAIN_ID ? HYPEREVM_ROLE_REGISTRY_OWNER : C.OPERATING_SAFE;
    }

    function _deployProxy(bytes32 salt, address implementation, bytes memory initData) private returns (address) {
        return _deployCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(implementation, initData)), salt);
    }

    /// @dev Matches the chains that already hold the `TopUpSourceFactory` reservation. Guards against
    ///      burning the salt on a chain that was never reviewed.
    function _requireSupportedChain() private view {
        uint256 id = block.chainid;
        bool supported = id == 1 // Ethereum
            || id == 10 // Optimism
            || id == 56 // BNB Chain
            || id == 137 // Polygon
            || id == 146 // Sonic
            || id == 999 // HyperEVM
            || id == 4217 // Tempo
            || id == 5000 // Mantle
            || id == 8453 // Base
            || id == 9745 // Plasma
            || id == 42_161 // Arbitrum
            || id == 43_114 // Avalanche
            || id == 59_144 // Linea
            || id == 534_352; // Scroll
        require(supported, "chain not in the reservation set");
    }
}
