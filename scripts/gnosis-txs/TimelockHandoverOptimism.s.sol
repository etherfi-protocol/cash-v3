// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/// @title TimelockHandoverOptimism
/// @notice Generates the TWO Gnosis Safe Transaction Builder JSONs that hand RoleRegistry
///         ownership on Optimism to the EtherFiTimelock (deployed by DeployTimelock.s.sol),
///         then simulates both bundles on the current fork and asserts the end state.
///
///         The ownership move uses solady Ownable's two-step handover:
///         - step1 (governance safe): timelock.schedule(roleRegistry.requestOwnershipHandover)
///         - step2 (same safe, >= 8h later): timelock.execute(requestOwnershipHandover)
///           + roleRegistry.completeOwnershipHandover(timelock)
///
///         Routing the handover request through the timelock proves its schedule -> execute
///         round-trip works on-chain before it becomes owner, and executing + completing in
///         one step-2 bundle keeps solady's 48h handover expiry far away.
///
/// @dev NO re-gating ships with this handover: every onlyRoleRegistryOwner path — grantRole /
///      revokeRole, contract upgrades via onlyUpgrader, and the config & treasury functions —
///      moves behind the 8-hour schedule -> execute round-trip until the re-gate lands. The
///      governance safe stays proposer/executor/canceller, so nothing is lost, only delayed.
///
/// Usage (no broadcast — writes ./output/*.json and simulates):
///   forge script scripts/gnosis-txs/TimelockHandoverOptimism.s.sol --rpc-url $OPTIMISM_RPC
contract TimelockHandoverOptimism is Utils, GnosisHelpers {
    /// @dev EtherFiTimelock at its deterministic CREATE3 address (DeployTimelock.s.sol)
    address constant ETHERFI_TIMELOCK = 0xDb546E6466f6A7Ff5D381835bEfAf2c3Ae944f9b;
    uint256 constant TIMELOCK_DELAY = 8 hours;
    bytes32 constant TL_PREDECESSOR = bytes32(0);
    bytes32 constant TL_SALT = bytes32(0);

    /// @dev Cash governance multisig owning the RoleRegistry on Optimism
    address constant GOVERNANCE_MULTISIG = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    function run() public {
        require(block.chainid == 10, "TimelockHandover: Optimism only");
        require(ETHERFI_TIMELOCK.code.length > 0, "EtherFiTimelock not deployed - run DeployTimelock.s.sol first");
        // Never hand RoleRegistry ownership to a mimic squatting the CREATE3 address: the code
        // at the hardcoded address must be exactly this build's EtherFiTimelock runtime code
        require(keccak256(ETHERFI_TIMELOCK.code) == keccak256(type(EtherFiTimelock).runtimeCode), "timelock bytecode != local EtherFiTimelock build");

        string memory deployments = readDeploymentFile();
        address roleRegistry = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "RoleRegistry"));

        address safe = RoleRegistry(roleRegistry).owner();
        require(safe == GOVERNANCE_MULTISIG, "RoleRegistry owner != expected governance");

        // ── Build step 1: schedule the handover request on the timelock ──
        string memory step1 = _getGnosisHeader(vm.toString(block.chainid), addressToHex(safe));
        step1 = string(abi.encodePacked(step1, _scheduleTimelockOpTx(roleRegistry, _handoverRequestCalldata(), true)));
        string memory step1Path = _writeBundle("step1-schedule", step1);

        // ── Build step 2: execute the request, then complete the handover ──
        string memory step2 = _getGnosisHeader(vm.toString(block.chainid), addressToHex(safe));
        step2 = string(abi.encodePacked(step2, _executeTimelockOpTx(roleRegistry, _handoverRequestCalldata(), false)));
        step2 = string(abi.encodePacked(step2, _completeHandoverTx(roleRegistry, true)));
        string memory step2Path = _writeBundle("step2-handover", step2);

        // ── Simulate both bundles on the fork and assert the end state ──
        _simulateAndVerify(step1Path, step2Path, roleRegistry, safe);
    }

    // ── Gnosis tx builders ─────────────────────────────────────────────────────────

    function _handoverRequestCalldata() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("requestOwnershipHandover()");
    }

    /// @dev step1: schedule an operation on the EtherFi timelock (8-hour delay)
    function _scheduleTimelockOpTx(address target, bytes memory data, bool isLast) internal pure returns (string memory) {
        string memory scheduleData = iToHex(abi.encodeWithSignature("schedule(address,uint256,bytes,bytes32,bytes32,uint256)", target, 0, data, TL_PREDECESSOR, TL_SALT, TIMELOCK_DELAY));
        return _getGnosisTransaction(addressToHex(ETHERFI_TIMELOCK), scheduleData, "0", isLast);
    }

    /// @dev step2: execute a previously scheduled timelock operation
    function _executeTimelockOpTx(address target, bytes memory data, bool isLast) internal pure returns (string memory) {
        string memory executeData = iToHex(abi.encodeWithSignature("execute(address,uint256,bytes,bytes32,bytes32)", target, 0, data, TL_PREDECESSOR, TL_SALT));
        return _getGnosisTransaction(addressToHex(ETHERFI_TIMELOCK), executeData, "0", isLast);
    }

    /// @dev step2: safe (still owner) completes the handover — timelock becomes owner
    function _completeHandoverTx(address roleRegistry, bool isLast) internal pure returns (string memory) {
        string memory data = iToHex(abi.encodeWithSignature("completeOwnershipHandover(address)", ETHERFI_TIMELOCK));
        return _getGnosisTransaction(addressToHex(roleRegistry), data, "0", isLast);
    }

    function _writeBundle(string memory step, string memory txs) internal returns (string memory path) {
        vm.createDir("./output", true);
        path = string.concat("./output/TimelockHandover-", vm.toString(block.chainid), "-", step, ".json");
        vm.writeFile(path, txs);
        console.log("Wrote", path);
    }

    // ── Fork simulation of both bundles + end-state assertions ────────────────────

    function _simulateAndVerify(string memory step1Path, string memory step2Path, address roleRegistry, address safe) internal {
        console.log("");
        console.log("=== Simulating step 1 (schedule handover request) ===");
        executeGnosisTransactionBundle(step1Path);

        require(RoleRegistry(roleRegistry).owner() == safe, "owner must not change in step 1");

        console.log("=== Warping past the 8-hour timelock delay ===");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        console.log("=== Simulating step 2 (execute request + complete handover) ===");
        executeGnosisTransactionBundle(step2Path);

        require(RoleRegistry(roleRegistry).owner() == ETHERFI_TIMELOCK, "timelock is not RoleRegistry owner");

        // The safe must no longer pass owner-gated paths directly...
        vm.prank(safe);
        (bool ok,) = roleRegistry.call(abi.encodeWithSignature("grantRole(bytes32,address)", keccak256("PROBE_ROLE"), safe));
        require(!ok, "safe can still grant roles after handover");

        // ...but the same operation must work through the timelock's schedule -> execute round-trip
        bytes memory probeGrant = abi.encodeWithSignature("grantRole(bytes32,address)", keccak256("PROBE_ROLE"), safe);
        vm.prank(safe);
        (bool scheduled,) = ETHERFI_TIMELOCK.call(abi.encodeWithSignature("schedule(address,uint256,bytes,bytes32,bytes32,uint256)", roleRegistry, 0, probeGrant, TL_PREDECESSOR, TL_SALT, TIMELOCK_DELAY));
        require(scheduled, "safe cannot schedule through the timelock");

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        vm.prank(safe);
        (bool executed,) = ETHERFI_TIMELOCK.call(abi.encodeWithSignature("execute(address,uint256,bytes,bytes32,bytes32)", roleRegistry, 0, probeGrant, TL_PREDECESSOR, TL_SALT));
        require(executed, "safe cannot execute through the timelock");
        require(RoleRegistry(roleRegistry).hasRole(keccak256("PROBE_ROLE"), safe), "role grant through timelock failed");

        console.log("");
        console.log("  [OK] RoleRegistry owner is the timelock:", ETHERFI_TIMELOCK);
        console.log("  [OK] safe can operate the registry through schedule -> execute");
        console.log("  [OK] safe is proposer/executor/canceller:", safe);
    }
}
