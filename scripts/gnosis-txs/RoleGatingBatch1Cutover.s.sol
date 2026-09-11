// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/// @title RoleGatingBatch1Cutover
/// @notice Generates the TWO Gnosis Safe Transaction Builder JSONs for the batch-1 cutover on
///         Optimism (STAKE-1925), then simulates both on the current fork and asserts the end
///         state.
///
///         No ownership transfer: the RoleRegistry owner stays the existing timelock
///         (0x9106…4434) — the batch simply raises its delay from 8h to 2 days as its LAST
///         action, after upgrading everything and granting the new roles. A freshly deployed
///         8h operating timelock (DeployTimelock.s.sol) receives ADMIN_TIMELOCK_ROLE.
///
///         multisend 1 (schedule, day 0) — timelock.scheduleBatch (8h delay) of 12 calls:
///           upgrade RoleRegistry -> grant ADMIN_ROLE to the Safe -> grant
///           ADMIN_TIMELOCK_ROLE to the new operating timelock -> upgrade the 7 re-gated
///           proxies -> timelock.updateDelay(2 days)
///         multisend 2 (execute, hour 8+) — timelock.executeBatch of the same 12 calls.
///
///         updateDelay is last, so the batch itself rides the 8h delay and only operations
///         scheduled AFTER it take 2 days. Already-scheduled operations keep the readiness
///         timestamps they were scheduled with.
///
/// Usage (no broadcast — writes ./output/*.json and simulates):
///   forge script scripts/gnosis-txs/RoleGatingBatch1Cutover.s.sol --rpc-url $OPTIMISM_RPC
contract RoleGatingBatch1Cutover is Utils, GnosisHelpers {
    /// @dev The live timelock — RoleRegistry owner before AND after this 3CP (8h -> 2d delay)
    address constant UPGRADE_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;
    /// @dev Cash governance multisig (3/6) — proposer/executor on the timelock
    address constant GOVERNANCE_MULTISIG = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    /// @dev Permissioned CREATE3 deployer — predicts the new operating timelock address
    EtherFiDeployer constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);
    /// @dev Salt used by the repurposed DeployTimelock.s.sol for the NEW 8h operating timelock
    bytes32 constant SALT_OPERATING_TIMELOCK = keccak256("DeployTimelock.EtherFiOperatingTimelock");

    uint256 constant CURRENT_DELAY = 8 hours;
    uint256 constant NEW_DELAY = 2 days;
    bytes32 constant TL_PREDECESSOR = bytes32(0);
    bytes32 constant TL_SALT = keccak256("RoleGatingBatch1Cutover");

    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant ADMIN_TIMELOCK_ROLE = keccak256("ADMIN_TIMELOCK_ROLE");

    address roleRegistry;
    address operatingTimelock;
    address[] batchTargets;
    bytes[] batchPayloads;

    function run() public {
        require(block.chainid == 10, "RoleGatingBatch1Cutover: Optimism only");
        operatingTimelock = DEPLOYER.getDeterministicAddress(SALT_OPERATING_TIMELOCK);
        _checkTimelocks();

        string memory deployments = readDeploymentFile();
        string memory impls = vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet/10/role-gating-batch1.json"));
        roleRegistry = readAddr(deployments, "RoleRegistry");
        require(RoleRegistry(roleRegistry).owner() == UPGRADE_TIMELOCK, "RoleRegistry owner != timelock");

        _buildBatch(deployments, impls);

        // ── multisend 1: schedule the batch ──
        string memory ms1 = _getGnosisHeader(vm.toString(block.chainid), addressToHex(GOVERNANCE_MULTISIG));
        ms1 = string(abi.encodePacked(ms1, _scheduleBatchTx(true)));
        string memory ms1Path = _writeBundle("multisend1-schedule", ms1);

        // ── multisend 2: execute the batch (hour 8+) ──
        string memory ms2 = _getGnosisHeader(vm.toString(block.chainid), addressToHex(GOVERNANCE_MULTISIG));
        ms2 = string(abi.encodePacked(ms2, _executeBatchTx(true)));
        string memory ms2Path = _writeBundle("multisend2-execute", ms2);

        _simulateAndVerify(ms1Path, ms2Path);
    }

    // ── Sanity checks ──────────────────────────────────────────────────────────────

    function _checkTimelocks() internal view {
        require(keccak256(UPGRADE_TIMELOCK.code) == keccak256(type(EtherFiTimelock).runtimeCode), "timelock bytecode != local build");
        EtherFiTimelock tl = EtherFiTimelock(payable(UPGRADE_TIMELOCK));
        require(tl.getMinDelay() == CURRENT_DELAY, "timelock delay != 8h (already cut over?)");
        require(tl.hasRole(tl.PROPOSER_ROLE(), GOVERNANCE_MULTISIG) && tl.hasRole(tl.EXECUTOR_ROLE(), GOVERNANCE_MULTISIG), "multisig not proposer/executor on timelock");

        if (operatingTimelock.code.length > 0) {
            require(keccak256(operatingTimelock.code) == keccak256(type(EtherFiTimelock).runtimeCode), "operating timelock bytecode != local build");
            EtherFiTimelock op = EtherFiTimelock(payable(operatingTimelock));
            require(op.getMinDelay() == CURRENT_DELAY, "operating timelock delay != 8h");
            require(op.hasRole(op.PROPOSER_ROLE(), GOVERNANCE_MULTISIG) && op.hasRole(op.EXECUTOR_ROLE(), GOVERNANCE_MULTISIG), "multisig not proposer/executor on operating timelock");
            require(op.hasRole(op.DEFAULT_ADMIN_ROLE(), operatingTimelock), "operating timelock is not its own admin");
        } else {
            console.log("!! operating timelock NOT deployed yet at", operatingTimelock);
            console.log("!! run scripts/DeployTimelock.s.sol before signing; the grant below targets this address");
        }
    }

    // ── The batch, in the order that matters ───────────────────────────────────────

    function _buildBatch(string memory deployments, string memory impls) internal {
        // 1. Registry first: the re-gated impls call check functions that only exist on the new registry
        _add(roleRegistry, abi.encodeWithSignature("upgradeToAndCall(address,bytes)", _impl(impls, "roleRegistryImpl"), bytes("")));
        // 2. Grants before any consumer upgrade, so nothing is ever gated on an unheld role
        _add(roleRegistry, abi.encodeWithSignature("grantRole(bytes32,address)", ADMIN_ROLE, GOVERNANCE_MULTISIG));
        _add(roleRegistry, abi.encodeWithSignature("grantRole(bytes32,address)", ADMIN_TIMELOCK_ROLE, operatingTimelock));
        // 3. The seven re-gated proxies
        _addUpgrade(deployments, impls, "SettlementDispatcherReap", "settlementDispatcherReapImpl");
        _addUpgrade(deployments, impls, "SettlementDispatcherRain", "settlementDispatcherRainImpl");
        _addUpgrade(deployments, impls, "SettlementDispatcherPix", "settlementDispatcherPixImpl");
        _addUpgrade(deployments, impls, "SettlementDispatcherCardOrder", "settlementDispatcherCardOrderImpl");
        _addUpgrade(deployments, impls, "TopUpDest", "topUpDestImpl");
        _addUpgrade(deployments, impls, "CashbackDispatcher", "cashbackDispatcherImpl");
        _addUpgrade(deployments, impls, "LiquidUSDLiquifierModule", "liquidUsdLiquifierImpl");
        // 4. LAST: raise the timelock's own delay to 2 days — everything above already executed
        _add(UPGRADE_TIMELOCK, abi.encodeWithSignature("updateDelay(uint256)", NEW_DELAY));
    }

    function _addUpgrade(string memory deployments, string memory impls, string memory proxyKey, string memory implKey) internal {
        _add(readAddr(deployments, proxyKey), abi.encodeWithSignature("upgradeToAndCall(address,bytes)", _impl(impls, implKey), bytes("")));
    }

    function _add(address target, bytes memory payload) internal {
        batchTargets.push(target);
        batchPayloads.push(payload);
    }

    function _impl(string memory impls, string memory key) internal pure returns (address) {
        return stdJson.readAddress(impls, string.concat(".", key));
    }

    function readAddr(string memory deployments, string memory key) internal pure returns (address) {
        return stdJson.readAddress(deployments, string.concat(".addresses.", key));
    }

    // ── Gnosis tx builders ─────────────────────────────────────────────────────────

    function _scheduleBatchTx(bool isLast) internal view returns (string memory) {
        uint256[] memory values = new uint256[](batchTargets.length);
        string memory data = iToHex(abi.encodeWithSignature("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)", batchTargets, values, batchPayloads, TL_PREDECESSOR, TL_SALT, CURRENT_DELAY));
        return _getGnosisTransaction(addressToHex(UPGRADE_TIMELOCK), data, "0", isLast);
    }

    function _executeBatchTx(bool isLast) internal view returns (string memory) {
        uint256[] memory values = new uint256[](batchTargets.length);
        string memory data = iToHex(abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", batchTargets, values, batchPayloads, TL_PREDECESSOR, TL_SALT));
        return _getGnosisTransaction(addressToHex(UPGRADE_TIMELOCK), data, "0", isLast);
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
        console.log("=== Simulating multisend 1 (schedule the batch) ===");
        executeGnosisTransactionBundle(ms1Path);
        require(EtherFiTimelock(payable(UPGRADE_TIMELOCK)).getMinDelay() == CURRENT_DELAY, "delay must not change in multisend 1");

        console.log("=== Warping past the 8-hour delay ===");
        vm.warp(block.timestamp + CURRENT_DELAY + 1);

        console.log("=== Simulating multisend 2 (execute the batch) ===");
        executeGnosisTransactionBundle(ms2Path);

        // Ownership unchanged; delay raised; roles granted
        require(reg.owner() == UPGRADE_TIMELOCK, "owner must not change");
        require(EtherFiTimelock(payable(UPGRADE_TIMELOCK)).getMinDelay() == NEW_DELAY, "timelock delay != 2 days");
        require(reg.hasRole(ADMIN_ROLE, GOVERNANCE_MULTISIG), "multisig missing ADMIN_ROLE");
        require(reg.hasRole(ADMIN_TIMELOCK_ROLE, operatingTimelock), "operating timelock missing ADMIN_TIMELOCK_ROLE");
        reg.onlyAdmin(GOVERNANCE_MULTISIG);
        reg.onlyAdminTimelock(operatingTimelock);

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

        // The multisig still cannot use owner paths directly, and new owner ops now take 2 days
        vm.prank(GOVERNANCE_MULTISIG);
        (ok,) = roleRegistry.call(abi.encodeWithSignature("grantRole(bytes32,address)", keccak256("PROBE"), GOVERNANCE_MULTISIG));
        require(!ok, "multisig can grant roles directly");
        bytes memory probe = abi.encodeWithSignature("grantRole(bytes32,address)", keccak256("PROBE"), GOVERNANCE_MULTISIG);
        vm.prank(GOVERNANCE_MULTISIG);
        (ok,) = UPGRADE_TIMELOCK.call(abi.encodeWithSignature("schedule(address,uint256,bytes,bytes32,bytes32,uint256)", roleRegistry, 0, probe, TL_PREDECESSOR, TL_SALT, CURRENT_DELAY));
        require(!ok, "8h schedule must be rejected after the delay is raised");
        vm.prank(GOVERNANCE_MULTISIG);
        (ok,) = UPGRADE_TIMELOCK.call(abi.encodeWithSignature("schedule(address,uint256,bytes,bytes32,bytes32,uint256)", roleRegistry, 0, probe, TL_PREDECESSOR, TL_SALT, NEW_DELAY));
        require(ok, "2-day schedule must work");

        console.log("");
        console.log("  [OK] owner unchanged (timelock), delay raised to 2 days");
        console.log("  [OK] ADMIN_ROLE -> multisig, ADMIN_TIMELOCK_ROLE -> new operating timelock");
        console.log("  [OK] all 8 proxies upgraded to the audited impls");
        console.log("  [OK] revokeFast live and governance-tier-protected");
    }
}
