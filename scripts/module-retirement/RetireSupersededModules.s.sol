// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/// @title RetireSupersededModules
/// @notice Generates the Gnosis Safe Transaction Builder bundles that retire the superseded Optimism Cash
///         modules and the per-contract admin roles the role re-gating removed, then simulates them on a
///         fork and asserts the end state. It contains no broadcast call: it only writes JSON files and
///         runs the fork simulation with prank.
///
///         Optimism (chain 10) produces two bundles, both signed by the governance Safe (0xA6cf...AAC4),
///         each holding one call per timelock:
///           schedule: 8h operating timelock.scheduleBatch(module retirement)
///                     2-day upgrade timelock.scheduleBatch(role revocations)
///           execute (not before 48 hours after the schedule):
///                     8h operating timelock.executeBatch(module retirement)
///                     2-day upgrade timelock.executeBatch(role revocations)
///         Ethereum (chain 1) produces two single-call bundles: scheduleBatch and executeBatch on the 2-day
///         timelock, for the role revocations only.
///
///         1. Module retirement (Optimism, every function gated on ADMIN_TIMELOCK_ROLE once the re-gated
///            code is live, so it goes through the 8 hour timelock):
///            Retired (old -> replacement): EtherFiLiquidModule, EtherFiLiquidModuleWithReferrer,
///            StargateModule, BeHYPEStakeModule, MidasModule. The replacements are already default,
///            whitelisted, requesters and drivers with the same configuration. The batch, in order:
///              a. CashModule.configureModulesCanRequestWithdraw([old Liquid, old Liquid referrer, old Stargate], false)
///              b. LendGateway.setDriver(old, false) for old Liquid, Liquid referrer, BeHYPE and Midas
///              c. EtherFiDataProvider.configureModules([5 old modules], false)
///                 (false removes a module from the whitelist AND the default set in one call)
///            Ordering is not forced by the contracts: configureModulesCanRequestWithdraw only checks that
///            a module is whitelisted when ADDING it, and setDriver and configureModules do not look at
///            each other's state. The order above stops new withdrawal requests first and removes the
///            module from the Safes last.
///
///         2. Role revocation (both chains; RoleRegistry-owner calls, so the 2-day timelock): every holder of
///            every role whose constant the re-gating removed, on the cash and trading RoleRegistry of the
///            chain. The holders are read live. Roles that still exist in the code (ADMIN_ROLE,
///            ADMIN_TIMELOCK_ROLE, PAUSER, UNPAUSER and every operational role) are never touched, and the
///            simulation asserts their holders are identical afterwards.
///
///         Hard precondition for 1: no pending withdrawal or bridge on any retired module. A Cash withdrawal
///         requested by a module pays out to the module, and once the module stops being a requester
///         processWithdrawal is open to anyone while the module has no sweep. The Safe set is too large
///         to scan on-chain (about 540k Safes), so the preflight runs
///         scripts/module-retirement/check-pending-retired-modules.sh through ffi, which scans the
///         withdrawal events and confirms every suspect against live state. A non-zero count reverts
///         the script unless ALLOW_PENDING_COUNT acknowledges it, which exists only so a bundle can be
///         simulated while a known pending item is still being resolved. Re-run the preflight right
///         before executing the batch: a withdrawal requested between schedule and execute is not
///         covered by the one at generation time.
///
///         The re-gating rollout has to be live for the batches to execute. If the fork predates it (the
///         trading RoleRegistry is not yet owned by the 2-day timelock), the queued rollout transaction is
///         fetched from the Safe transaction service (the pending re-gating execute on each chain) and replayed
///         first as the Safe, after warping past its 2 day delay. Pass ROLLOUT_JSON=<path> to replay a
///         file instead of fetching, or ROLLOUT_NONCE to replay another nonce.
///
/// Usage (no broadcast; writes ./output/*.json and simulates):
///   ENV=mainnet forge script scripts/module-retirement/RetireSupersededModules.s.sol --rpc-url $OPTIMISM_RPC
///   ENV=mainnet forge script scripts/module-retirement/RetireSupersededModules.s.sol --rpc-url $MAINNET_RPC
///   Optional: ROLLOUT_NONCE, ROLLOUT_JSON, ALLOW_PENDING_COUNT, LOGS_RPC
contract RetireSupersededModules is GnosisHelpers, Utils {
    // ─────────────────────────────── governance and live addresses ───────────────────────────────

    address internal constant SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address internal constant UPGRADE_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;
    address internal constant OPERATING_TIMELOCK = 0x9AEb8eaa982084219d1A938D8F7B5040a1d47849;
    uint256 internal constant UPGRADE_DELAY = 2 days;
    uint256 internal constant OPERATING_DELAY = 8 hours;

    // Optimism
    address internal constant CASH_REGISTRY_OP = 0x5C1E3D653fcbC54Ae25c2AD9d59548D2082C687B;
    address internal constant DATA_PROVIDER = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address internal constant CASH_MODULE = 0x7Ca0b75E67E33c0014325B739A8d019C4FE445F0;
    address internal constant LEND_GATEWAY = 0x01F8cDFb1694eA8fE4ED6c38a0fD78d1188E03F4;
    // Ethereum
    address internal constant CASH_REGISTRY_ETH = 0x55963de88267Aa3D1D995c359e8068D0Df34BEBb;
    // Trading RoleRegistry (same address on both chains)
    address internal constant TRADING_REGISTRY = 0xBdAe3A2EfDFf4f27Dc1D89E0BEdb88F3e9A62Bd0;

    bytes32 internal constant TL_PREDECESSOR = bytes32(0);
    bytes32 internal constant TL_SALT_MODULES = keccak256("RetireSupersededModules.OP.v1");
    bytes32 internal constant TL_SALT_ROLES = keccak256("RetireSupersededModules.Roles.v1");

    uint256 internal constant N = 5;
    string internal constant PENDING_CHECK = "scripts/module-retirement/check-pending-retired-modules.sh";
    string internal constant PUBLIC_STATE_RPC = "https://optimism-rpc.publicnode.com";
    string internal constant PUBLIC_LOGS_RPC = "https://optimism.gateway.tenderly.co";

    // Index-aligned: Liquid, Liquid with referrer, Stargate, BeHYPE stake, Midas
    address[5] internal OLD = [
        0x427fDe7FF5D685e76f572BDFb896184a2048f232,
        0xA051246A613E3216DD90402453D3B8aD63E71Cd1,
        0x865a756d15e40D1D38595a39F29867518594182E,
        0x46E9aF4DC3D4535AfCbeb408Db564D729F527bD8,
        0x80b14dC43d257C6bC7487249095F1435d43fC591
    ];
    address[5] internal NEW = [
        0xf4d5Be5CfcCE8C32785FC36bF3851D2f1E3C0154,
        0x48651bf1ED1eE15C7493a79188E3326602b321c4,
        0x8ad28aB6b117dA4f9cf92960cd43bDAA7FE45be4,
        0xd2fBD2fCac7e88ef323694e617141Efb20140c56,
        0x1052fDcE6CBE3D2AD265050e1426D41E23fc54dc
    ];
    string[5] internal NAMES = ["EtherFiLiquidModule", "EtherFiLiquidModuleWithReferrer", "StargateModule", "BeHYPEStakeModule", "MidasModule"];
    /// @dev Withdraw requesters among the five: Liquid, Liquid with referrer, Stargate
    bool[5] internal IS_REQUESTER = [true, true, true, false, false];
    /// @dev LendGateway drivers among the five: everything but Stargate
    bool[5] internal IS_DRIVER = [true, true, false, true, true];

    // Roles whose constant the role re-gating (cash-v3 PR #289) removed from the code. Nothing in the
    // current code checks any of them; the consolidated ADMIN_ROLE / ADMIN_TIMELOCK_ROLE replaced them.
    string[16] internal REMOVED_ROLES = [
        "ACROSS_SWAP_MODULE_ADMIN_ROLE",
        "BEHYPE_STAKE_MODULE_ADMIN_ROLE",
        "CASHBACK_DISPATCHER_ADMIN_ROLE",
        "CASH_MODULE_CONTROLLER_ROLE",
        "DATA_PROVIDER_ADMIN_ROLE",
        "DEBT_MANAGER_ADMIN_ROLE",
        "ENSO_SWAP_MODULE_ADMIN_ROLE",
        "ETHERFI_LIQUID_MODULE_ADMIN",
        "LEND_GATEWAY_ADMIN_ROLE",
        "MIDAS_MODULE_ADMIN",
        "PRICE_PROVIDER_ADMIN_ROLE",
        "STARGATE_MODULE_ADMIN_ROLE",
        "STOCK_UNWRAPPER_ADMIN_ROLE",
        "STOCK_WITHDRAW_MODULE_ADMIN_ROLE",
        "TRADING_LENS_ADMIN_ROLE",
        "WORMHOLE_MODULE_ADMIN_ROLE"
    ];

    // Every role constant that still exists in the code. Their holders must be identical after the batch.
    string[17] internal KEPT_ROLES = [
        "ADMIN_ROLE",
        "ADMIN_TIMELOCK_ROLE",
        "CASHBACK_DISTRIBUTOR_ROLE",
        "CCTP_MODULE_ADMIN_ROLE",
        "DEPOSITOR_ROLE",
        "ETHERFI_SAFE_FACTORY_ADMIN_ROLE",
        "ETHER_FI_WALLET_ROLE",
        "PAUSER",
        "RAMP_VOLUME_EMITTER_ROLE",
        "SETTLEMENT_DISPATCHER_BRIDGER_ROLE",
        "TOPUP_FACTORY_BRIDGER_ROLE",
        "TOPUP_FACTORY_REDIRECT_ROLE",
        "TOP_UP_ROLE",
        "TRADING_SAFE_FACTORY_ADMIN_ROLE",
        "TRADING_SAFE_LIQUID_DEPOSIT_MODULE_ADMIN",
        "TRADING_SAFE_REDIRECT_ROLE",
        "UNPAUSER"
    ];

    // 8h batch: module retirement (Optimism only)
    address[] internal targets;
    bytes[] internal payloads;
    // 2-day batch: role revocations
    address[] internal revTargets;
    bytes[] internal revPayloads;

    /// @dev One revocation, kept so the end state can assert it
    struct Revocation {
        address registry;
        bytes32 role;
        address holder;
    }

    Revocation[] internal revocations;

    struct Snapshot {
        address[] whitelisted;
        address[] defaults;
        address[] requesters;
        bool[] otherDrivers;
        bytes32[] keptRoleDigests;
    }

    function run() public {
        require(block.chainid == 10 || block.chainid == 1, "RetireSupersededModules: Optimism or Ethereum only");
        require(isEqualString(getEnv(), "mainnet"), "ENV must be mainnet");
        bool isOp = block.chainid == 10;

        console.log("Fork block:", block.number);
        console.log("Fork timestamp:", block.timestamp);
        _checkTimelock(UPGRADE_TIMELOCK, UPGRADE_DELAY);
        _checkTimelock(OPERATING_TIMELOCK, OPERATING_DELAY);

        address[] memory registries = new address[](2);
        registries[0] = isOp ? CASH_REGISTRY_OP : CASH_REGISTRY_ETH;
        registries[1] = TRADING_REGISTRY;

        if (isOp) {
            _checkRecords();
            // The gate for a retired module with something in flight comes first: nothing below matters
            // if retiring would strand funds.
            _checkNoPending();
        }

        // Bring the fork to the post-rollout state the batches execute against.
        if (RoleRegistry(TRADING_REGISTRY).owner() != UPGRADE_TIMELOCK) _replayQueuedRollout();
        _checkRegistries(registries);
        if (isOp) _checkPreState();

        Snapshot memory before = _snapshot(registries, isOp);

        if (isOp) _buildModuleBatch();
        _buildRevocations(registries);
        require(revTargets.length > 0, "no retired role has a holder: nothing to revoke");
        (string memory schedulePath, string memory executePath) = _writeBundles(isOp);

        TimelockController tl8 = TimelockController(payable(OPERATING_TIMELOCK));
        TimelockController tl2 = TimelockController(payable(UPGRADE_TIMELOCK));
        bytes32 id8 = tl8.hashOperationBatch(targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, TL_SALT_MODULES);
        bytes32 id2 = tl2.hashOperationBatch(revTargets, new uint256[](revTargets.length), revPayloads, TL_PREDECESSOR, TL_SALT_ROLES);
        if (isOp) {
            console.log("8h operation id:");
            console.logBytes32(id8);
            require(!tl8.isOperation(id8), "module operation already scheduled on the operating timelock");
        }
        console.log("2-day operation id:");
        console.logBytes32(id2);
        require(!tl2.isOperation(id2), "role operation already scheduled on the upgrade timelock");

        // The Safe cannot make these changes directly; only the timelocks can.
        _probeSafeLockedOut(registries, isOp);

        console.log("=== Simulating schedule ===");
        executeGnosisTransactionBundle(schedulePath);
        require(tl2.isOperationPending(id2) && !tl2.isOperationReady(id2), "role operation not pending after schedule");
        if (isOp) require(tl8.isOperationPending(id8) && !tl8.isOperationReady(id8), "module operation not pending after schedule");

        // Nothing executes before its delay
        vm.prank(SAFE);
        (bool ok,) = UPGRADE_TIMELOCK.call(_executeData(revTargets, revPayloads, TL_SALT_ROLES));
        require(!ok, "2-day executeBatch succeeded before the delay elapsed");
        if (isOp) {
            vm.prank(SAFE);
            (ok,) = OPERATING_TIMELOCK.call(_executeData(targets, payloads, TL_SALT_MODULES));
            require(!ok, "8h executeBatch succeeded before the delay elapsed");
            console.log("=== Warping 8 hours: only the module batch is ready ===");
            vm.warp(block.timestamp + OPERATING_DELAY + 1);
            require(tl8.isOperationReady(id8) && !tl2.isOperationReady(id2), "unexpected readiness after 8 hours");
            vm.prank(SAFE);
            (ok,) = UPGRADE_TIMELOCK.call(_executeData(revTargets, revPayloads, TL_SALT_ROLES));
            require(!ok, "2-day executeBatch succeeded after only 8 hours");
        }
        console.log("=== Warping to 2 days ===");
        vm.warp(block.timestamp + UPGRADE_DELAY + 1);
        require(tl2.isOperationReady(id2), "role operation not ready after the delay");

        console.log("=== Simulating execute ===");
        executeGnosisTransactionBundle(executePath);
        require(tl2.isOperationDone(id2), "role operation not done after execute");
        if (isOp) require(tl8.isOperationDone(id8), "module operation not done after execute");

        _assertEndState(before, registries, isOp);
        console.log("");
        console.log("  [OK] retirement bundles simulated; end state verified");
    }

    // ─────────────────────────────── preflight ───────────────────────────────

    function _checkTimelock(address timelock, uint256 delay) internal view {
        require(keccak256(timelock.code) == keccak256(type(EtherFiTimelock).runtimeCode), "timelock bytecode != local build");
        EtherFiTimelock tl = EtherFiTimelock(payable(timelock));
        require(tl.getMinDelay() == delay, "timelock: unexpected delay");
        require(tl.hasRole(tl.PROPOSER_ROLE(), SAFE) && tl.hasRole(tl.EXECUTOR_ROLE(), SAFE), "Safe is not proposer/executor");
        require(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), timelock) && !tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), SAFE), "timelock admin misconfigured");
    }

    /// @dev The pinned addresses must equal the deploy record and the current deployments file
    function _checkRecords() internal view {
        string memory rec = vm.readFile("./deployments/mainnet/10/role-gating-batch3.json");
        string memory dep = readDeploymentFile();
        string[5] memory oldKeys = ["old_liquidModule", "old_liquidReferrerModule", "old_stargateModule", "old_beHypeStakeModule", "old_midasModule"];
        string[5] memory newKeys = ["liquidModule", "liquidReferrerModule", "stargateModule", "beHypeStakeModule", "midasModule"];
        for (uint256 k = 0; k < N; ++k) {
            require(stdJson.readAddress(rec, string.concat(".", oldKeys[k])) == OLD[k], string.concat("old module != deploy record: ", NAMES[k]));
            require(stdJson.readAddress(rec, string.concat(".", newKeys[k])) == NEW[k], string.concat("new module != deploy record: ", NAMES[k]));
            // deployments.json already points at the replacement (the backend reads it)
            require(stdJson.readAddress(dep, string.concat(".addresses.", NAMES[k])) == NEW[k], string.concat("deployments.json not on the new module: ", NAMES[k]));
        }
    }

    /// @dev Zero pending withdrawals/bridges on every retired module, or revert
    function _checkNoPending() internal {
        string memory stateRpc = vm.envOr("OPTIMISM_RPC", PUBLIC_STATE_RPC);
        string memory logsRpc = vm.envOr("LOGS_RPC", PUBLIC_LOGS_RPC);
        string[] memory cmd = new string[](5);
        cmd[0] = "bash";
        cmd[1] = "-c";
        // Prints only the count; a script failure leaves it empty, which fails the parse below
        cmd[2] = string.concat("'", PENDING_CHECK, "' \"$0\" \"$1\" 2>/dev/null | grep -E '^PENDING_COUNT=' | cut -d= -f2");
        cmd[3] = stateRpc;
        cmd[4] = logsRpc;
        bytes memory out = vm.ffi(cmd);
        require(out.length > 0, "pending-withdrawal preflight failed to run (see check-pending-retired-modules.sh)");
        uint256 pending = vm.parseUint(string(out));
        uint256 allowed = vm.envOr("ALLOW_PENDING_COUNT", uint256(0));
        console.log("Pending withdrawals/bridges on retired modules:", pending);
        if (pending > 0) {
            require(pending <= allowed, "pending withdrawals on retired modules: resolve them before generating (see the preflight output)");
            console.log("  WARNING: simulating with an acknowledged pending item. Do NOT queue this bundle until the preflight shows 0.");
        }
    }

    /// @dev Replays the queued rollout (Safe-signed, executes the 2-day batch and the handover) as the Safe
    function _replayQueuedRollout() internal {
        console.log("Rollout not executed on this fork yet: replaying the queued rollout first");
        string memory path = vm.envOr("ROLLOUT_JSON", string(""));
        if (bytes(path).length == 0) {
            path = string.concat("./output/queued-rollout-", vm.toString(block.chainid), ".json");
            string[] memory cmd = new string[](5);
            cmd[0] = "bash";
            cmd[1] = "scripts/module-retirement/queued-safe-tx-to-json.sh";
            cmd[2] = vm.toString(block.chainid);
            cmd[3] = vm.toString(vm.envOr("ROLLOUT_NONCE", block.chainid == 10 ? uint256(127) : uint256(64)));
            cmd[4] = path;
            vm.createDir("./output", true);
            vm.ffi(cmd);
        }
        require(vm.parseJsonAddress(vm.readFile(path), ".safeAddress") == SAFE, "rollout file is for another Safe");
        vm.warp(block.timestamp + UPGRADE_DELAY + 1);
        executeGnosisTransactionBundle(path);
        require(RoleRegistry(TRADING_REGISTRY).owner() == UPGRADE_TIMELOCK, "rollout did not hand the trading registry to the 2-day timelock");
    }

    /// @dev Both registries run the re-gated code, are owned by the 2-day timelock, and keep both admin roles
    function _checkRegistries(address[] memory registries) internal view {
        for (uint256 i = 0; i < registries.length; ++i) {
            RoleRegistry reg = RoleRegistry(registries[i]);
            require(reg.owner() == UPGRADE_TIMELOCK, "RoleRegistry owner != 2-day timelock");
            reg.onlyAdmin(SAFE);
            reg.onlyAdminTimelock(OPERATING_TIMELOCK);
        }
    }

    /// @dev State the module batch relies on: old modules still wired, replacements fully wired
    function _checkPreState() internal view {
        EtherFiDataProvider dp = EtherFiDataProvider(DATA_PROVIDER);
        address[] memory requesters = ICashModule(CASH_MODULE).getWhitelistedModulesCanRequestWithdraw();
        LendGateway gw = LendGateway(LEND_GATEWAY);
        for (uint256 k = 0; k < N; ++k) {
            require(dp.isWhitelistedModule(OLD[k]) && dp.isDefaultModule(OLD[k]), string.concat("old module not whitelisted+default: ", NAMES[k]));
            require(_contains(requesters, OLD[k]) == IS_REQUESTER[k], string.concat("old module requester flag unexpected: ", NAMES[k]));
            require(gw.isDriver(OLD[k]) == IS_DRIVER[k], string.concat("old module driver flag unexpected: ", NAMES[k]));

            require(dp.isWhitelistedModule(NEW[k]) && dp.isDefaultModule(NEW[k]), string.concat("replacement not whitelisted+default: ", NAMES[k]));
            require(_contains(requesters, NEW[k]) == IS_REQUESTER[k], string.concat("replacement requester flag unexpected: ", NAMES[k]));
            require(gw.isDriver(NEW[k]) == IS_DRIVER[k], string.concat("replacement driver flag unexpected: ", NAMES[k]));
        }
    }

    // ─────────────────────────────── batches ───────────────────────────────

    function _buildModuleBatch() internal {
        // 1. stop new withdrawal requests through the retired modules
        uint256 nReq;
        for (uint256 k = 0; k < N; ++k) if (IS_REQUESTER[k]) ++nReq;
        address[] memory reqModules = new address[](nReq);
        bool[] memory reqFlags = new bool[](nReq);
        uint256 j;
        for (uint256 k = 0; k < N; ++k) {
            if (IS_REQUESTER[k]) reqModules[j++] = OLD[k];
        }
        _add(CASH_MODULE, abi.encodeWithSelector(ICashModule.configureModulesCanRequestWithdraw.selector, reqModules, reqFlags));

        // 2. drop the gateway driver authorisation
        for (uint256 k = 0; k < N; ++k) {
            if (IS_DRIVER[k]) _add(LEND_GATEWAY, abi.encodeWithSelector(LendGateway.setDriver.selector, OLD[k], false));
        }

        // 3. remove from the whitelist and the default set (every Safe stops seeing them enabled)
        address[] memory all = new address[](N);
        bool[] memory allFlags = new bool[](N);
        for (uint256 k = 0; k < N; ++k) all[k] = OLD[k];
        _add(DATA_PROVIDER, abi.encodeWithSelector(EtherFiDataProvider.configureModules.selector, all, allFlags));
    }

    /// @dev One revokeRole per (registry, removed role, live holder), in registry then role order
    function _buildRevocations(address[] memory registries) internal {
        for (uint256 i = 0; i < registries.length; ++i) {
            for (uint256 r = 0; r < REMOVED_ROLES.length; ++r) {
                bytes32 role = keccak256(bytes(REMOVED_ROLES[r]));
                address[] memory holders = RoleRegistry(registries[i]).roleHolders(role);
                for (uint256 h = 0; h < holders.length; ++h) {
                    revTargets.push(registries[i]);
                    revPayloads.push(abi.encodeWithSelector(RoleRegistry.revokeRole.selector, role, holders[h]));
                    revocations.push(Revocation({ registry: registries[i], role: role, holder: holders[h] }));
                    console.log(string.concat("  revoke ", REMOVED_ROLES[r], " from"), holders[h]);
                    console.log("    on registry", registries[i]);
                }
            }
        }
        console.log("  role revocations:", revTargets.length);
    }

    function _add(address to, bytes memory data) internal {
        targets.push(to);
        payloads.push(data);
    }

    function _scheduleData(address[] memory t, bytes[] memory p, bytes32 salt, uint256 delay) internal pure returns (bytes memory) {
        return abi.encodeCall(TimelockController.scheduleBatch, (t, new uint256[](t.length), p, TL_PREDECESSOR, salt, delay));
    }

    function _executeData(address[] memory t, bytes[] memory p, bytes32 salt) internal pure returns (bytes memory) {
        return abi.encodeCall(TimelockController.executeBatch, (t, new uint256[](t.length), p, TL_PREDECESSOR, salt));
    }

    function _writeBundles(bool isOp) internal returns (string memory schedulePath, string memory executePath) {
        string memory chain = vm.toString(block.chainid);
        string memory sched = _getGnosisHeader(chain, addressToHex(SAFE));
        string memory exec = _getGnosisHeader(chain, addressToHex(SAFE));
        if (isOp) {
            // 8h batch first, then the 2-day batch (both orders are valid; this one retires modules first)
            sched = string.concat(sched, _getGnosisTransaction(addressToHex(OPERATING_TIMELOCK), iToHex(_scheduleData(targets, payloads, TL_SALT_MODULES, OPERATING_DELAY)), "0", false));
            exec = string.concat(exec, _getGnosisTransaction(addressToHex(OPERATING_TIMELOCK), iToHex(_executeData(targets, payloads, TL_SALT_MODULES)), "0", false));
        }
        sched = string.concat(sched, _getGnosisTransaction(addressToHex(UPGRADE_TIMELOCK), iToHex(_scheduleData(revTargets, revPayloads, TL_SALT_ROLES, UPGRADE_DELAY)), "0", true));
        exec = string.concat(exec, _getGnosisTransaction(addressToHex(UPGRADE_TIMELOCK), iToHex(_executeData(revTargets, revPayloads, TL_SALT_ROLES)), "0", true));

        vm.createDir("./output", true);
        schedulePath = string.concat("./output/RetireSupersededModules-", chain, "-schedule.json");
        executePath = string.concat("./output/RetireSupersededModules-", chain, "-execute.json");
        vm.writeFile(schedulePath, sched);
        vm.writeFile(executePath, exec);
        console.log("Wrote", schedulePath);
        console.log("Wrote", executePath);
        console.log("  module batch calls:", targets.length);
        console.log("  role batch calls:  ", revTargets.length);
    }

    // ─────────────────────────────── simulation checks ───────────────────────────────

    function _probeSafeLockedOut(address[] memory registries, bool isOp) internal {
        address[] memory one = new address[](1);
        one[0] = OLD[0];
        bool[] memory no = new bool[](1);
        if (isOp) {
            vm.prank(SAFE);
            (bool ok,) = DATA_PROVIDER.call(abi.encodeWithSelector(EtherFiDataProvider.configureModules.selector, one, no));
            require(!ok, "Safe can still configureModules directly");
            vm.prank(SAFE);
            (ok,) = CASH_MODULE.call(abi.encodeWithSelector(ICashModule.configureModulesCanRequestWithdraw.selector, one, no));
            require(!ok, "Safe can still configureModulesCanRequestWithdraw directly");
            vm.prank(SAFE);
            (ok,) = LEND_GATEWAY.call(abi.encodeWithSelector(LendGateway.setDriver.selector, OLD[0], false));
            require(!ok, "Safe can still setDriver directly");
        }
        // revokeRole is a RoleRegistry-owner call
        for (uint256 i = 0; i < registries.length; ++i) {
            vm.prank(SAFE);
            (bool ok2,) = registries[i].call(abi.encodeWithSelector(RoleRegistry.revokeRole.selector, keccak256("PROBE"), SAFE));
            require(!ok2, "Safe can still revokeRole directly");
        }
        console.log("  [OK] the Safe cannot make these changes directly; only the timelocks can");
    }

    /// @dev Everything outside the retired five and the removed roles that must be identical across the batches
    function _snapshot(address[] memory registries, bool isOp) internal view returns (Snapshot memory s) {
        if (isOp) {
            EtherFiDataProvider dp = EtherFiDataProvider(DATA_PROVIDER);
            s.whitelisted = dp.getWhitelistedModules();
            s.defaults = dp.getDefaultModules();
            s.requesters = ICashModule(CASH_MODULE).getWhitelistedModulesCanRequestWithdraw();
            address[] memory others = _otherDriverCandidates();
            s.otherDrivers = new bool[](others.length);
            for (uint256 i = 0; i < others.length; ++i) s.otherDrivers[i] = LendGateway(LEND_GATEWAY).isDriver(others[i]);
        }
        s.keptRoleDigests = _keptRoleDigests(registries);
    }

    function _keptRoleDigests(address[] memory registries) internal view returns (bytes32[] memory d) {
        d = new bytes32[](registries.length * KEPT_ROLES.length);
        for (uint256 i = 0; i < registries.length; ++i) {
            for (uint256 r = 0; r < KEPT_ROLES.length; ++r) {
                d[i * KEPT_ROLES.length + r] = keccak256(abi.encode(RoleRegistry(registries[i]).roleHolders(keccak256(bytes(KEPT_ROLES[r])))));
            }
        }
    }

    /// @dev Every address that was a LendGateway driver other than the five retired (from the DriverSet
    ///      history) plus the five replacements
    function _otherDriverCandidates() internal view returns (address[] memory list) {
        list = new address[](14);
        list[0] = 0x0078C5a459132e279056B2371fE8A8eC973A9553; // DebtManager
        list[1] = 0x3a6A724595184dda4be69dB1Ce726F2Ac3D66B87; // TopUpDest
        list[2] = 0x850D01FfCD8d23fA29751Eb26F8A473FFa4FFD0A; // OpenOceanSwapModule
        list[3] = 0x3C97a4899a92b7e84d92c5032dC7d865E7471EcE; // FraxModule
        list[4] = 0xD4F81cF925248513631723A5cd0a8842f8cC2C3E; // EtherFiStakeModule
        list[5] = 0x39161A44588ec2327a18D4707EA5216C721ba539; // LiquidUSDLiquifierModule
        list[6] = 0xac6BcA0bB66D4587171CFc77b19E5E68F74De55e; // EnsoSwapModule
        list[7] = 0x241D0227e6Ae4df1747f2A04F4bF3d33eD850cA7; // AcrossSwapModule
        list[8] = 0x162c9f902867308B6f92c80B7329f5883385FC87; // MidasLiquifierModule
        // the replacements (the Stargate one is not a driver and must stay that way)
        for (uint256 k = 0; k < N; ++k) list[9 + k] = NEW[k];
    }

    function _assertEndState(Snapshot memory before, address[] memory registries, bool isOp) internal view {
        if (isOp) _assertModules(before);

        // Removed roles: no holder left on either registry, and exactly the recorded revocations happened
        for (uint256 i = 0; i < registries.length; ++i) {
            for (uint256 r = 0; r < REMOVED_ROLES.length; ++r) {
                require(RoleRegistry(registries[i]).roleHolders(keccak256(bytes(REMOVED_ROLES[r]))).length == 0, string.concat("removed role still has a holder: ", REMOVED_ROLES[r]));
            }
        }
        for (uint256 k = 0; k < revocations.length; ++k) {
            require(!RoleRegistry(revocations[k].registry).hasRole(revocations[k].role, revocations[k].holder), "revoked holder still has the role");
        }

        // Kept roles untouched: ADMIN_ROLE (Safe), ADMIN_TIMELOCK_ROLE (8h timelock), PAUSER/UNPAUSER and every operational role
        bytes32[] memory afterDigests = _keptRoleDigests(registries);
        for (uint256 k = 0; k < afterDigests.length; ++k) require(afterDigests[k] == before.keptRoleDigests[k], "a kept role's holders changed");
        for (uint256 i = 0; i < registries.length; ++i) {
            RoleRegistry(registries[i]).onlyAdmin(SAFE);
            RoleRegistry(registries[i]).onlyAdminTimelock(OPERATING_TIMELOCK);
            require(!RoleRegistry(registries[i]).hasRole(keccak256("ADMIN_TIMELOCK_ROLE"), SAFE), "Safe must not hold ADMIN_TIMELOCK_ROLE");
            // Governance unchanged
            require(RoleRegistry(registries[i]).owner() == UPGRADE_TIMELOCK, "CRITICAL: RoleRegistry owner changed");
        }
        require(EtherFiTimelock(payable(UPGRADE_TIMELOCK)).getMinDelay() == UPGRADE_DELAY, "upgrade timelock delay changed");
        require(EtherFiTimelock(payable(OPERATING_TIMELOCK)).getMinDelay() == OPERATING_DELAY, "operating timelock delay changed");
        console.log("  [OK] removed roles have no holders; kept roles, owners and delays unchanged");
    }

    function _assertModules(Snapshot memory before) internal view {
        EtherFiDataProvider dp = EtherFiDataProvider(DATA_PROVIDER);
        LendGateway gw = LendGateway(LEND_GATEWAY);
        address[] memory whitelisted = dp.getWhitelistedModules();
        address[] memory defaults = dp.getDefaultModules();
        address[] memory requesters = ICashModule(CASH_MODULE).getWhitelistedModulesCanRequestWithdraw();

        uint256 reqRemoved;
        for (uint256 k = 0; k < N; ++k) {
            require(!dp.isWhitelistedModule(OLD[k]), string.concat("old module still whitelisted: ", NAMES[k]));
            require(!dp.isDefaultModule(OLD[k]), string.concat("old module still default: ", NAMES[k]));
            require(!_contains(requesters, OLD[k]), string.concat("old module still a requester: ", NAMES[k]));
            require(!gw.isDriver(OLD[k]), string.concat("old module still a driver: ", NAMES[k]));
            if (IS_REQUESTER[k]) ++reqRemoved;

            // replacements untouched
            require(dp.isWhitelistedModule(NEW[k]) && dp.isDefaultModule(NEW[k]), string.concat("replacement lost whitelist/default: ", NAMES[k]));
            require(_contains(requesters, NEW[k]) == IS_REQUESTER[k], string.concat("replacement requester flag changed: ", NAMES[k]));
            require(gw.isDriver(NEW[k]) == IS_DRIVER[k], string.concat("replacement driver flag changed: ", NAMES[k]));
        }

        // Nothing else moved: each list lost exactly the retired modules and kept every other entry
        require(whitelisted.length == before.whitelisted.length - N, "whitelist length: expected exactly the five removed");
        require(defaults.length == before.defaults.length - N, "default list length: expected exactly the five removed");
        require(requesters.length == before.requesters.length - reqRemoved, "requester list length: expected only the retired requesters removed");
        _requireKept(before.whitelisted, whitelisted, "whitelist");
        _requireKept(before.defaults, defaults, "default list");
        _requireKept(before.requesters, requesters, "requesters");

        address[] memory others = _otherDriverCandidates();
        for (uint256 i = 0; i < others.length; ++i) {
            require(gw.isDriver(others[i]) == before.otherDrivers[i], "a non-retired driver changed");
        }

        // CashModule, LendGateway and the data provider are still live
        require(dp.isDefaultModule(CASH_MODULE) && dp.isDefaultModule(LEND_GATEWAY), "CashModule/LendGateway lost default status");
        console.log("  [OK] old modules gone; replacements and every other module unchanged");
    }

    /// @dev Every entry of `before` that is not one of the retired modules is still in `after`
    function _requireKept(address[] memory before, address[] memory after_, string memory what) internal view {
        for (uint256 i = 0; i < before.length; ++i) {
            if (_isOld(before[i])) continue;
            require(_contains(after_, before[i]), string.concat("entry lost from ", what));
        }
    }

    function _isOld(address a) internal view returns (bool) {
        for (uint256 k = 0; k < N; ++k) if (OLD[k] == a) return true;
        return false;
    }

    function _contains(address[] memory list, address needle) internal pure returns (bool) {
        for (uint256 i = 0; i < list.length; ++i) if (list[i] == needle) return true;
        return false;
    }
}
