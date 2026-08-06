// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { RoleRegistry } from "../../../src/role-registry/RoleRegistry.sol";
import { Create3Deployer } from "../../utils/Create3Deployer.sol";
import { GnosisHelpers } from "../../utils/GnosisHelpers.sol";
import { Utils } from "../../utils/Utils.sol";

/// @title TimelockMigrationBase
/// @notice Shared machinery for the per-chain migration scripts. Each chain script:
///         1. Deploys the re-gated implementations via Nick's factory + CREATE3 (broadcast).
///         2. Generates TWO Gnosis Safe Transaction Builder JSONs:
///            - step1: upgrade every re-gated proxy + grant GOVERNANCE_ROLE to the safe
///                     + timelock.schedule(roleRegistry.requestOwnershipHandover, 2 days)
///            - step2 (execute >= 2 days later): timelock.execute(requestOwnershipHandover)
///                     + roleRegistry.completeOwnershipHandover(timelock)
///         3. Simulates both bundles on the current fork (with a 2-day warp in between) and
///            asserts the end state: new impls live, safe holds GOVERNANCE_ROLE, timelock owns
///            the RoleRegistry, and the safe can no longer act as owner.
///
///         The ownership move uses solady Ownable's two-step handover: the timelock itself
///         requests the handover (only possible through a scheduled timelock operation, which
///         also proves the timelock's schedule→execute round-trip works on that chain before
///         it becomes owner), and the safe — still owner — completes it in the same step-2
///         bundle, so the 48h handover expiry is never approached.
abstract contract TimelockMigrationBase is Utils, GnosisHelpers {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev EtherFiTimelock — deployed at the same CREATE3 address on all 6 chains (DeployTimelock.s.sol)
    address constant ETHERFI_TIMELOCK = 0xDb546E6466f6A7Ff5D381835bEfAf2c3Ae944f9b;
    uint256 constant TIMELOCK_DELAY = 2 days;
    bytes32 constant TL_PREDECESSOR = bytes32(0);
    bytes32 constant TL_SALT = bytes32(0);

    bytes32 constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev ether.fi guardian safe — becomes CANCELLER on the timelock (can veto queued
    ///      operations, nothing else). Same address on all 6 chains; not yet deployed on
    ///      Arbitrum but will land at this address there too, and role grants are
    ///      address-based so granting ahead of deployment is safe.
    address constant CANCELLER_SAFE = 0x055a8B2B65d0aB4E0C17a0168d032464B7E97bdF;

    /// @dev Governance multisig owning the RoleRegistry on Ethereum, Optimism, BNB, Base, Arbitrum
    address constant GOVERNANCE_MULTISIG = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    /// @dev HyperEVM governance runs through the cash controller safe instead
    address constant CASH_CONTROLLER_SAFE_HYPEREVM = 0xf27128a5b064e8d97EDaa60D24bFa2FD1eeC26eB;

    function expectedSafe(uint256 chainId) internal pure returns (address) {
        if (chainId == 1 || chainId == 10 || chainId == 56 || chainId == 8453 || chainId == 42_161) return GOVERNANCE_MULTISIG;
        if (chainId == 999) return CASH_CONTROLLER_SAFE_HYPEREVM;
        revert("TimelockMigration: unsupported chain");
    }

    /// @dev Resolves and sanity-checks the chain context shared by every migration script
    function _resolveContext(uint256 requiredChainId, address roleRegistry) internal view returns (address safe) {
        require(block.chainid == requiredChainId, "wrong chain for this script");
        require(NICKS_FACTORY.code.length > 0, "Nick's factory not deployed");
        require(ETHERFI_TIMELOCK.code.length > 0, "EtherFiTimelock not deployed on this chain");

        safe = RoleRegistry(roleRegistry).owner();
        require(safe == expectedSafe(block.chainid), "RoleRegistry owner != expected safe");
        require(!RoleRegistry(roleRegistry).hasRole(GOVERNANCE_ROLE, address(0)), "sanity");
    }

    // ── Gnosis tx builders ─────────────────────────────────────────────────────────

    function _upgradeTx(address proxy, address newImpl, bool isLast) internal pure returns (string memory) {
        string memory data = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, newImpl, ""));
        return _getGnosisTransaction(addressToHex(proxy), data, "0", isLast);
    }

    function _grantGovernanceRoleTx(address roleRegistry, address safe, bool isLast) internal pure returns (string memory) {
        string memory data = iToHex(abi.encodeWithSignature("grantRole(bytes32,address)", GOVERNANCE_ROLE, safe));
        return _getGnosisTransaction(addressToHex(roleRegistry), data, "0", isLast);
    }

    function _handoverRequestCalldata() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("requestOwnershipHandover()");
    }

    /// @dev timelock.grantRole(CANCELLER_ROLE, CANCELLER_SAFE) — the timelock is its own admin,
    ///      so the grant must go through a scheduled operation targeting the timelock itself
    function _grantCancellerCalldata() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("grantRole(bytes32,address)", CANCELLER_ROLE, CANCELLER_SAFE);
    }

    /// @dev step1: schedule an operation on the EtherFi timelock (2-day delay)
    function _scheduleTimelockOpTx(address target, bytes memory data, bool isLast) internal pure returns (string memory) {
        string memory scheduleData = iToHex(abi.encodeWithSignature("schedule(address,uint256,bytes,bytes32,bytes32,uint256)", target, 0, data, TL_PREDECESSOR, TL_SALT, TIMELOCK_DELAY));
        return _getGnosisTransaction(addressToHex(ETHERFI_TIMELOCK), scheduleData, "0", isLast);
    }

    /// @dev step2: execute a previously scheduled timelock operation
    function _executeTimelockOpTx(address target, bytes memory data, bool isLast) internal pure returns (string memory) {
        string memory executeData = iToHex(abi.encodeWithSignature("execute(address,uint256,bytes,bytes32,bytes32)", target, 0, data, TL_PREDECESSOR, TL_SALT));
        return _getGnosisTransaction(addressToHex(ETHERFI_TIMELOCK), executeData, "0", isLast);
    }

    /// @dev step1 tail shared by every chain: grant GOVERNANCE_ROLE to the safe, schedule the
    ///      ownership-handover request, and schedule the canceller grant for the guardian safe
    function _appendStep1GovernanceTxs(string memory txs, address roleRegistry, address safe) internal pure returns (string memory) {
        txs = string(abi.encodePacked(txs, _grantGovernanceRoleTx(roleRegistry, safe, false)));
        txs = string(abi.encodePacked(txs, _scheduleTimelockOpTx(roleRegistry, _handoverRequestCalldata(), false)));
        txs = string(abi.encodePacked(txs, _scheduleTimelockOpTx(ETHERFI_TIMELOCK, _grantCancellerCalldata(), true)));
        return txs;
    }

    /// @dev step2: safe (still owner) completes the handover — timelock becomes owner
    function _completeHandoverTx(address roleRegistry, bool isLast) internal pure returns (string memory) {
        string memory data = iToHex(abi.encodeWithSignature("completeOwnershipHandover(address)", ETHERFI_TIMELOCK));
        return _getGnosisTransaction(addressToHex(roleRegistry), data, "0", isLast);
    }

    /// @dev step2 bundle is identical for every chain: execute the handover request, complete
    ///      the ownership transfer, and execute the canceller grant for the guardian safe
    function _buildStep2(address roleRegistry, address safe) internal view returns (string memory txs) {
        txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(safe));
        txs = string(abi.encodePacked(txs, _executeTimelockOpTx(roleRegistry, _handoverRequestCalldata(), false)));
        txs = string(abi.encodePacked(txs, _completeHandoverTx(roleRegistry, false)));
        txs = string(abi.encodePacked(txs, _executeTimelockOpTx(ETHERFI_TIMELOCK, _grantCancellerCalldata(), true)));
    }

    function _writeBundle(string memory step, string memory txs) internal returns (string memory path) {
        vm.createDir("./output", true);
        path = string.concat("./output/TimelockMigration-", vm.toString(block.chainid), "-", step, ".json");
        vm.writeFile(path, txs);
        console.log("Wrote", path);
    }

    // ── CREATE3 impl deployment — atomic via Create3Deployer (see its natspec) ─────

    function deployCreate3(bytes memory creationCode, bytes32 salt) internal returns (address deployed) {
        deployed = CREATE3.predictDeterministicAddress(salt, NICKS_FACTORY);

        if (deployed.code.length > 0) {
            console.log("  [SKIP] already deployed at", deployed);
            return deployed;
        }

        new Create3Deployer(creationCode, salt);
        require(deployed.code.length > 0, "CREATE3 deployment verification failed");
    }

    // ── Fork simulation of both bundles + end-state assertions ────────────────────

    function _impl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
    }

    /// @param proxies   upgraded proxies, index-matched with `impls`
    /// @param impls     freshly deployed implementations
    function _simulateAndVerify(string memory step1Path, string memory step2Path, address roleRegistry, address safe, address[] memory proxies, address[] memory impls) internal {
        console.log("");
        console.log("=== Simulating step 1 (upgrades + role grant + schedule) ===");
        executeGnosisTransactionBundle(step1Path);

        for (uint256 i = 0; i < proxies.length; i++) {
            require(_impl(proxies[i]) == impls[i], "impl slot mismatch after step 1");
        }
        require(RoleRegistry(roleRegistry).hasRole(GOVERNANCE_ROLE, safe), "safe missing GOVERNANCE_ROLE");
        require(RoleRegistry(roleRegistry).owner() == safe, "owner must not change in step 1");

        console.log("=== Warping past the 2-day timelock delay ===");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        console.log("=== Simulating step 2 (execute handover request + complete handover) ===");
        executeGnosisTransactionBundle(step2Path);

        require(RoleRegistry(roleRegistry).owner() == ETHERFI_TIMELOCK, "timelock is not RoleRegistry owner");

        // The safe must no longer pass owner-gated paths (e.g. granting roles)...
        vm.prank(safe);
        (bool ok,) = roleRegistry.call(abi.encodeWithSignature("grantRole(bytes32,address)", keccak256("PROBE_ROLE"), safe));
        require(!ok, "safe can still grant roles after handover");

        // ...but upgrades authorized by the new owner (the timelock) must work.
        require(RoleRegistry(roleRegistry).hasRole(GOVERNANCE_ROLE, safe), "GOVERNANCE_ROLE lost in handover");

        // Guardian safe is canceller on the timelock — and nothing more
        (, bytes memory hasCanceller) = ETHERFI_TIMELOCK.staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", CANCELLER_ROLE, CANCELLER_SAFE));
        require(abi.decode(hasCanceller, (bool)), "canceller safe missing CANCELLER_ROLE");
        (, bytes memory isProposer) = ETHERFI_TIMELOCK.staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", keccak256("PROPOSER_ROLE"), CANCELLER_SAFE));
        require(!abi.decode(isProposer, (bool)), "canceller safe must not be proposer");
        (, bytes memory isAdmin) = ETHERFI_TIMELOCK.staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", bytes32(0), CANCELLER_SAFE));
        require(!abi.decode(isAdmin, (bool)), "canceller safe must not be admin");

        console.log("");
        console.log("  [OK] all proxies upgraded");
        console.log("  [OK] safe holds GOVERNANCE_ROLE:", safe);
        console.log("  [OK] RoleRegistry owner is the timelock:", ETHERFI_TIMELOCK);
        console.log("  [OK] canceller safe holds CANCELLER_ROLE:", CANCELLER_SAFE);
    }
}
