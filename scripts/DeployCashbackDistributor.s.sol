// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console2 } from "forge-std/console2.sol";

import { UUPSProxy } from "../src/UUPSProxy.sol";
import { CashbackDistributor } from "../src/cashback-distributor/CashbackDistributor.sol";
import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";
import { EtherFiTimelock } from "../src/timelock/EtherFiTimelock.sol";
import { CashbackDistributorConfig } from "./CashbackDistributorConfig.sol";
import { GnosisHelpers } from "./utils/GnosisHelpers.sol";

/**
 * @notice Deploys CashbackDistributor on Optimism -- CREATE3 impl + CREATE3 UUPS proxy with
 *         atomic init -- through the on-chain EtherFiDeployer. The teller lands at
 *         `initialize`, so `awardStaked` is live from the proxy's first block with no
 *         privileged follow-up call.
 * @dev The script is idempotent per env: `_create3` returns the existing address when the
 *      env-scoped salt is already occupied, the dev grantRole is skipped when the grantee
 *      already holds the role, and the prod bundles are skipped when the relayer already
 *      holds the role (or refuse to overwrite an already-scheduled timelock operation), so
 *      re-running after a partial failure only produces what is still missing.
 *
 *      Two-actor flow, selected by ENV:
 *      - ENV=dev:      the broadcaster's key owns the RoleRegistry, so the deploys AND the
 *                      grantRole are broadcast directly.
 *      - ENV=mainnet:  this script performs the unprivileged CREATE3 deploys, then writes the
 *                      two Gnosis bundles for the role grant -- grantRole is owner-gated and
 *                      the prod RoleRegistry owner is the 8h EtherFiTimelock:
 *                        step 1 (Safe): timelock.schedule(grantRole, 8h)
 *                        step 2 (Safe, >= 8h after step 1 EXECUTES): timelock.execute(grantRole)
 *                      Both land in ./output/ and are fork-simulated (schedule -> warp ->
 *                      execute) before the script exits.
 *
 *      ETHFI/sETHFI/DataProvider are immutable on the implementation and the teller is
 *      validated inside `initialize` -- all four come from CashbackDistributorConfig /
 *      deployments.json, so they must be correct at deploy time.
 *
 *      Env: PRIVATE_KEY (deployer; must be registered on the EtherFiDeployer), ENV
 *      (dev|mainnet) so readDeploymentFile() resolves the RoleRegistry/DataProvider addresses
 *      and the salts get the right prefix, plus CASHBACK_DISTRIBUTOR_RELAYER (prod only; the
 *      backend relayer the timelock grants the role to).
 *
 *      Post-deploy steps (this script completes the first on dev, and generates it on prod):
 *      1. Grant `CASHBACK_DISTRIBUTOR_ROLE` to the relayer (dev: broadcast above, to the
 *         broadcaster; prod: sign the two ./output/ bundles, 8h apart).
 *      2. Fund the CashbackDistributor proxy itself with the ETHFI/other tokens that
 *         `award`/`awardBatch`/`awardStaked` pay out -- the contract custodies these funds
 *         directly and pays from its own balance.
 *      3. Run VerifyCashbackDistributor.s.sol against the live chain.
 */
contract DeployCashbackDistributor is CashbackDistributorConfig, GnosisHelpers {
    /// @notice Prod Safe (OperatingSafe) -- timelock proposer/executor, signs both bundles.
    address internal constant SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    /// @dev EtherFiTimelock at its deterministic CREATE3 address (DeployTimelock.s.sol) --
    ///      the prod OP RoleRegistry owner since the governance handover.
    address internal constant ETHERFI_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;
    uint256 internal constant TIMELOCK_DELAY = 8 hours;
    bytes32 internal constant TL_PREDECESSOR = bytes32(0);
    /// @dev Deliberately NON-ZERO: TimelockController marks an id `isOperation` forever once
    ///      scheduled, so a bytes32(0)-salted payload could never be re-scheduled after a
    ///      redeploy. Both steps derive from this one constant, so they cannot drift.
    bytes32 internal constant TL_SALT = keccak256("Cashback.GrantDistributorRole.OP");

    RoleRegistry internal roleRegistry;

    function run() public {
        require(block.chainid == 10, "This script must be run on Optimism (chain ID 10)");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        require(DEPLOYER.isDeployer(deployer), "broadcaster is not an EtherFiDeployer deployer");

        string memory deployments = readDeploymentFile();
        roleRegistry = RoleRegistry(stdJson.readAddress(deployments, ".addresses.RoleRegistry"));
        address dataProvider = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");

        address registryOwnerBefore = roleRegistry.owner();

        vm.startBroadcast(deployerPrivateKey);

        address impl = _create3(_implSalt(), type(CashbackDistributor).creationCode, abi.encode(ETHFI, SETHFI, dataProvider));

        bytes memory initData = abi.encodeCall(CashbackDistributor.initialize, (address(roleRegistry), SETHFI_TELLER));
        address proxy = _create3(_proxySalt(), type(UUPSProxy).creationCode, abi.encode(impl, initData));

        bytes32 role = CashbackDistributor(proxy).CASHBACK_DISTRIBUTOR_ROLE();
        if (_isDev() && !roleRegistry.hasRole(role, deployer)) {
            roleRegistry.grantRole(role, deployer);
        }

        vm.stopBroadcast();

        // A timelock/registry-owner handover sneaking into the same broadcast would put every
        // later privileged call under someone else's control -- fail loudly if it moved.
        require(roleRegistry.owner() == registryOwnerBefore, "CRITICAL: RoleRegistry owner changed during deploy");

        console2.log("CashbackDistributor impl :", impl);
        console2.log("CashbackDistributor proxy:", proxy);

        if (_isDev()) {
            console2.log("Granted CASHBACK_DISTRIBUTOR_ROLE to:", deployer);
        } else {
            _emitGrantRoleBundles(role);
        }
    }

    // -- Prod: Gnosis bundles for the timelocked role grant --------------------------------

    /// @dev Writes the schedule/execute bundle pair to ./output/ and fork-simulates the whole
    ///      lifecycle so a bundle that cannot work is never handed to signers.
    function _emitGrantRoleBundles(bytes32 role) internal {
        address relayer = vm.envAddress("CASHBACK_DISTRIBUTOR_RELAYER");

        // Idempotency: a grant that already landed needs no bundle.
        if (roleRegistry.hasRole(role, relayer)) {
            console2.log("Relayer already holds CASHBACK_DISTRIBUTOR_ROLE - no bundle written:", relayer);
            return;
        }

        EtherFiTimelock timelockController = EtherFiTimelock(payable(ETHERFI_TIMELOCK));
        bytes memory payload = abi.encodeWithSignature("grantRole(bytes32,address)", role, relayer);
        bytes32 opId = timelockController.hashOperation(address(roleRegistry), 0, payload, TL_PREDECESSOR, TL_SALT);

        // The grant is executed BY the timelock, so it must actually be the owner, the Safe
        // must be able to sign both steps, and this exact operation must not already be live.
        require(roleRegistry.owner() == ETHERFI_TIMELOCK, "RoleRegistry owner is not the timelock - handover not done, bundles would revert");
        require(timelockController.getMinDelay() == TIMELOCK_DELAY, "timelock minDelay != 8 hours");
        require(timelockController.hasRole(timelockController.PROPOSER_ROLE(), SAFE), "Safe is not a timelock proposer - cannot sign step 1");
        require(
            timelockController.hasRole(timelockController.EXECUTOR_ROLE(), SAFE) || timelockController.hasRole(timelockController.EXECUTOR_ROLE(), address(0)),
            "Safe is not a timelock executor - cannot sign step 2"
        );
        require(!timelockController.isOperation(opId), "this operation id is already scheduled - step 1 has already landed");

        string memory scheduleData =
            iToHex(abi.encodeWithSignature("schedule(address,uint256,bytes,bytes32,bytes32,uint256)", address(roleRegistry), 0, payload, TL_PREDECESSOR, TL_SALT, TIMELOCK_DELAY));
        string memory step1 = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
        step1 = string.concat(step1, _getGnosisTransaction(addressToHex(ETHERFI_TIMELOCK), scheduleData, "0", true));
        string memory step1Path = _writeBundle("step1-schedule", step1);

        string memory executeData = iToHex(abi.encodeWithSignature("execute(address,uint256,bytes,bytes32,bytes32)", address(roleRegistry), 0, payload, TL_PREDECESSOR, TL_SALT));
        string memory step2 = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
        step2 = string.concat(step2, _getGnosisTransaction(addressToHex(ETHERFI_TIMELOCK), executeData, "0", true));
        string memory step2Path = _writeBundle("step2-execute", step2);

        console2.log("Timelock operation id:", vm.toString(opId));

        _simulateBundles(step1Path, step2Path, opId, role, relayer);

        console2.log("");
        console2.log("Sign step 1, wait for it to EXECUTE, then wait 8h before step 2.");
    }

    function _writeBundle(string memory step, string memory txs) internal returns (string memory path) {
        vm.createDir("./output", true);
        path = string.concat("./output/CashbackDistributorGrantRole-op-", vm.toString(block.chainid), "-", step, ".json");
        vm.writeFile(path, txs);
        console2.log("Wrote", path);
    }

    /// @dev Local-fork simulation only -- pranked calls are never broadcast.
    function _simulateBundles(string memory step1Path, string memory step2Path, bytes32 opId, bytes32 role, address relayer) internal {
        EtherFiTimelock timelockController = EtherFiTimelock(payable(ETHERFI_TIMELOCK));
        address ownerBefore = roleRegistry.owner();

        console2.log("");
        console2.log("=== Simulating step 1 (schedule) ===");
        executeGnosisTransactionBundle(step1Path);
        require(timelockController.isOperationPending(opId), "SIM FAILED: operation not pending after schedule");
        require(!roleRegistry.hasRole(role, relayer), "SIM FAILED: role granted by step 1 - the delay did nothing");

        console2.log("=== Warping past the 8-hour timelock delay ===");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        require(timelockController.isOperationReady(opId), "SIM FAILED: operation not ready after the delay");

        console2.log("=== Simulating step 2 (execute) ===");
        executeGnosisTransactionBundle(step2Path);
        require(timelockController.isOperationDone(opId), "SIM FAILED: timelock operation not done");
        require(roleRegistry.hasRole(role, relayer), "SIM FAILED: relayer did not receive CASHBACK_DISTRIBUTOR_ROLE");

        // Collateral damage: a role grant must not touch ownership.
        require(roleRegistry.owner() == ownerBefore, "SIM FAILED: RoleRegistry owner changed");

        console2.log("");
        console2.log("  [OK] CASHBACK_DISTRIBUTOR_ROLE held by the relayer after execute:", relayer);
    }
}
