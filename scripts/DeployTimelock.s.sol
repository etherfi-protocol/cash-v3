// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";
import { EtherFiTimelock } from "../src/timelock/EtherFiTimelock.sol";
import { Create3Deployer } from "./utils/Create3Deployer.sol";
import { Utils } from "./utils/Utils.sol";

/// @title DeployTimelock
/// @notice Deploys the EtherFiTimelock at the same deterministic address on all 6 cash chains
///         (Ethereum, Optimism, BNB, HyperEVM, Base, Arbitrum) via Nick's factory + CREATE3,
///         With CREATE3 the address depends only on (factory, salt) — not on initcode or deployer
///         so per-chain constructor args and any signer (e.g. a Ledger) yield the
///         same address everywhere.
///
///         Config per chain: 2-day min delay; the chain's current governance — read live from
///         RoleRegistry.owner() and cross-checked against a hardcoded per-chain expectation — as
///         the only proposer, executor and canceller; no admin, so the timelock administers its
///         own roles behind the delay.
///
///         The script is idempotent: re-running on a chain where the timelock already exists
///         skips the deploy and only re-verifies the configuration. If the address was squatted
///         through Nick's factory with a different config, verification reverts.
///
/// @dev This script only deploys the timelock. Transferring RoleRegistry ownership to it must be
///      sent by the governance multisig itself (roleRegistry.transferOwnership), via
///      scripts/gnosis-txs/, after GOVERNANCE_ROLE has been granted to the multisig,
///      or config & treasury functions freeze behind the delay.
///
/// Usage (once per chain, Ledger). --slow makes forge wait for each receipt before sending
/// the next tx: the CREATE3 proxy must be mined before the creation call that targets it,
/// or that call no-ops against a codeless address and the timelock is never deployed.
///   forge script scripts/DeployTimelock.s.sol --rpc-url $MAINNET_RPC  --ledger --broadcast --slow
///   forge script scripts/DeployTimelock.s.sol --rpc-url $OPTIMISM_RPC --ledger --broadcast --slow
///   forge script scripts/DeployTimelock.s.sol --rpc-url $BSC_RPC      --ledger --broadcast --slow
///   forge script scripts/DeployTimelock.s.sol --rpc-url $HYPEREVM_RPC --ledger --broadcast --slow
///   forge script scripts/DeployTimelock.s.sol --rpc-url $BASE_RPC     --ledger --broadcast --slow
///   forge script scripts/DeployTimelock.s.sol --rpc-url $ARBITRUM_RPC --ledger --broadcast --slow
contract DeployTimelock is Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev Must be identical on every chain — it alone (with the factory) determines the address
    bytes32 constant SALT_TIMELOCK = keccak256("DeployTimelock.EtherFiTimelock");

    uint256 constant TIMELOCK_DELAY = 2 days;

    /// @dev Governance multisig owning the RoleRegistry on Ethereum, Optimism, BNB, Base, Arbitrum
    address constant GOVERNANCE_MULTISIG = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    /// @dev HyperEVM governance runs through the cash controller safe instead
    ///      (see scripts/topups-migration/UpgradeTopUpFactoryHyperEVM.s.sol)
    address constant CASH_CONTROLLER_SAFE_HYPEREVM = 0xf27128a5b064e8d97EDaa60D24bFa2FD1eeC26eB;

    function expectedGovernance(uint256 chainId) internal pure returns (address) {
        if (chainId == 1 || chainId == 10 || chainId == 56 || chainId == 8453 || chainId == 42_161) return GOVERNANCE_MULTISIG;
        if (chainId == 999) return CASH_CONTROLLER_SAFE_HYPEREVM;
        revert("DeployTimelock: unsupported chain");
    }

    function run() public {
        require(NICKS_FACTORY.code.length > 0, "Nick's factory not deployed on this chain");

        // ── 1. Resolve the chain's governance from the RoleRegistry owner ──
        string memory deployments = readDeploymentFile();
        address roleRegistry = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "RoleRegistry"));
        address governance = RoleRegistry(roleRegistry).owner();

        // Manual cross-check: the live owner must match the reviewed per-chain expectation
        require(governance == expectedGovernance(block.chainid), "RoleRegistry owner != expected governance");

        address predicted = CREATE3.predictDeterministicAddress(SALT_TIMELOCK, NICKS_FACTORY);

        console.log("=== Deploy EtherFiTimelock ===");
        console.log("Chain ID:", block.chainid);
        console.log("Governance (proposer/executor):", governance);
        console.log("Predicted timelock:", predicted);

        // ── 2. Deploy via Nick's factory + CREATE3 (skipped if already deployed) ──
        address[] memory proposers = new address[](1);
        proposers[0] = governance;

        address[] memory executors = new address[](1);
        executors[0] = governance;

        bytes memory creationCode = abi.encodePacked(type(EtherFiTimelock).creationCode, abi.encode(TIMELOCK_DELAY, proposers, executors, address(0)));

        vm.startBroadcast();
        address timelock = deployCreate3(creationCode, SALT_TIMELOCK);
        vm.stopBroadcast();

        require(timelock == predicted, "deployed address != predicted");

        // ── 3. Verify configuration (also guards a squatted or misconfigured deployment) ──
        EtherFiTimelock tl = EtherFiTimelock(payable(timelock));
        require(tl.getMinDelay() == TIMELOCK_DELAY, "delay != 2 days");
        require(tl.hasRole(tl.PROPOSER_ROLE(), governance), "governance is not proposer");
        require(tl.hasRole(tl.EXECUTOR_ROLE(), governance), "governance is not executor");
        require(tl.hasRole(tl.CANCELLER_ROLE(), governance), "governance is not canceller");
        require(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), timelock), "timelock is not its own admin");
        require(!tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), governance), "governance must not be admin");
        require(!tl.hasRole(tl.PROPOSER_ROLE(), msg.sender), "deployer must not be proposer");
        require(!tl.hasRole(tl.EXECUTOR_ROLE(), msg.sender), "deployer must not be executor");
        require(!tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), msg.sender), "deployer must not be admin");

        console.log("  [OK] EtherFiTimelock:", timelock);
        console.log("  [OK] Delay (seconds):", tl.getMinDelay());
    }

    /// @dev Atomic CREATE3 deployment via Create3Deployer — a single constructor tx that
    ///      reverts on inner-CREATE failure, so gas estimation cannot converge on a limit
    ///      where nothing gets deployed (see Create3Deployer natspec).
    function deployCreate3(bytes memory creationCode, bytes32 salt) internal returns (address deployed) {
        deployed = CREATE3.predictDeterministicAddress(salt, NICKS_FACTORY);

        if (deployed.code.length > 0) {
            console.log("  [SKIP] already deployed at", deployed);
            return deployed;
        }

        new Create3Deployer(creationCode, salt);
        require(deployed.code.length > 0, "CREATE3 deployment verification failed");
    }
}
