// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { UpgradeableBeacon } from "../../src/beacon-factory/BeaconFactory.sol";
import { EtherFiSafe } from "../../src/safe/EtherFiSafe.sol";
import { EtherFiSafeFactory } from "../../src/safe/EtherFiSafeFactory.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title UpgradeSafeImplOP3CP
 * @author ether.fi
 * @notice Points the EtherFiSafeFactory beacon at a new `EtherFiSafe` implementation, through the
 *         8h `EtherFiTimelock`. Two bundles, then a fork simulation of the whole lifecycle.
 *
 *           Step 1 (Safe, 1 tx): timelock.schedule(upgradeBeaconImplementation, 8h)
 *           Step 2 (Safe, 1 tx, >= 8h after step 1 EXECUTES): timelock.execute(...)
 *
 *         The single call the TIMELOCK runs:
 *           EtherFiSafeFactory.upgradeBeaconImplementation(SAFE_IMPL)
 *
 * @dev BLAST RADIUS. One beacon write re-points EVERY safe on the chain in the same block. There
 *      is no per-safe rollout and no opt-out, so the bytecode equality check below is the control
 *      that matters: the recorded implementation must match a local `new EtherFiSafe(dataProvider)`
 *      exactly, which proves it is this repo's source AND bound to the prod data provider.
 *
 * @dev WHY THE TIMELOCK. `upgradeBeaconImplementation` is `onlyRoleRegistryOwner`, and since the
 *      governance handover the OP RoleRegistry owner is the `EtherFiTimelock`, not the Safe. A
 *      direct Safe call would revert, so `_assertGovernance` refuses to emit bundles otherwise.
 *
 * @dev SALT: TL_SALT is deliberately NON-ZERO and mixes in the target implementation, so each
 *      upgrade gets a distinct operation id. `TimelockController` marks an id `isOperation`
 *      forever, so a fixed salt would make the second upgrade unschedulable.
 *
 * Prerequisite: the new implementation is deployed on OP and its address is in `SAFE_IMPL`.
 *
 * Usage (no broadcast — writes ./output/*.json and simulates):
 *   SAFE_IMPL=0x... forge script scripts/gnosis-txs/UpgradeSafeImplOP3CP.s.sol --rpc-url $OPTIMISM_RPC
 */
contract UpgradeSafeImplOP3CP is Utils, GnosisHelpers {
    using stdJson for string;

    /// @dev ether.fi OperatingSafe on Optimism
    address internal constant SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    /// @dev EtherFiTimelock at its deterministic CREATE3 address (DeployTimelock.s.sol)
    address internal constant ETHERFI_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;
    address internal constant OP_WETH = 0x4200000000000000000000000000000000000006;

    uint256 internal constant TIMELOCK_DELAY = 8 hours;
    bytes32 internal constant TL_PREDECESSOR = bytes32(0);

    RoleRegistry internal roleRegistry;
    EtherFiSafeFactory internal safeFactory;
    EtherFiTimelock internal timelockController;
    address internal dataProvider;
    address internal newImpl;
    address internal currentImpl;

    function run() public {
        require(block.chainid == 10, "UpgradeSafeImpl: Optimism only");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        _loadAddresses();
        _checkPreconditions();

        (string memory step1Path, string memory step2Path) = _writeBundles();
        _simulateAndVerify(step1Path, step2Path);
    }

    // ── Address loading ───────────────────────────────────────────────────────────

    function _loadAddresses() internal {
        string memory deployments = readDeploymentFile();

        roleRegistry = RoleRegistry(deployments.readAddress(".addresses.RoleRegistry"));
        safeFactory = EtherFiSafeFactory(deployments.readAddress(".addresses.EtherFiSafeFactory"));
        dataProvider = deployments.readAddress(".addresses.EtherFiDataProvider");
        timelockController = EtherFiTimelock(payable(ETHERFI_TIMELOCK));

        newImpl = vm.envAddress("SAFE_IMPL");
        currentImpl = UpgradeableBeacon(safeFactory.beacon()).implementation();
    }

    // ── Preconditions ─────────────────────────────────────────────────────────────

    function _checkPreconditions() internal {
        _assertImplementation();
        _assertGovernance();
    }

    /// @dev The recorded implementation must be byte-identical to what this repo builds against the
    ///      prod data provider. Anything else — a stale build, a dev-bound impl, a hijacked address
    ///      — fails here rather than after every safe has already been re-pointed at it.
    function _assertImplementation() internal {
        require(newImpl != address(0), "SAFE_IMPL not set");
        require(newImpl.code.length > 0, "SAFE_IMPL has no code");
        require(newImpl != currentImpl, "beacon already points at SAFE_IMPL - upgrade already done?");

        address local = address(new EtherFiSafe(dataProvider));
        require(keccak256(newImpl.code) == keccak256(local.code), "SAFE_IMPL bytecode != local EtherFiSafe build bound to the prod dataProvider");

        require(address(EtherFiSafe(payable(newImpl)).dataProvider()) == dataProvider, "SAFE_IMPL bound to a different EtherFiDataProvider");
        require(EtherFiSafe(payable(newImpl)).WETH() == OP_WETH, "SAFE_IMPL WETH is not the OP predeploy");
        require(OP_WETH.code.length > 0, "no WETH at the OP predeploy address");
    }

    /// @dev Bytecode alone does not prove configuration — the delay and proposer/executor roles live
    ///      in storage, so re-assert the full expected config before routing a privileged payload.
    function _assertGovernance() internal view {
        require(ETHERFI_TIMELOCK.code.length > 0, "EtherFiTimelock not deployed");
        require(keccak256(ETHERFI_TIMELOCK.code) == keccak256(type(EtherFiTimelock).runtimeCode), "timelock bytecode != local EtherFiTimelock build");
        require(timelockController.getMinDelay() == TIMELOCK_DELAY, "timelock minDelay != 8 hours");
        require(timelockController.hasRole(timelockController.PROPOSER_ROLE(), SAFE), "Safe is not a timelock proposer - cannot sign step 1");
        require(
            timelockController.hasRole(timelockController.EXECUTOR_ROLE(), SAFE) || timelockController.hasRole(timelockController.EXECUTOR_ROLE(), address(0)),
            "Safe is not a timelock executor - cannot sign step 2"
        );

        require(address(safeFactory.roleRegistry()) == address(roleRegistry), "factory roleRegistry mismatch - possible hijack");
        require(roleRegistry.owner() == ETHERFI_TIMELOCK, "RoleRegistry owner is not the timelock - handover not done");
        require(!timelockController.isOperation(_operationId()), "this operation id is already scheduled - step 1 has already landed");
    }

    // ── Operation construction ────────────────────────────────────────────────────

    /// @dev Salted per implementation so a later upgrade is still schedulable.
    function _salt() internal view returns (bytes32) {
        return keccak256(abi.encodePacked("UpgradeSafeImpl.OP", newImpl));
    }

    /// @dev Built once and reused by schedule, execute and the id computation — all three must be
    ///      byte-identical or execute reverts.
    function _upgradeData() internal view returns (bytes memory) {
        return abi.encodeWithSignature("upgradeBeaconImplementation(address)", newImpl);
    }

    function _operationId() internal view returns (bytes32) {
        return timelockController.hashOperation(address(safeFactory), 0, _upgradeData(), TL_PREDECESSOR, _salt());
    }

    function _writeBundles() internal returns (string memory step1Path, string memory step2Path) {
        bytes memory payload = _upgradeData();

        string memory scheduleData =
            iToHex(abi.encodeWithSignature("schedule(address,uint256,bytes,bytes32,bytes32,uint256)", address(safeFactory), 0, payload, TL_PREDECESSOR, _salt(), TIMELOCK_DELAY));
        string memory step1 = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
        step1 = string.concat(step1, _getGnosisTransaction(addressToHex(ETHERFI_TIMELOCK), scheduleData, "0", true));
        step1Path = _writeBundleFile("step1-schedule", step1);

        string memory executeData = iToHex(abi.encodeWithSignature("execute(address,uint256,bytes,bytes32,bytes32)", address(safeFactory), 0, payload, TL_PREDECESSOR, _salt()));
        string memory step2 = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
        step2 = string.concat(step2, _getGnosisTransaction(addressToHex(ETHERFI_TIMELOCK), executeData, "0", true));
        step2Path = _writeBundleFile("step2-execute", step2);

        console.log("");
        console.log("Old implementation:  ", currentImpl);
        console.log("New implementation:  ", newImpl);
        console.log("Timelock operation id:", vm.toString(_operationId()));
    }

    function _writeBundleFile(string memory step, string memory txs) internal returns (string memory path) {
        vm.createDir("./output", true);
        path = string.concat("./output/UpgradeSafeImpl-op-", vm.toString(block.chainid), "-", step, ".json");
        vm.writeFile(path, txs);
        console.log("Wrote", path);
    }

    // ── Fork simulation ───────────────────────────────────────────────────────────

    function _simulateAndVerify(string memory step1Path, string memory step2Path) internal {
        address ownerBefore = roleRegistry.owner();
        uint256 safesBefore = safeFactory.numContractsDeployed();

        address liveSafe = safesBefore > 0 ? safeFactory.getDeployedAddresses(0, 1)[0] : address(0);
        uint256 ownersBefore = liveSafe == address(0) ? 0 : EtherFiSafe(payable(liveSafe)).getOwners().length;

        console.log("");
        console.log("=== Simulating step 1 (schedule) ===");
        executeGnosisTransactionBundle(step1Path);

        bytes32 opId = _operationId();
        require(timelockController.isOperationPending(opId), "SIM FAILED: operation not pending after schedule");
        require(!timelockController.isOperationReady(opId), "SIM FAILED: operation ready before the delay elapsed");
        require(UpgradeableBeacon(safeFactory.beacon()).implementation() == currentImpl, "SIM FAILED: beacon moved during step 1 - the delay did nothing");

        console.log("=== Warping past the 8-hour timelock delay ===");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        require(timelockController.isOperationReady(opId), "SIM FAILED: operation not ready after the delay");

        console.log("=== Simulating step 2 (execute) ===");
        executeGnosisTransactionBundle(step2Path);

        require(timelockController.isOperationDone(opId), "SIM FAILED: timelock operation not done");
        require(UpgradeableBeacon(safeFactory.beacon()).implementation() == newImpl, "SIM FAILED: beacon did not move to the new implementation");

        // Every safe now runs the new code, so prove it on a real one rather than trusting the
        // beacon write: owners must survive the swap, and ETH must actually land as WETH.
        if (liveSafe != address(0)) {
            require(EtherFiSafe(payable(liveSafe)).getOwners().length == ownersBefore, "SIM FAILED: live safe lost its owners");

            // `receive` wraps only msg.value, so ETH already stranded here stays native until
            // `wrapEth` sweeps it. Assert the two mechanisms separately rather than assuming the
            // safe started empty - a stranded balance is the very thing this upgrade exists to clear.
            uint256 wethBefore = IERC20(OP_WETH).balanceOf(liveSafe);
            uint256 strandedBefore = liveSafe.balance;

            address sender = address(uint160(uint256(keccak256("UpgradeSafeImpl.sim.sender"))));
            vm.deal(sender, 1 ether);
            vm.prank(sender);
            (bool ok,) = liveSafe.call{ value: 1 ether }("");

            require(ok, "SIM FAILED: live safe rejected an ETH transfer");
            require(liveSafe.balance == strandedBefore, "SIM FAILED: incoming ETH was not wrapped on arrival");
            require(IERC20(OP_WETH).balanceOf(liveSafe) == wethBefore + 1 ether, "SIM FAILED: incoming ETH did not land as WETH");

            EtherFiSafe(payable(liveSafe)).wrapEth();
            require(liveSafe.balance == 0, "SIM FAILED: wrapEth left native ETH on the safe");
            require(IERC20(OP_WETH).balanceOf(liveSafe) == wethBefore + 1 ether + strandedBefore, "SIM FAILED: wrapEth did not sweep the stranded balance");

            console.log("  [OK] stranded ETH swept from the sampled safe (wei):", strandedBefore);
        }

        require(roleRegistry.owner() == ownerBefore, "SIM FAILED: RoleRegistry owner changed");
        require(safeFactory.numContractsDeployed() == safesBefore, "SIM FAILED: deployed safe count changed");

        console.log("");
        console.log("  [OK] beacon implementation:", newImpl);
        console.log("  [OK] live safe kept its owners, wraps incoming ETH, and sweeps via wrapEth");
        console.log("  [OK] RoleRegistry ownership and safe count unchanged");
        console.log("");
        console.log("Simulation passed. Sign step 1, wait for it to EXECUTE, then wait 8h before step 2.");
    }
}
