// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { SettlementDispatcherV2 } from "../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/// @title RoleGatingBatch1Cutover
/// @notice Generates the TWO Gnosis Safe Transaction Builder JSONs for the batch-1 cutover on
///         Optimism (STAKE-1925), then simulates both on the current fork and asserts the end
///         state.
///
///         multisend 1 (schedule, day 0):
///           - 2-day upgrade timelock: schedule roleRegistry.requestOwnershipHandover()
///           - 8h operating timelock: scheduleBatch [upgrade RoleRegistry -> grant ADMIN_ROLE
///             to the multisig -> grant ADMIN_TIMELOCK_ROLE to the 8h timelock -> upgrade the
///             7 re-gated proxies -> completeOwnershipHandover(2-day timelock)]
///
///         multisend 2 (execute, day 2+):
///           - 2-day timelock: execute the handover request
///           - 8h timelock: executeBatch (upgrades + grants + handover completion)
///
///         Ordering safety: the batch ends with completeOwnershipHandover, which reverts unless
///         the request (first tx of multisend 2) has landed — so executing the 8h batch early
///         reverts atomically and nothing is left half-done. Both bundles are one Safe tx each;
///         the multisig is proposer + executor on both timelocks.
///
/// Usage (no broadcast — writes ./output/*.json and simulates):
///   forge script scripts/gnosis-txs/RoleGatingBatch1Cutover.s.sol --rpc-url $OPTIMISM_RPC
contract RoleGatingBatch1Cutover is Utils, GnosisHelpers {
    /// @dev The live 8h operating timelock — current RoleRegistry owner
    address constant OPERATING_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;
    /// @dev The 2-day upgrade timelock deployed by DeployRoleGatingBatch1.s.sol
    address constant UPGRADE_TIMELOCK = 0x120F246e415Ceff6dA7a22AdA1A40ef4beD7d95d;
    /// @dev Cash governance multisig (3/6) — proposer/executor on both timelocks
    address constant GOVERNANCE_MULTISIG = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    uint256 constant OPERATING_DELAY = 8 hours;
    uint256 constant UPGRADE_DELAY = 2 days;
    bytes32 constant TL_PREDECESSOR = bytes32(0);
    bytes32 constant TL_SALT = keccak256("RoleGatingBatch1Cutover");

    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant ADMIN_TIMELOCK_ROLE = keccak256("ADMIN_TIMELOCK_ROLE");

    address roleRegistry;
    address[] batchTargets;
    bytes[] batchPayloads;

    function run() public {
        require(block.chainid == 10, "RoleGatingBatch1Cutover: Optimism only");
        _checkTimelocks();

        string memory deployments = readDeploymentFile();
        string memory impls = vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet/10/role-gating-batch1.json"));
        roleRegistry = readAddr(deployments, "RoleRegistry");
        require(RoleRegistry(roleRegistry).owner() == OPERATING_TIMELOCK, "RoleRegistry owner != 8h operating timelock");

        _buildBatch(deployments, impls);

        // ── multisend 1: both schedules in one Safe tx ──
        string memory ms1 = _getGnosisHeader(vm.toString(block.chainid), addressToHex(GOVERNANCE_MULTISIG));
        ms1 = string(abi.encodePacked(ms1, _scheduleHandoverRequestTx(false)));
        ms1 = string(abi.encodePacked(ms1, _scheduleBatchTx(true)));
        string memory ms1Path = _writeBundle("multisend1-schedule", ms1);

        // ── multisend 2: both executes in one Safe tx (request first, batch second) ──
        string memory ms2 = _getGnosisHeader(vm.toString(block.chainid), addressToHex(GOVERNANCE_MULTISIG));
        ms2 = string(abi.encodePacked(ms2, _executeHandoverRequestTx(false)));
        ms2 = string(abi.encodePacked(ms2, _executeBatchTx(true)));
        string memory ms2Path = _writeBundle("multisend2-execute", ms2);

        _simulateAndVerify(ms1Path, ms2Path);
    }

    // ── Sanity checks ──────────────────────────────────────────────────────────────

    function _checkTimelocks() internal view {
        require(keccak256(OPERATING_TIMELOCK.code) == keccak256(type(EtherFiTimelock).runtimeCode), "8h timelock bytecode != local build");
        require(keccak256(UPGRADE_TIMELOCK.code) == keccak256(type(EtherFiTimelock).runtimeCode), "2d timelock bytecode != local build");

        EtherFiTimelock op = EtherFiTimelock(payable(OPERATING_TIMELOCK));
        EtherFiTimelock up = EtherFiTimelock(payable(UPGRADE_TIMELOCK));
        require(op.getMinDelay() == OPERATING_DELAY, "8h timelock delay mismatch");
        require(up.getMinDelay() == UPGRADE_DELAY, "2d timelock delay mismatch");
        require(op.hasRole(op.PROPOSER_ROLE(), GOVERNANCE_MULTISIG) && op.hasRole(op.EXECUTOR_ROLE(), GOVERNANCE_MULTISIG), "multisig not proposer/executor on 8h timelock");
        require(up.hasRole(up.PROPOSER_ROLE(), GOVERNANCE_MULTISIG) && up.hasRole(up.EXECUTOR_ROLE(), GOVERNANCE_MULTISIG), "multisig not proposer/executor on 2d timelock");
        require(up.hasRole(up.DEFAULT_ADMIN_ROLE(), UPGRADE_TIMELOCK), "2d timelock is not its own admin");
    }

    // ── The 8h batch, in the order that matters ────────────────────────────────────

    function _buildBatch(string memory deployments, string memory impls) internal {
        // 1. Registry first: the re-gated impls call check functions that only exist on the new registry
        _add(roleRegistry, abi.encodeWithSignature("upgradeToAndCall(address,bytes)", _impl(impls, "roleRegistryImpl"), bytes("")));
        // 2. Grants before any consumer upgrade, so nothing is ever gated on an unheld role
        _add(roleRegistry, abi.encodeWithSignature("grantRole(bytes32,address)", ADMIN_ROLE, GOVERNANCE_MULTISIG));
        _add(roleRegistry, abi.encodeWithSignature("grantRole(bytes32,address)", ADMIN_TIMELOCK_ROLE, OPERATING_TIMELOCK));
        // 3. The seven re-gated proxies
        _addUpgrade(deployments, impls, "SettlementDispatcherReap", "settlementDispatcherReapImpl");
        _addUpgrade(deployments, impls, "SettlementDispatcherRain", "settlementDispatcherRainImpl");
        _addUpgrade(deployments, impls, "SettlementDispatcherPix", "settlementDispatcherPixImpl");
        _addUpgrade(deployments, impls, "SettlementDispatcherCardOrder", "settlementDispatcherCardOrderImpl");
        _addUpgrade(deployments, impls, "TopUpDest", "topUpDestImpl");
        _addUpgrade(deployments, impls, "CashbackDispatcher", "cashbackDispatcherImpl");
        _addUpgrade(deployments, impls, "LiquidUSDLiquifierModule", "liquidUsdLiquifierImpl");
        // 4. Handover completion LAST — reverts atomically if the 2d request has not landed
        _add(roleRegistry, abi.encodeWithSignature("completeOwnershipHandover(address)", UPGRADE_TIMELOCK));
    }

    function _addUpgrade(string memory deployments, string memory impls, string memory proxyKey, string memory implKey) internal {
        address proxy = readAddr(deployments, proxyKey);
        address impl = _impl(impls, implKey);
        _add(proxy, abi.encodeWithSignature("upgradeToAndCall(address,bytes)", impl, bytes("")));
    }

    function _add(address target, bytes memory payload) internal {
        batchTargets.push(target);
        batchPayloads.push(payload);
    }

    function _impl(string memory impls, string memory key) internal pure returns (address impl) {
        impl = stdJson.readAddress(impls, string.concat(".", key));
        return impl;
    }

    function readAddr(string memory deployments, string memory key) internal pure returns (address) {
        return stdJson.readAddress(deployments, string.concat(".addresses.", key));
    }

    // ── Gnosis tx builders ─────────────────────────────────────────────────────────

    function _handoverRequestCalldata() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("requestOwnershipHandover()");
    }

    function _scheduleHandoverRequestTx(bool isLast) internal view returns (string memory) {
        string memory data = iToHex(abi.encodeWithSignature("schedule(address,uint256,bytes,bytes32,bytes32,uint256)", roleRegistry, 0, _handoverRequestCalldata(), TL_PREDECESSOR, TL_SALT, UPGRADE_DELAY));
        return _getGnosisTransaction(addressToHex(UPGRADE_TIMELOCK), data, "0", isLast);
    }

    function _executeHandoverRequestTx(bool isLast) internal view returns (string memory) {
        string memory data = iToHex(abi.encodeWithSignature("execute(address,uint256,bytes,bytes32,bytes32)", roleRegistry, 0, _handoverRequestCalldata(), TL_PREDECESSOR, TL_SALT));
        return _getGnosisTransaction(addressToHex(UPGRADE_TIMELOCK), data, "0", isLast);
    }

    function _scheduleBatchTx(bool isLast) internal view returns (string memory) {
        uint256[] memory values = new uint256[](batchTargets.length);
        string memory data = iToHex(abi.encodeWithSignature("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)", batchTargets, values, batchPayloads, TL_PREDECESSOR, TL_SALT, OPERATING_DELAY));
        return _getGnosisTransaction(addressToHex(OPERATING_TIMELOCK), data, "0", isLast);
    }

    function _executeBatchTx(bool isLast) internal view returns (string memory) {
        uint256[] memory values = new uint256[](batchTargets.length);
        string memory data = iToHex(abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", batchTargets, values, batchPayloads, TL_PREDECESSOR, TL_SALT));
        return _getGnosisTransaction(addressToHex(OPERATING_TIMELOCK), data, "0", isLast);
    }

    function _writeBundle(string memory step, string memory txs) internal returns (string memory path) {
        vm.createDir("./output", true);
        path = string.concat("./output/RoleGatingBatch1Cutover-", vm.toString(block.chainid), "-", step, ".json");
        vm.writeFile(path, txs);
        console.log("Wrote", path);
    }

    // ── Fork simulation + end-state assertions ─────────────────────────────────────

    function _simulateAndVerify(string memory ms1Path, string memory ms2Path) internal {
        RoleRegistry reg = RoleRegistry(roleRegistry);

        console.log("");
        console.log("=== Simulating multisend 1 (schedule both ops) ===");
        executeGnosisTransactionBundle(ms1Path);
        require(reg.owner() == OPERATING_TIMELOCK, "owner must not change in multisend 1");

        console.log("=== Warping past the 2-day delay ===");
        vm.warp(block.timestamp + UPGRADE_DELAY + 1);

        console.log("=== Simulating multisend 2 (execute both ops) ===");
        executeGnosisTransactionBundle(ms2Path);

        // Ownership and roles
        require(reg.owner() == UPGRADE_TIMELOCK, "owner != 2-day upgrade timelock");
        require(reg.hasRole(ADMIN_ROLE, GOVERNANCE_MULTISIG), "multisig missing ADMIN_ROLE");
        require(reg.hasRole(ADMIN_TIMELOCK_ROLE, OPERATING_TIMELOCK), "8h timelock missing ADMIN_TIMELOCK_ROLE");
        // The new registry impl's reverting checks are live for the right principals
        reg.onlyAdmin(GOVERNANCE_MULTISIG);
        reg.onlyAdminTimelock(OPERATING_TIMELOCK);

        // Every proxy points at its new impl
        for (uint256 i = 0; i < batchTargets.length; i++) {
            bytes memory payload = batchPayloads[i];
            if (bytes4(payload) != bytes4(keccak256("upgradeToAndCall(address,bytes)"))) continue;
            address target = batchTargets[i];
            address impl;
            assembly { impl := mload(add(payload, 36)) }
            bytes32 slot = vm.load(target, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
            require(address(uint160(uint256(slot))) == impl, "proxy impl slot != new impl");
        }

        // revokeFast is live, admin-gated, and protects the governance tier
        vm.prank(makeAddr("stranger"));
        (bool ok,) = roleRegistry.call(abi.encodeWithSignature("revokeFast(bytes32,address)", keccak256("PROBE"), makeAddr("x")));
        require(!ok, "stranger can call revokeFast");
        vm.prank(GOVERNANCE_MULTISIG);
        (ok,) = roleRegistry.call(abi.encodeWithSignature("revokeFast(bytes32,address)", ADMIN_ROLE, GOVERNANCE_MULTISIG));
        require(!ok, "revokeFast must refuse ADMIN_ROLE");

        // The multisig can no longer use owner paths directly
        vm.prank(GOVERNANCE_MULTISIG);
        (ok,) = roleRegistry.call(abi.encodeWithSignature("grantRole(bytes32,address)", keccak256("PROBE"), GOVERNANCE_MULTISIG));
        require(!ok, "multisig can still grant roles directly after handover");

        console.log("");
        console.log("  [OK] RoleRegistry owner is the 2-day upgrade timelock");
        console.log("  [OK] ADMIN_ROLE -> multisig, ADMIN_TIMELOCK_ROLE -> 8h timelock");
        console.log("  [OK] all 8 proxies upgraded to the audited impls");
        console.log("  [OK] revokeFast live and governance-tier-protected");
    }
}
