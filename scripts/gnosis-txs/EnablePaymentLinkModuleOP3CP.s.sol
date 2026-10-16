// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { PaymentLinkModule } from "../../src/payment-link/PaymentLinkModule.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { PaymentLinkConfig } from "../payment-link/PaymentLinkConfig.sol";
import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";

/**
 * @title EnablePaymentLinkModuleOP3CP
 * @author ether.fi
 * @notice Builds the Safe bundles that turn the deployed prod PaymentLinkModule on, then
 *         simulates them on the current fork and asserts the end state. Nothing is broadcast.
 *
 *         All three calls are gated by ADMIN_TIMELOCK_ROLE, which on Optimism is held ONLY by
 *         the 8h operating timelock (the Safe does not hold it), so they ship as one timelock
 *         batch in two Safe bundles:
 *
 *           Step 1 (day 0): Safe -> OPERATING_TIMELOCK.scheduleBatch(...)
 *           Step 2 (>= 8h): Safe -> OPERATING_TIMELOCK.executeBatch(...)
 *
 *           EtherFiDataProvider.configureModules([module], [true])           whitelist only, NOT default
 *           CashModule.configureModulesCanRequestWithdraw([module], [true])  needs the whitelist first
 *           PaymentLinkModule.setFee(LAUNCH_FEE_BPS, PROD_FEE_RECEIVER)
 *
 *         Whitelist-only (spec §2 DEFAULT): the module is never enabled on safes, so it has no
 *         `execTransactionFromModule` authority; it only receives CashModule withdrawals.
 *
 *         Going live is safe without an admin-role grant: `pause()` is PAUSER-gated and the Safe
 *         holds PAUSER/UNPAUSER (asserted and exercised below), and `cancel` stays open while
 *         paused, so senders can always recover funds.
 *
 * Prerequisite: the prod module is deployed (DeployPaymentLinkModule.s.sol, ENV=mainnet) and
 * VerifyPaymentLinkModule passes with PAYMENT_LINK_VERIFY_DEPLOY_ONLY=true. If
 * `.addresses.PaymentLinkModule` is recorded in deployments/mainnet/10/deployments.json it must
 * equal the pinned prod proxy.
 *
 * Usage (no broadcast; writes ./output/*.json and simulates both steps on the fork):
 *   forge script scripts/gnosis-txs/EnablePaymentLinkModuleOP3CP.s.sol --rpc-url $OPTIMISM_RPC --sender 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E --no-isolate -vvv
 *   (--sender: the default script sender cannot `new` on this fork; nothing is sent. --no-isolate:
 *   the simulation pranks the Safe, which forge 1.8 rejects as an isolated top-level sender.)
 */
contract EnablePaymentLinkModuleOP3CP is PaymentLinkConfig, GnosisHelpers, ContractCodeChecker {
    using stdJson for string;

    bytes32 internal constant TL_PREDECESSOR = bytes32(0);
    /// @dev Specific to this batch so the operation id is unique; TimelockController keeps an id
    ///      `isOperation` forever, so a reused salt could never be scheduled again.
    bytes32 internal constant TL_SALT = keccak256("PaymentLink.EnablePaymentLinkModuleOP3CP.v1");

    Stack internal s;
    PaymentLinkModule internal module;

    address[] internal targets;
    bytes[] internal payloads;

    /// @notice Paths of the bundles written by the last `run()`.
    string public step1Path;
    string public step2Path;

    function run() public {
        require(block.chainid == OPTIMISM_CHAIN_ID, "EnablePaymentLinkModule: Optimism only");
        require(isEqualString(_env(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        _load();
        _checkPreconditions();
        _buildBatch();

        string memory header = _getGnosisHeader(vm.toString(block.chainid), addressToHex(PROD_SAFE));
        step1Path = _writeBundle("step1-schedule", string.concat(header, _scheduleTx(true)));
        step2Path = _writeBundle("step2-execute", string.concat(header, _executeTx(true)));

        _simulate();
    }

    // ── Address loading ───────────────────────────────────────────────────────────

    function _load() internal {
        s = _stack("mainnet");
        module = PaymentLinkModule(EXPECTED_PROD_MODULE_PROXY);

        string memory deployments = _prodDeployments();
        if (vm.keyExistsJson(deployments, ".addresses.PaymentLinkModule")) {
            require(deployments.readAddress(".addresses.PaymentLinkModule") == EXPECTED_PROD_MODULE_PROXY, "deployments.json PaymentLinkModule != pinned Prod.PaymentLink proxy");
        }
    }

    function _prodDeployments() internal view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet/10/deployments.json"));
    }

    // ── Preconditions ─────────────────────────────────────────────────────────────

    function _checkPreconditions() internal {
        // The module is the PROD one, built from this repo against the prod stack.
        _assertPinnedAddresses();
        _assertStack(s);
        address impl = EXPECTED_PROD_MODULE_IMPL;
        require(address(module).code.length > 0, "PaymentLinkModule proxy has no code - deploy it first");
        require(_implOf(address(module)) == impl, "proxy impl slot != Prod.PaymentLink impl - possible hijack");
        require(_registryOf(address(module)) == address(s.roleRegistry), "proxy roleRegistry != prod RoleRegistry - possible hijack");
        require(address(module.etherFiDataProvider()) == address(s.dataProvider), "module bound to a different DataProvider");
        require(address(module.cashModule()) == address(s.cashModule), "module bound to a different CashModule");
        requireCodeMatchAllowingAddressEmbeds("PaymentLinkModuleImpl", impl, address(new PaymentLinkModule(address(s.dataProvider), address(s.cashModule))));

        // Deploy-time state, so the bundle is not already applied (idempotence).
        (uint16 feeBps, address feeReceiver) = module.getFee();
        require(feeBps == DEPLOY_FEE_BPS && feeReceiver == DEPLOY_FEE_RECEIVER, "module fee already configured - enable already done?");
        require(!s.dataProvider.isWhitelistedModule(address(module)), "module already whitelisted - enable already done?");
        require(!_canRequestWithdraw(s.cashModule, address(module)), "module already allowed to request withdrawals");
        require(!module.paused(), "module is paused");

        // Launch config is valid for setFee.
        require(LAUNCH_FEE_BPS <= module.MAX_FEE_BPS(), "launch fee above MAX_FEE_BPS");
        require(PROD_FEE_RECEIVER != address(0), "launch fee needs a receiver");

        // Governance: ADMIN_TIMELOCK_ROLE sits with the 8h operating timelock, the Safe proposes and executes.
        require(s.roleRegistry.owner() == UPGRADE_TIMELOCK, "RoleRegistry owner is not the upgrade timelock");
        require(s.roleRegistry.hasRole(keccak256("ADMIN_TIMELOCK_ROLE"), OPERATING_TIMELOCK), "operating timelock lacks ADMIN_TIMELOCK_ROLE");
        EtherFiTimelock tl = EtherFiTimelock(payable(OPERATING_TIMELOCK));
        require(keccak256(OPERATING_TIMELOCK.code) == keccak256(type(EtherFiTimelock).runtimeCode), "operating timelock bytecode != local EtherFiTimelock build");
        require(tl.getMinDelay() == OPERATING_TIMELOCK_DELAY, "operating timelock minDelay mismatch");
        require(tl.hasRole(tl.PROPOSER_ROLE(), PROD_SAFE), "Safe is not a proposer on the operating timelock");
        require(tl.hasRole(tl.EXECUTOR_ROLE(), PROD_SAFE) || tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "Safe is not an executor on the operating timelock");

        // Emergency stop is available from the moment the module goes live.
        require(s.roleRegistry.hasRole(s.roleRegistry.PAUSER(), PROD_SAFE), "Safe lacks PAUSER - do not enable without an emergency stop");
        require(s.roleRegistry.hasRole(s.roleRegistry.UNPAUSER(), PROD_SAFE), "Safe lacks UNPAUSER");
    }

    // ── Bundle construction ───────────────────────────────────────────────────────

    function _buildBatch() internal {
        address[] memory modules = new address[](1);
        modules[0] = address(module);
        bool[] memory enable = new bool[](1);
        enable[0] = true;

        // Order matters: CashModule refuses a requester the DataProvider has not whitelisted.
        targets.push(address(s.dataProvider));
        payloads.push(abi.encodeCall(EtherFiDataProvider.configureModules, (modules, enable)));
        targets.push(address(s.cashModule));
        payloads.push(abi.encodeCall(ICashModule.configureModulesCanRequestWithdraw, (modules, enable)));
        targets.push(address(module));
        payloads.push(abi.encodeCall(PaymentLinkModule.setFee, (LAUNCH_FEE_BPS, PROD_FEE_RECEIVER)));

        require(!_isOperation(), "enable batch already scheduled");
    }

    function _scheduleTx(bool isLast) internal view returns (string memory) {
        bytes memory data = abi.encodeWithSignature("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)", targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, TL_SALT, OPERATING_TIMELOCK_DELAY);
        return _getGnosisTransaction(addressToHex(OPERATING_TIMELOCK), iToHex(data), "0", isLast);
    }

    function _executeTx(bool isLast) internal view returns (string memory) {
        bytes memory data = abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, TL_SALT);
        return _getGnosisTransaction(addressToHex(OPERATING_TIMELOCK), iToHex(data), "0", isLast);
    }

    function _writeBundle(string memory step, string memory txs) internal returns (string memory path) {
        vm.createDir("./output", true);
        path = string.concat("./output/EnablePaymentLinkModuleOP3CP-10-", step, ".json");
        vm.writeFile(path, txs);
        console.log("Wrote", path);
    }

    function _isOperation() internal view returns (bool) {
        EtherFiTimelock tl = EtherFiTimelock(payable(OPERATING_TIMELOCK));
        return tl.isOperation(tl.hashOperationBatch(targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, TL_SALT));
    }

    // ── Fork simulation ───────────────────────────────────────────────────────────

    function _simulate() internal {
        address ownerBefore = s.roleRegistry.owner();
        address lendGateway = _prodDeployments().readAddress(".addresses.LendGateway");

        console.log("");
        console.log("=== Step 1: schedule the enable batch on the 8h operating timelock ===");
        executeGnosisTransactionBundle(step1Path);
        require(_isOperation(), "SIM FAILED: batch not scheduled");
        require(!s.dataProvider.isWhitelistedModule(address(module)), "SIM FAILED: nothing may apply before execute");

        console.log("=== Warp 8h, step 2: execute ===");
        vm.warp(block.timestamp + OPERATING_TIMELOCK_DELAY + 1);
        executeGnosisTransactionBundle(step2Path);

        require(s.dataProvider.isWhitelistedModule(address(module)), "SIM FAILED: module not whitelisted");
        require(!s.dataProvider.isDefaultModule(address(module)), "SIM FAILED: module must not be a default module");
        require(_canRequestWithdraw(s.cashModule, address(module)), "SIM FAILED: module cannot request withdrawals");
        (uint16 feeBps, address feeReceiver) = module.getFee();
        require(feeBps == LAUNCH_FEE_BPS && feeReceiver == PROD_FEE_RECEIVER, "SIM FAILED: fee not set");

        // The emergency stop must actually work on the now-live module, not merely be role-held.
        vm.prank(PROD_SAFE);
        module.pause();
        require(module.paused(), "SIM FAILED: pause did not take effect");
        vm.prank(PROD_SAFE);
        module.unpause();
        require(!module.paused(), "SIM FAILED: unpause did not take effect");

        // Collateral damage: the bundle must not touch the existing module set.
        if (lendGateway != address(0)) require(s.dataProvider.isDefaultModule(lendGateway), "SIM FAILED: LendGateway lost default status");

        // Must be the last check: a batch must never move RoleRegistry ownership.
        require(s.roleRegistry.owner() == ownerBefore, "SIM FAILED: CRITICAL: RoleRegistry owner changed");

        console.log("");
        console.log("  [OK] PaymentLinkModule enabled:", address(module));
        console.log("       whitelisted (not default) on EtherFiDataProvider");
        console.log("       can request withdrawals on CashModule");
        console.log("       fee bps:", feeBps);
        console.log("       fee receiver:", feeReceiver);
        console.log("  [OK] pause/unpause verified; RoleRegistry owner unchanged");
        console.log("EnablePaymentLinkModuleOP3CP simulation passed. Run VerifyPaymentLinkModule.s.sol after execution.");
    }
}
