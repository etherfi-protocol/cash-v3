// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/// @title RoleGatingBatch2Cutover
/// @notice Generates the ONE Gnosis Safe Transaction Builder JSON for the batch-2 cutover on
///         the current top-up source chain (ETH, Arbitrum, Base, BSC or HyperEVM), then
///         simulates it on the fork and asserts the end state.
///
///         The RoleRegistry owner on these chains is the governance safe itself (the cash
///         controller safe on HyperEVM), so unlike Optimism there is nothing to schedule —
///         one immediate multisend of 5 calls:
///           1. upgrade RoleRegistry to the audited impl
///           2. grantRole(ADMIN_ROLE, governance safe)
///           3. grantRole(ADMIN_TIMELOCK_ROLE, 8h operating timelock)
///           4. upgrade TopUpFactory to the audited impl
///           5. LAST: transferOwnership(2-day upgrade timelock) — after this, upgrades and
///              role admin take 2 days; the safe keeps the fast lane through ADMIN_ROLE
///
/// Usage (no broadcast — writes ./output/*.json and simulates):
///   forge script scripts/gnosis-txs/RoleGatingBatch2Cutover.s.sol --rpc-url <chain rpc>
contract RoleGatingBatch2Cutover is Utils, GnosisHelpers {
    /// @dev 2-day upgrade timelock — same address on every chain, becomes the registry owner
    address constant UPGRADE_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;
    /// @dev 8h operating timelock — same address on every chain, receives ADMIN_TIMELOCK_ROLE
    address constant OPERATING_TIMELOCK = 0x9AEb8eaa982084219d1A938D8F7B5040a1d47849;

    /// @dev Cash governance multisig — RoleRegistry owner on ETH, Arbitrum, Base and BSC
    address constant GOVERNANCE_MULTISIG = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    /// @dev On HyperEVM the RoleRegistry owner (and timelock governor) is the cash controller safe
    address constant HYPEREVM_CONTROLLER_SAFE = 0xf27128a5b064e8d97EDaa60D24bFa2FD1eeC26eB;

    uint256 constant UPGRADE_DELAY = 2 days;
    uint256 constant OPERATING_DELAY = 8 hours;

    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant ADMIN_TIMELOCK_ROLE = keccak256("ADMIN_TIMELOCK_ROLE");

    address governance;
    address roleRegistry;
    address topUpFactory;
    address registryImpl;
    address factoryImpl;

    function run() public {
        require(
            block.chainid == 1 || block.chainid == 42161 || block.chainid == 8453 || block.chainid == 56 || block.chainid == 999,
            "RoleGatingBatch2Cutover: top-up source chains only"
        );
        governance = block.chainid == 999 ? HYPEREVM_CONTROLLER_SAFE : GOVERNANCE_MULTISIG;

        // ── 1. Resolve addresses and cross-check the world looks as reviewed ──
        string memory deployments = readDeploymentFile();
        string memory impls = vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet/", vm.toString(block.chainid), "/role-gating-batch2.json"));
        roleRegistry = stdJson.readAddress(deployments, ".addresses.RoleRegistry");
        topUpFactory = stdJson.readAddress(deployments, ".addresses.TopUpSourceFactory");
        registryImpl = stdJson.readAddress(impls, ".roleRegistryImpl");
        factoryImpl = stdJson.readAddress(impls, ".topUpFactoryImpl");
        require(stdJson.readAddress(impls, ".upgradeTimelock") == UPGRADE_TIMELOCK && stdJson.readAddress(impls, ".operatingTimelock") == OPERATING_TIMELOCK, "deployment record: timelock mismatch");

        require(RoleRegistry(roleRegistry).owner() == governance, "RoleRegistry owner != governance safe (already cut over?)");
        require(registryImpl.code.length > 0 && factoryImpl.code.length > 0, "impls not deployed");
        _checkTimelock(UPGRADE_TIMELOCK, UPGRADE_DELAY);
        _checkTimelock(OPERATING_TIMELOCK, OPERATING_DELAY);

        // ── 2. The multisend, in the order that matters ──
        // Registry first (the re-gated factory impl calls check functions that only exist on
        // the new registry), grants before the factory upgrade (nothing gated on an unheld
        // role), ownership transfer LAST (every earlier call needs the safe to be owner).
        string memory ms = _getGnosisHeader(vm.toString(block.chainid), addressToHex(governance));
        ms = string(abi.encodePacked(ms, _getGnosisTransaction(addressToHex(roleRegistry), iToHex(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", registryImpl, bytes(""))), "0", false)));
        ms = string(abi.encodePacked(ms, _getGnosisTransaction(addressToHex(roleRegistry), iToHex(abi.encodeWithSignature("grantRole(bytes32,address)", ADMIN_ROLE, governance)), "0", false)));
        ms = string(abi.encodePacked(ms, _getGnosisTransaction(addressToHex(roleRegistry), iToHex(abi.encodeWithSignature("grantRole(bytes32,address)", ADMIN_TIMELOCK_ROLE, OPERATING_TIMELOCK)), "0", false)));
        ms = string(abi.encodePacked(ms, _getGnosisTransaction(addressToHex(topUpFactory), iToHex(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", factoryImpl, bytes(""))), "0", false)));
        ms = string(abi.encodePacked(ms, _getGnosisTransaction(addressToHex(roleRegistry), iToHex(abi.encodeWithSignature("transferOwnership(address)", UPGRADE_TIMELOCK)), "0", true)));

        vm.createDir("./output", true);
        string memory path = string.concat("./output/RoleGatingBatch2Cutover-", vm.toString(block.chainid), "-multisend.json");
        vm.writeFile(path, ms);
        console.log("Wrote", path);

        _simulateAndVerify(path);
    }

    // ── Sanity checks ──────────────────────────────────────────────────────────────

    function _checkTimelock(address timelock, uint256 delay) internal view {
        require(keccak256(timelock.code) == keccak256(type(EtherFiTimelock).runtimeCode), "timelock bytecode != local build");
        EtherFiTimelock tl = EtherFiTimelock(payable(timelock));
        require(tl.getMinDelay() == delay, "timelock: unexpected delay");
        require(tl.hasRole(tl.PROPOSER_ROLE(), governance), "governance is not proposer");
        require(tl.hasRole(tl.EXECUTOR_ROLE(), governance), "governance is not executor");
        require(tl.hasRole(tl.CANCELLER_ROLE(), governance), "governance is not canceller");
        require(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), timelock), "timelock is not its own admin");
        require(!tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), governance), "governance must not be timelock admin");
    }

    // ── Fork simulation + end-state assertions ─────────────────────────────────────

    function _simulateAndVerify(string memory path) internal {
        RoleRegistry reg = RoleRegistry(roleRegistry);

        console.log("");
        console.log("=== Simulating the multisend ===");
        executeGnosisTransactionBundle(path);

        // Ownership moved to the 2-day timelock; roles granted
        require(reg.owner() == UPGRADE_TIMELOCK, "owner != 2-day upgrade timelock");
        require(reg.hasRole(ADMIN_ROLE, governance), "governance missing ADMIN_ROLE");
        require(reg.hasRole(ADMIN_TIMELOCK_ROLE, OPERATING_TIMELOCK), "operating timelock missing ADMIN_TIMELOCK_ROLE");
        reg.onlyAdmin(governance);
        reg.onlyAdminTimelock(OPERATING_TIMELOCK);

        // Both proxies point at the audited impls
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        require(address(uint160(uint256(vm.load(roleRegistry, implSlot)))) == registryImpl, "registry impl slot mismatch");
        require(address(uint160(uint256(vm.load(topUpFactory, implSlot)))) == factoryImpl, "factory impl slot mismatch");

        // revokeFast is live, admin-gated, and protects the governance tier
        vm.prank(makeAddr("stranger"));
        (bool ok,) = roleRegistry.call(abi.encodeWithSignature("revokeFast(bytes32,address)", keccak256("PROBE"), makeAddr("x")));
        require(!ok, "stranger can call revokeFast");
        vm.prank(governance);
        (ok,) = roleRegistry.call(abi.encodeWithSignature("revokeFast(bytes32,address)", ADMIN_ROLE, governance));
        require(!ok, "revokeFast must refuse ADMIN_ROLE");

        // The safe lost the owner paths: direct grants revert, owner ops go through the 2-day timelock
        vm.prank(governance);
        (ok,) = roleRegistry.call(abi.encodeWithSignature("grantRole(bytes32,address)", keccak256("PROBE"), governance));
        require(!ok, "safe can still grant roles directly");
        bytes memory probe = abi.encodeWithSignature("grantRole(bytes32,address)", keccak256("PROBE"), governance);
        vm.prank(governance);
        (ok,) = UPGRADE_TIMELOCK.call(abi.encodeWithSignature("schedule(address,uint256,bytes,bytes32,bytes32,uint256)", roleRegistry, 0, probe, bytes32(0), keccak256("probe.fast"), OPERATING_DELAY));
        require(!ok, "8h schedule on the 2-day timelock must be rejected");
        vm.prank(governance);
        (ok,) = UPGRADE_TIMELOCK.call(abi.encodeWithSignature("schedule(address,uint256,bytes,bytes32,bytes32,uint256)", roleRegistry, 0, probe, bytes32(0), keccak256("probe.slow"), UPGRADE_DELAY));
        require(ok, "2-day schedule must work");

        // Re-gated factory setters answer only to the operating timelock
        bytes memory setter = abi.encodeWithSignature("setRecoveryWallet(address)", makeAddr("recovery"));
        vm.prank(governance);
        (ok,) = topUpFactory.call(setter);
        require(!ok, "safe must not pass onlyAdminTimelock on the factory");
        vm.prank(OPERATING_TIMELOCK);
        (ok,) = topUpFactory.call(setter);
        require(ok, "operating timelock must pass onlyAdminTimelock on the factory");

        console.log("");
        console.log("  [OK] owner -> 2-day upgrade timelock; safe locked out of direct owner paths");
        console.log("  [OK] ADMIN_ROLE -> governance safe, ADMIN_TIMELOCK_ROLE -> operating timelock");
        console.log("  [OK] RoleRegistry + TopUpFactory upgraded to the audited impls");
        console.log("  [OK] revokeFast live and governance-tier-protected; factory setters re-gated");
    }
}
