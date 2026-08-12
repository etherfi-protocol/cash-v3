// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/// @dev Minimal view of the deployed StockWithdrawModule. Declared locally, ON PURPOSE: this
///      script is cut from master, where `src/stock-withdraw/**` does not exist yet (it ships on
///      the unmerged stock-withdraw branch). Importing the real contract would make 3CP-641
///      un-cherry-pickable onto master.
interface IStockWithdrawModule {
    function STOCK_WITHDRAW_MODULE_ADMIN_ROLE() external view returns (bytes32);
    function etherFiDataProvider() external view returns (address);
    function getProviderFee() external view returns (uint16 providerFeeBps, address feeReceiver);
    function getLzGasLimits() external view returns (uint128 lzReceiveGasLimit, uint128 composeGasLimit);
    function setProviderFee(uint16 providerFeeBps, address feeReceiver) external;
    function setLzGasLimits(uint128 lzReceiveGasLimit, uint128 composeGasLimit) external;
}

/**
 * @title StockWithdrawGrantAndTopUpDrawdownOP3CP
 * @author ether.fi
 * @notice 3CP-641 — queues BOTH owner-gated OP operations as ONE atomic timelock batch, as two
 *         3CP bundles signed 8h apart, then simulates the whole lifecycle on the current fork.
 *
 *         Supersedes the standalone TopUpDest drawdown that was originally 3CP-640: that number
 *         now belongs to EnableStockWithdrawModuleOP3CP (the non-timelock module enable, which
 *         ships on the stock-withdraw branch), and the drawdown moved here, batched with the
 *         admin-role grant. Sign 640 first.
 *
 *         The seven calls the TIMELOCK runs, in order:
 *           0. RoleRegistry.grantRole(STOCK_WITHDRAW_MODULE_ADMIN_ROLE, SAFE)
 *           1. TopUpDest.withdraw(USDT,   400,000e6)
 *           2. TopUpDest.withdraw(USDC,   100,000e6)
 *           3. TopUpDest.withdraw(beHYPE, 829e18)
 *           4. USDT.transfer(opsWallet,   400,000e6)
 *           5. USDC.transfer(opsWallet,   100,000e6)
 *           6. beHYPE.transfer(opsWallet, 829e18)
 *
 *         Step 1 (Safe, 1 tx): timelock.scheduleBatch(all seven, 8h)
 *         Step 2 (Safe, 1 tx, >= 8h after step 1 EXECUTES): timelock.executeBatch(all seven)
 *
 * @dev SELF-CONTAINED BY DESIGN: it ships alongside the stock-withdraw work but deliberately
 *      does not depend on it — no StockWithdrawConfig, no StockWithdrawModule import, and no
 *      reliance on a `.addresses.StockWithdrawModule` entry (master's deployments.json has
 *      none). So this file can be cherry-picked onto master and run on its own if the drawdown
 *      needs to go out before the stock-withdraw branch merges. The module address is instead
 *      PINNED as a constant below and cross-checked on-chain at run time, the same way
 *      RemoveOldLendModulesOP3CP pins the addresses it retires.
 *
 * @dev WHY THE TRANSFERS ARE PART OF THE BATCH: `TopUpDest.withdraw` takes no recipient — it
 *      always pays `msg.sender` — and it is `onlyRoleRegistryOwner`, which post-handover is the
 *      TIMELOCK. So the withdrawals land in the timelock itself, and calls 4-6 sweep them out
 *      from the timelock's own context. All seven run inside one `executeBatch`, so the funds
 *      never rest anywhere between calls. Scheduling the withdrawals WITHOUT the paired
 *      transfers would strand the capital in the timelock behind another 8h round-trip.
 *
 * @dev ATOMICITY, EXPLICITLY: this is ONE timelock operation. A revert in any leg reverts the
 *      whole batch, including the role grant, and the operation cannot be partially cancelled —
 *      cancelling drops the role grant too. This was chosen deliberately over two independent
 *      operations sharing the same two Safe transactions. The `deposits[]` ceiling and the live
 *      balances are re-asserted below precisely because a treasury leg reverting at execute
 *      time would also cost the grant.
 *
 * @dev SALT: TL_SALT is deliberately NON-ZERO. TimelockController marks an operation id as
 *      `isOperation` forever once scheduled, so a bytes32(0)-salted batch could never be
 *      re-scheduled — a real constraint for a treasury drawdown that may recur with identical
 *      amounts and recipient. Both steps derive it from this one constant, so they cannot
 *      drift; changing it between signing step 1 and step 2 makes step 2 revert.
 *
 * @dev `TopUpDest.deposits[]` IS A WITHDRAWAL CEILING, NOT A BALANCE — `topUpUserSafe` moves
 *      tokens out without decrementing it, so it drifts ABOVE the real balance for active
 *      tokens and can sit BELOW it for idle ones. Both bounds are therefore asserted per token.
 *
 * Usage (no broadcast — writes ./output/*.json and simulates):
 *   forge script scripts/gnosis-txs/StockWithdrawGrantAndTopUpDrawdownOP3CP.s.sol --rpc-url $OPTIMISM_RPC
 */
contract StockWithdrawGrantAndTopUpDrawdownOP3CP is Utils, GnosisHelpers {
    using stdJson for string;

    /// @notice Cash governance multisig (the 3CP Safe) — proposer/executor on the timelock.
    address constant SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    /// @dev EtherFiTimelock at its deterministic CREATE3 address (DeployTimelock.s.sol).
    address constant ETHERFI_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;
    uint256 constant TIMELOCK_DELAY = 8 hours;
    bytes32 constant TL_PREDECESSOR = bytes32(0);
    /// @dev See the SALT note above — must NOT be bytes32(0).
    bytes32 constant TL_SALT = keccak256("3CP-641.StockWithdrawGrant+TopUpDrawdown.OP");

    /// @notice The deployed prod StockWithdrawModule proxy on OP. Pinned rather than read from
    ///         deployments.json because master's copy has no such entry. Deployed via
    ///         CREATE3 salt "Prod.StockWithdraw.StockWithdrawModuleProxy"; every property that
    ///         matters is re-derived on-chain in `_checkModule`.
    address constant STOCK_WITHDRAW_MODULE = 0x62A737Df43f53449FeF9f1deE55CD925DB5C5012;

    /// @notice Ops wallet receiving the drawn-down top-up capital.
    address constant OPS_WALLET = 0x86fBaEB3D6b5247F420590D303a6ffC9cd523790;

    uint256 constant USDT_AMOUNT = 400_000e6;
    uint256 constant USDC_AMOUNT = 100_000e6;
    /// @dev TopUpDest holds ~834.35 beHYPE but `withdraw` is capped at deposits[beHYPE] = 829e18,
    ///      so 829 is both the round number and the maximum withdrawable. The ~5.35 remainder is
    ///      only reachable after a further `deposit()` bumps the accounting back up.
    uint256 constant BEHYPE_AMOUNT = 829e18;

    uint256 constant CALL_COUNT = 7;

    /// @dev UpgradeableProxy ERC-7201 slot; first member is the roleRegistry address.
    bytes32 constant UPGRADEABLE_PROXY_STORAGE_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;

    RoleRegistry internal roleRegistry;
    EtherFiTimelock internal timelockController;
    TopUpDest internal topUpDest;
    IStockWithdrawModule internal module;
    address internal dataProvider;
    bytes32 internal adminRole;

    address[3] internal tokens;
    uint256[3] internal amounts;
    string[3] internal tokenNames;

    function run() public {
        require(block.chainid == 10, "StockWithdrawGrantAndTopUpDrawdown: Optimism only");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        _loadAddresses();
        _checkPreconditions();

        (string memory step1Path, string memory step2Path) = _writeBundles();
        _simulateAndVerify(step1Path, step2Path);
    }

    // ── Address loading ───────────────────────────────────────────────────────────

    function _loadAddresses() internal {
        string memory deployments = readDeploymentFile();
        string memory fixtures = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/fixtures/fixtures.json"));
        string memory chainId = vm.toString(block.chainid);

        roleRegistry = RoleRegistry(deployments.readAddress(".addresses.RoleRegistry"));
        dataProvider = deployments.readAddress(".addresses.EtherFiDataProvider");
        topUpDest = TopUpDest(payable(deployments.readAddress(".addresses.TopUpDest")));
        timelockController = EtherFiTimelock(payable(ETHERFI_TIMELOCK));
        module = IStockWithdrawModule(STOCK_WITHDRAW_MODULE);

        adminRole = module.STOCK_WITHDRAW_MODULE_ADMIN_ROLE();

        tokens[0] = fixtures.readAddress(string.concat(".", chainId, ".usdt"));
        tokens[1] = fixtures.readAddress(string.concat(".", chainId, ".usdc"));
        tokens[2] = fixtures.readAddress(string.concat(".", chainId, ".beHYPE"));
        amounts[0] = USDT_AMOUNT;
        amounts[1] = USDC_AMOUNT;
        amounts[2] = BEHYPE_AMOUNT;
        tokenNames[0] = "USDT";
        tokenNames[1] = "USDC";
        tokenNames[2] = "beHYPE";
    }

    // ── Preconditions ─────────────────────────────────────────────────────────────

    function _checkPreconditions() internal view {
        _checkModule();
        _checkDrawdown();
        _checkTimelock();
    }

    /// @dev The module address is a hardcoded constant, so it gets the full treatment: the role
    ///      it reports must be the one this batch grants, its stored registry and immutable
    ///      DataProvider must be ours (hijack detection), and the role must not already be held.
    function _checkModule() internal view {
        require(STOCK_WITHDRAW_MODULE.code.length > 0, "pinned StockWithdrawModule has no code");
        require(adminRole == keccak256("STOCK_WITHDRAW_MODULE_ADMIN_ROLE"), "pinned module reports an unexpected admin role - wrong address?");
        require(module.etherFiDataProvider() == dataProvider, "module is bound to a different EtherFiDataProvider");

        address storedRegistry = address(uint160(uint256(vm.load(STOCK_WITHDRAW_MODULE, UPGRADEABLE_PROXY_STORAGE_SLOT))));
        require(storedRegistry == address(roleRegistry), "module roleRegistry mismatch - possible hijack");

        require(!roleRegistry.hasRole(adminRole, SAFE), "Safe already holds STOCK_WITHDRAW_MODULE_ADMIN_ROLE");
    }

    /// @dev Both of `withdraw`'s constraints, per token: the deposits[] ceiling AND the real
    ///      balance. Either one failing at execute time reverts the whole batch, grant included.
    function _checkDrawdown() internal view {
        require(address(topUpDest).code.length > 0, "TopUpDest has no code");
        require(OPS_WALLET != address(0), "ops wallet is the zero address");

        for (uint256 i = 0; i < 3; i++) {
            require(tokens[i] != address(0), "token address missing from fixtures.json");
            require(amounts[i] > 0, "drawdown amount is zero");
            require(topUpDest.getDeposit(tokens[i]) >= amounts[i], "amount exceeds TopUpDest deposits accounting");
            require(IERC20(tokens[i]).balanceOf(address(topUpDest)) >= amounts[i], "amount exceeds TopUpDest balance");
        }
        require(tokens[0] != tokens[1] && tokens[1] != tokens[2] && tokens[0] != tokens[2], "duplicate token in the drawdown set");
    }

    /// @dev Bytecode alone does not prove configuration — the delay and the proposer/executor
    ///      roles live in storage, so re-assert the full expected config before routing a
    ///      privileged payload through this address.
    function _checkTimelock() internal view {
        require(ETHERFI_TIMELOCK.code.length > 0, "EtherFiTimelock not deployed");
        require(keccak256(ETHERFI_TIMELOCK.code) == keccak256(type(EtherFiTimelock).runtimeCode), "timelock bytecode != local EtherFiTimelock build");
        require(timelockController.getMinDelay() == TIMELOCK_DELAY, "timelock minDelay != 8 hours");
        require(timelockController.hasRole(timelockController.PROPOSER_ROLE(), SAFE), "Safe is not a timelock proposer - cannot sign step 1");
        require(
            timelockController.hasRole(timelockController.EXECUTOR_ROLE(), SAFE) || timelockController.hasRole(timelockController.EXECUTOR_ROLE(), address(0)),
            "Safe is not a timelock executor - cannot sign step 2"
        );
        require(TL_SALT != bytes32(0), "TL_SALT must be non-zero so the batch can be re-scheduled later");

        // Every owner-gated leg here is executed BY the timelock, so it must actually be the
        // owner. Unlike the pre-handover era there is no fallback: if this is still the Safe,
        // the batch cannot work and must not be signed.
        require(roleRegistry.owner() == ETHERFI_TIMELOCK, "RoleRegistry owner is not the timelock - handover not done");
    }

    // ── Batch construction ────────────────────────────────────────────────────────

    /// @dev The batch, built once and reused by scheduleBatch, executeBatch and the operation-id
    ///      computation — all three must be byte-identical or executeBatch reverts.
    function _batch() internal view returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads) {
        targets = new address[](CALL_COUNT);
        values = new uint256[](CALL_COUNT);
        payloads = new bytes[](CALL_COUNT);

        targets[0] = address(roleRegistry);
        payloads[0] = abi.encodeWithSignature("grantRole(bytes32,address)", adminRole, SAFE);

        for (uint256 i = 0; i < 3; i++) {
            // withdraw into the timelock...
            targets[1 + i] = address(topUpDest);
            payloads[1 + i] = abi.encodeWithSelector(TopUpDest.withdraw.selector, tokens[i], amounts[i]);
            // ...then sweep out of it, same batch.
            targets[4 + i] = tokens[i];
            payloads[4 + i] = abi.encodeWithSelector(IERC20.transfer.selector, OPS_WALLET, amounts[i]);
        }
    }

    function _operationId() internal view returns (bytes32) {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _batch();
        return timelockController.hashOperationBatch(targets, values, payloads, TL_PREDECESSOR, TL_SALT);
    }

    function _writeBundles() internal returns (string memory step1Path, string memory step2Path) {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _batch();

        string memory scheduleData = iToHex(abi.encodeWithSignature("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)", targets, values, payloads, TL_PREDECESSOR, TL_SALT, TIMELOCK_DELAY));
        string memory step1 = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
        step1 = string.concat(step1, _getGnosisTransaction(addressToHex(ETHERFI_TIMELOCK), scheduleData, "0", true));
        step1Path = _writeBundle("step1-schedule", step1);

        string memory executeData = iToHex(abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", targets, values, payloads, TL_PREDECESSOR, TL_SALT));
        string memory step2 = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
        step2 = string.concat(step2, _getGnosisTransaction(addressToHex(ETHERFI_TIMELOCK), executeData, "0", true));
        step2Path = _writeBundle("step2-execute", step2);
    }

    function _writeBundle(string memory step, string memory txs) internal returns (string memory path) {
        vm.createDir("./output", true);
        path = string.concat("./output/3CP-641-StockWithdrawGrantAndTopUpDrawdown-op-", vm.toString(block.chainid), "-", step, ".json");
        vm.writeFile(path, txs);
        console.log("Wrote", path);
    }

    // ── Fork simulation ───────────────────────────────────────────────────────────

    function _simulateAndVerify(string memory step1Path, string memory step2Path) internal {
        _logDrawdownState();

        uint256[3] memory opsBefore;
        uint256[3] memory destBefore;
        uint256[3] memory capBefore;
        for (uint256 i = 0; i < 3; i++) {
            opsBefore[i] = IERC20(tokens[i]).balanceOf(OPS_WALLET);
            destBefore[i] = IERC20(tokens[i]).balanceOf(address(topUpDest));
            capBefore[i] = topUpDest.getDeposit(tokens[i]);
        }

        console.log("");
        console.log("=== Simulating step 1 (scheduleBatch) ===");
        executeGnosisTransactionBundle(step1Path);

        bytes32 opId = _operationId();
        require(timelockController.isOperationPending(opId), "SIM FAILED: batch not pending after schedule");
        require(!timelockController.isOperationReady(opId), "SIM FAILED: batch ready before the delay elapsed");
        require(!roleRegistry.hasRole(adminRole, SAFE), "SIM FAILED: role granted by step 1 - the delay did nothing");
        for (uint256 i = 0; i < 3; i++) {
            require(IERC20(tokens[i]).balanceOf(address(topUpDest)) == destBefore[i], "SIM FAILED: step 1 moved funds");
        }

        console.log("=== Warping past the 8-hour timelock delay ===");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        require(timelockController.isOperationReady(opId), "SIM FAILED: batch not ready after the delay");

        console.log("=== Simulating step 2 (executeBatch) ===");
        address ownerBefore = roleRegistry.owner();
        executeGnosisTransactionBundle(step2Path);

        _assertEndState(opId, ownerBefore, opsBefore, destBefore, capBefore);
    }

    function _logDrawdownState() internal view {
        console.log("");
        console.log("TopUpDest drawdown (balance / deposits-ceiling / withdrawing):");
        for (uint256 i = 0; i < 3; i++) {
            console.log(string.concat("  ", tokenNames[i]), IERC20(tokens[i]).balanceOf(address(topUpDest)), topUpDest.getDeposit(tokens[i]), amounts[i]);
        }
    }

    function _assertEndState(bytes32 opId, address ownerBefore, uint256[3] memory opsBefore, uint256[3] memory destBefore, uint256[3] memory capBefore) internal {
        require(timelockController.isOperationDone(opId), "SIM FAILED: timelock batch not done");

        // ── Leg A: the role grant ──
        require(roleRegistry.hasRole(adminRole, SAFE), "SIM FAILED: Safe did not receive STOCK_WITHDRAW_MODULE_ADMIN_ROLE");
        // Hash equality is not proof: drive real admin setters as the Safe, using current values
        // so the calls are no-ops on config.
        (uint16 feeBps, address feeReceiver) = module.getProviderFee();
        vm.prank(SAFE);
        module.setProviderFee(feeBps, feeReceiver);
        (uint128 lzReceiveGas, uint128 composeGas) = module.getLzGasLimits();
        vm.prank(SAFE);
        module.setLzGasLimits(lzReceiveGas, composeGas);

        // ── Leg B: the drawdown ──
        for (uint256 i = 0; i < 3; i++) {
            require(IERC20(tokens[i]).balanceOf(OPS_WALLET) - opsBefore[i] == amounts[i], "SIM FAILED: ops wallet did not receive the exact amount");
            require(destBefore[i] - IERC20(tokens[i]).balanceOf(address(topUpDest)) == amounts[i], "SIM FAILED: TopUpDest did not decrease by the exact amount");
            require(capBefore[i] - topUpDest.getDeposit(tokens[i]) == amounts[i], "SIM FAILED: deposits accounting did not decrease by the exact amount");
            // The pass-through must leave nothing behind — stranded funds would need another
            // 8h round-trip to recover.
            require(IERC20(tokens[i]).balanceOf(ETHERFI_TIMELOCK) == 0, "SIM FAILED: funds stranded in the timelock");
        }

        // ── Collateral damage ──
        require(roleRegistry.owner() == ownerBefore, "SIM FAILED: RoleRegistry owner changed");
        require(roleRegistry.owner() == ETHERFI_TIMELOCK, "SIM FAILED: RoleRegistry owner is not the timelock");

        console.log("");
        console.log("  [OK] STOCK_WITHDRAW_MODULE_ADMIN_ROLE held by the Safe:", SAFE);
        console.log("  [OK] admin setters callable by the Safe (setProviderFee + setLzGasLimits verified)");
        console.log("  [OK] drawdown delivered in full to the ops wallet:", OPS_WALLET);
        console.log("  [OK] nothing stranded in the timelock");
        console.log("");
        console.log("3CP-641 simulation passed. Sign step 1, wait for it to EXECUTE, then wait 8h before step 2.");
    }
}
