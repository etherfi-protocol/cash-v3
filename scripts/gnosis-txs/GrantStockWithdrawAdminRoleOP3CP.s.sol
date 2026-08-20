// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { StockWithdrawModule } from "../../src/stock-withdraw/StockWithdrawModule.sol";
import { StockWithdrawConfig } from "../stock-withdraw/StockWithdrawConfig.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";

/**
 * @title GrantStockWithdrawAdminRoleOP3CP
 * @author ether.fi
 * @notice 3CP-648 — the last leg of the stock-withdraw launch: grants
 *         `STOCK_WITHDRAW_MODULE_ADMIN_ROLE` to the OperatingSafe on the deployed OP
 *         `StockWithdrawModule`, through the 8h `EtherFiTimelock`. Two bundles, then a fork
 *         simulation of the whole lifecycle.
 *
 *           Step 1 (Safe, 1 tx): timelock.schedule(grantRole, 8h)
 *           Step 2 (Safe, 1 tx, >= 8h after step 1 EXECUTES): timelock.execute(grantRole)
 *
 *         The single call the TIMELOCK runs:
 *           RoleRegistry.grantRole(STOCK_WITHDRAW_MODULE_ADMIN_ROLE, SAFE)
 *
 * @dev WHY THE TIMELOCK. `grantRole` is `onlyOwner` and since the governance handover the OP
 *      RoleRegistry owner is the `EtherFiTimelock` (8h), not the Safe. There is no fallback path:
 *      `_assertGovernance` refuses to emit bundles if the owner is anything else, because a
 *      direct Safe `grantRole` would simply revert.
 *
 * @dev SIGN THIS AFTER 3CP-646 (the module enable), but the two are INDEPENDENT — 646 is
 *      role-gated and lands immediately, this one is owner-gated and takes an 8h round-trip.
 *      Splitting them is what lets withdrawals go live without waiting on the timelock. Nothing
 *      here is required for a user withdrawal to work: the module's full launch config lands at
 *      `initialize`, and `pause()` is PAUSER-gated. What waits for this bundle is ADJUSTMENT —
 *      `setLzGasLimits`, `configureTokens`, `configureUnwrappers`, `setProviderFee`. Treat it as
 *      launch-critical follow-through rather than cleanup: until it lands nobody can bump the LZ
 *      executor gas limits, which is the exact knob whose under-provisioning previously stranded
 *      a live withdrawal mid-flight.
 *
 * @dev SALT: TL_SALT is deliberately NON-ZERO. `TimelockController` marks an operation id
 *      `isOperation` forever once scheduled, so a `bytes32(0)`-salted operation could never be
 *      re-scheduled — and this exact payload (grant one role to the Safe) is plausibly needed
 *      again after a module redeploy. Both steps derive the id from this one constant, so they
 *      cannot drift; changing it between signing step 1 and step 2 makes step 2 revert.
 *
 * Prerequisite: the prod module is deployed and recorded at `.addresses.StockWithdrawModule` in
 * deployments/mainnet/10/deployments.json (DeployStockWithdrawModule.s.sol, ENV=mainnet).
 *
 * Usage (no broadcast — writes ./output/*.json and simulates):
 *   forge script scripts/gnosis-txs/GrantStockWithdrawAdminRoleOP3CP.s.sol --rpc-url $OPTIMISM_RPC
 */
contract GrantStockWithdrawAdminRoleOP3CP is StockWithdrawConfig, GnosisHelpers {
    using stdJson for string;

    /// @dev EtherFiTimelock at its deterministic CREATE3 address (DeployTimelock.s.sol).
    address internal constant ETHERFI_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;
    uint256 internal constant TIMELOCK_DELAY = 8 hours;
    bytes32 internal constant TL_PREDECESSOR = bytes32(0);
    /// @dev See the SALT note above — must NOT be bytes32(0).
    bytes32 internal constant TL_SALT = keccak256("3CP-648.StockWithdrawAdminRole.OP");

    /// @dev UpgradeableProxy ERC-7201 slot; first member is the roleRegistry address.
    bytes32 internal constant UPGRADEABLE_PROXY_STORAGE_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;

    RoleRegistry internal roleRegistry;
    EtherFiDataProvider internal dataProvider;
    EtherFiTimelock internal timelockController;
    StockWithdrawModule internal module;
    bytes32 internal adminRole;

    function run() public {
        require(block.chainid == 10, "GrantStockWithdrawAdminRole: Optimism only");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        _loadAddresses();
        _checkPreconditions();

        (string memory step1Path, string memory step2Path) = _writeBundles();
        _simulateAndVerify(step1Path, step2Path);
    }

    // ── Address loading ───────────────────────────────────────────────────────────

    function _loadAddresses() internal {
        string memory deployments = readDeploymentFile();

        require(
            vm.keyExistsJson(deployments, ".addresses.StockWithdrawModule"),
            "StockWithdrawModule missing from deployments.json - deploy it first (DeployStockWithdrawModule.s.sol, ENV=mainnet)"
        );

        roleRegistry = RoleRegistry(deployments.readAddress(".addresses.RoleRegistry"));
        dataProvider = EtherFiDataProvider(deployments.readAddress(".addresses.EtherFiDataProvider"));
        module = StockWithdrawModule(payable(deployments.readAddress(".addresses.StockWithdrawModule")));
        timelockController = EtherFiTimelock(payable(ETHERFI_TIMELOCK));
        adminRole = module.ADMIN_ROLE();
    }

    // ── Preconditions ─────────────────────────────────────────────────────────────

    function _checkPreconditions() internal view {
        _assertProdAddresses();
        _assertModule();
        _assertGovernance();
    }

    /// @dev The module must be the PROD one. deployments.json is hand-maintained and dev OP is
    ///      also chain 10, so a dev-salt address landing in the prod file is a real failure mode.
    function _assertModule() internal view {
        require(address(module).code.length > 0, "StockWithdrawModule has no code at the recorded address");
        require(address(module) == _predictAddress(_moduleProxySalt()), "recorded module != Prod.StockWithdraw.StockWithdrawModuleProxy.V2 CREATE3 address");
        require(adminRole == keccak256("STOCK_WITHDRAW_MODULE_ADMIN_ROLE"), "module reports an unexpected admin role - wrong address?");
        require(address(module.etherFiDataProvider()) == address(dataProvider), "module is bound to a different EtherFiDataProvider");

        address storedRegistry = address(uint160(uint256(vm.load(address(module), UPGRADEABLE_PROXY_STORAGE_SLOT))));
        require(storedRegistry == address(roleRegistry), "module roleRegistry mismatch - possible hijack");

        // Granting admin over a module whose config does not match this repo's launch set would
        // mean the on-chain module is not the one reviewed alongside this bundle.
        (address[] memory iTokens,) = _iTokens();
        for (uint256 i = 0; i < iTokens.length; i++) {
            require(module.isTokenSupported(iTokens[i]), "module does not support a configured iToken");
        }
        require(module.getSupportedTokens().length == iTokens.length, "module supports a different NUMBER of tokens than configured");
        require(module.getStockUnwrapper(ETHEREUM_EID) == _predictAddress(_unwrapperProxySalt()), "module's Ethereum route is not the prod StockUnwrapper");
    }

    /// @dev Bytecode alone does not prove configuration — the delay and the proposer/executor
    ///      roles live in storage, so re-assert the full expected config before routing a
    ///      privileged payload through this address.
    function _assertGovernance() internal view {
        require(!roleRegistry.hasRole(adminRole, SAFE), "Safe already holds STOCK_WITHDRAW_MODULE_ADMIN_ROLE - grant already done?");

        require(ETHERFI_TIMELOCK.code.length > 0, "EtherFiTimelock not deployed");
        require(keccak256(ETHERFI_TIMELOCK.code) == keccak256(type(EtherFiTimelock).runtimeCode), "timelock bytecode != local EtherFiTimelock build");
        require(timelockController.getMinDelay() == TIMELOCK_DELAY, "timelock minDelay != 8 hours");
        require(timelockController.hasRole(timelockController.PROPOSER_ROLE(), SAFE), "Safe is not a timelock proposer - cannot sign step 1");
        require(
            timelockController.hasRole(timelockController.EXECUTOR_ROLE(), SAFE) || timelockController.hasRole(timelockController.EXECUTOR_ROLE(), address(0)),
            "Safe is not a timelock executor - cannot sign step 2"
        );
        require(TL_SALT != bytes32(0), "TL_SALT must be non-zero so this payload can be re-scheduled later");

        // The grant is executed BY the timelock, so it must actually be the owner. If this is
        // still the Safe, the bundles cannot work and must not be signed.
        require(roleRegistry.owner() == ETHERFI_TIMELOCK, "RoleRegistry owner is not the timelock - handover not done");

        // An id is `isOperation` forever once scheduled, so a live pending/done operation with
        // this salt means step 1 already went out; re-signing it would revert.
        require(!timelockController.isOperation(_operationId()), "this operation id is already scheduled - step 1 has already landed");
    }

    // ── Operation construction ────────────────────────────────────────────────────

    /// @dev The single call, built once and reused by schedule, execute and the operation-id
    ///      computation — all three must be byte-identical or execute reverts.
    function _grantRoleData() internal view returns (bytes memory) {
        return abi.encodeWithSignature("grantRole(bytes32,address)", adminRole, SAFE);
    }

    function _operationId() internal view returns (bytes32) {
        return timelockController.hashOperation(address(roleRegistry), 0, _grantRoleData(), TL_PREDECESSOR, TL_SALT);
    }

    function _writeBundles() internal returns (string memory step1Path, string memory step2Path) {
        bytes memory payload = _grantRoleData();

        string memory scheduleData =
            iToHex(abi.encodeWithSignature("schedule(address,uint256,bytes,bytes32,bytes32,uint256)", address(roleRegistry), 0, payload, TL_PREDECESSOR, TL_SALT, TIMELOCK_DELAY));
        string memory step1 = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
        step1 = string.concat(step1, _getGnosisTransaction(addressToHex(ETHERFI_TIMELOCK), scheduleData, "0", true));
        step1Path = _writeBundle("step1-schedule", step1);

        string memory executeData = iToHex(abi.encodeWithSignature("execute(address,uint256,bytes,bytes32,bytes32)", address(roleRegistry), 0, payload, TL_PREDECESSOR, TL_SALT));
        string memory step2 = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
        step2 = string.concat(step2, _getGnosisTransaction(addressToHex(ETHERFI_TIMELOCK), executeData, "0", true));
        step2Path = _writeBundle("step2-execute", step2);

        console.log("");
        console.log("Timelock operation id:", vm.toString(_operationId()));
    }

    function _writeBundle(string memory step, string memory txs) internal returns (string memory path) {
        vm.createDir("./output", true);
        path = string.concat("./output/3CP-648-GrantStockWithdrawAdminRole-op-", vm.toString(block.chainid), "-", step, ".json");
        vm.writeFile(path, txs);
        console.log("Wrote", path);
    }

    // ── Fork simulation ───────────────────────────────────────────────────────────

    function _simulateAndVerify(string memory step1Path, string memory step2Path) internal {
        address ownerBefore = roleRegistry.owner();
        uint256 tokensBefore = module.getSupportedTokens().length;
        bool defaultBefore = dataProvider.isDefaultModule(address(module));

        console.log("");
        console.log("Module enabled (3CP-646 landed):", defaultBefore);

        console.log("");
        console.log("=== Simulating step 1 (schedule) ===");
        executeGnosisTransactionBundle(step1Path);

        bytes32 opId = _operationId();
        require(timelockController.isOperationPending(opId), "SIM FAILED: operation not pending after schedule");
        require(!timelockController.isOperationReady(opId), "SIM FAILED: operation ready before the delay elapsed");
        require(!roleRegistry.hasRole(adminRole, SAFE), "SIM FAILED: role granted by step 1 - the delay did nothing");

        console.log("=== Warping past the 8-hour timelock delay ===");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        require(timelockController.isOperationReady(opId), "SIM FAILED: operation not ready after the delay");

        console.log("=== Simulating step 2 (execute) ===");
        executeGnosisTransactionBundle(step2Path);

        require(timelockController.isOperationDone(opId), "SIM FAILED: timelock operation not done");
        require(roleRegistry.hasRole(adminRole, SAFE), "SIM FAILED: Safe did not receive STOCK_WITHDRAW_MODULE_ADMIN_ROLE");

        // Hash equality is not proof: drive the real admin setters as the Safe, with the CURRENT
        // values so the calls cannot change config. `setLzGasLimits` specifically, because that
        // is the knob this whole bundle exists to make reachable.
        (uint16 feeBps, address feeReceiver) = module.getProviderFee();
        vm.prank(SAFE);
        module.setProviderFee(feeBps, feeReceiver);
        (uint128 lzReceiveGas, uint128 composeGas) = module.getLzGasLimits();
        vm.prank(SAFE);
        module.setLzGasLimits(lzReceiveGas, composeGas);

        // Collateral damage: a role grant must not touch ownership, the module's config or the
        // module's enabled state.
        require(roleRegistry.owner() == ownerBefore, "SIM FAILED: RoleRegistry owner changed");
        require(roleRegistry.owner() == ETHERFI_TIMELOCK, "SIM FAILED: RoleRegistry owner is not the timelock");
        require(module.getSupportedTokens().length == tokensBefore, "SIM FAILED: module token set changed");
        require(dataProvider.isDefaultModule(address(module)) == defaultBefore, "SIM FAILED: module default status changed");

        console.log("");
        console.log("  [OK] STOCK_WITHDRAW_MODULE_ADMIN_ROLE held by the Safe:", SAFE);
        console.log("  [OK] admin setters callable by the Safe (setProviderFee + setLzGasLimits verified)");
        console.log("  [OK] module config and enabled state unchanged");
        console.log("");
        console.log("3CP-648 simulation passed. Sign step 1, wait for it to EXECUTE, then wait 8h before step 2.");
    }
}
