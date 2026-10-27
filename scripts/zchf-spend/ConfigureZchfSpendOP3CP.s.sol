// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { BinSponsor, Cashback, ICashModule, Mode } from "../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { ZchfProd } from "../zchf/ZchfProdConfig.sol";

interface ILendGatewaySpendLike {
    function setSpendAsset(address asset, bool spendable) external;
    function isRegistered(address asset) external view returns (bool);
    function isSpendAsset(address asset) external view returns (bool);
    function reserveIdOf(address asset) external view returns (uint256);
    function spendAssets() external view returns (address[] memory);
}

interface IRoleRegistryOf {
    function roleRegistry() external view returns (address);
}

interface IAdminTimelock {
    function scheduleBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata payloads, bytes32 predecessor, bytes32 salt, uint256 delay) external;
    function executeBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata payloads, bytes32 predecessor, bytes32 salt) external payable;
    function hashOperationBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata payloads, bytes32 predecessor, bytes32 salt) external pure returns (bytes32);
    function getMinDelay() external view returns (uint256);
    function isOperation(bytes32 id) external view returns (bool);
    function isOperationDone(bytes32 id) external view returns (bool);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface ISettlementDispatcherLike {
    function setSettlementRecipients(address[] calldata tokens, address[] calldata recipients) external;
    function getSettlementRecipient(address token) external view returns (address);
    function settle(address token, uint256 amount) external;
}

/**
 * @title ConfigureZchfSpendOP3CP
 * @notice COR-1968: makes ZCHF (Frankencoin, 0xD4dD…5553 on Optimism) debit-spendable on the card, on
 *         both kinds of Cash safe, with a same-chain settlement route on every dispatcher. Swiss banking
 *         rail deposits arrive as ZCHF, which is already priced (PriceProviderV2, OracleSink CHF / USD),
 *         a DebtManager collateral and Summer Lend reserve 25 registered on the LendGateway.
 *
 *         Bundle 1 (Operating Safe nonce N): ADMIN_TIMELOCK.scheduleBatch, 8h, of
 *           setSettlementRecipients([ZCHF], [recipient]) on each dispatcher. The dispatchers only accept
 *           the admin timelock (ADMIN_TIMELOCK_ROLE). Recipients:
 *             Rain, Reap, Pix — 0x4358…79CB, the address EURC's bridge route delivers to (and Pix's live
 *                               USDT / USDT0 recipient), here on Optimism itself
 *             CardOrder       — the ops wallet, EURC's live recipient there
 *
 *         Bundle 2 (Operating Safe nonce N+1, >= 8h later), one MultiSend:
 *           1. ADMIN_TIMELOCK.executeBatch, byte-identical payload
 *           2. DebtManager.supportBorrowToken(ZCHF, 1, type(uint128).max)
 *                Legacy (not migrated) safes: CashLendLib._sourceLegacyDebits reverts UnsupportedToken
 *                unless debtManager.isBorrowToken(token). The config mirrors USDT / USDT0 exactly
 *                (borrowApy 1, minShares uint128 max): DebtManagerCore.supply cannot reach that share
 *                floor, so no ZCHF liquidity can be supplied and none can be borrowed. Spendable, not
 *                borrowable.
 *           3. LendGateway.setSpendAsset(ZCHF, true)
 *                Lend-gateway safes: CashLendLib._sourceDebitToken reverts UnsupportedToken unless
 *                gateway.isSpendAsset(token). Requires the asset to be registered (it is, reserve 25).
 *
 *         Spending opens in the same transaction that lands the recipients, so a ZCHF spend can never
 *         settle into a dispatcher with nowhere to send it.
 *
 *         Rehearsal: before the bundles, a 10 USD ZCHF debit spend reverts on a live legacy debit safe and
 *         a live lend-gateway debit safe; after them, the same spends move ZCHF into the Rain dispatcher,
 *         and settle() on every dispatcher delivers ZCHF to its recipient.
 *
 *         Not in these bundles: credit-mode spend in ZCHF, top-up rails.
 *
 * Usage:
 *   forge script scripts/zchf-spend/ConfigureZchfSpendOP3CP.s.sol --rpc-url $OPTIMISM_RPC
 */
contract ConfigureZchfSpendOP3CP is GnosisHelpers, Utils, Test {
    string constant SCHEDULE_PATH = "./output/ConfigureZchfSpendOP3CP-10-schedule.json";
    string constant EXECUTE_PATH = "./output/ConfigureZchfSpendOP3CP-10-execute-and-spend.json";

    address constant OPERATING_SAFE = ZchfProd.OPERATING_SAFE;
    /// @dev Operating (admin) timelock, 8h; the only ADMIN_TIMELOCK_ROLE holder. The Operating Safe is
    ///      proposer, executor and canceller (3CP-722 used the same route for card-order recipients)
    address constant ADMIN_TIMELOCK = 0x9AEb8eaa982084219d1A938D8F7B5040a1d47849;
    bytes32 constant PREDECESSOR = bytes32(0);
    bytes32 constant SALT = keccak256("ZchfDebitSpend.OP.SettlementRecipients.v1");

    address constant DISPATCHER_RAIN = 0x50A233C4a0Bb1d7124b0224880037d35767a501C;
    address constant DISPATCHER_REAP = 0x9623e86Df854FF3b48F7B4079a516a4F64861Db2;
    address constant DISPATCHER_PIX = 0x95aaddD43b6edF838ec486E9f9814787212Bf42D;
    address constant DISPATCHER_CARD_ORDER = 0xb14FDfd7D2cfFb6Cc6953C1b80F1B1d12c2F766a;
    /// @dev The destRecipient of EURC's bridge route on Rain / Reap / Pix (asserted below); a 1-of-3 Safe
    ///      on Optimism that already receives Pix's USDT and USDT0
    address constant CARD_SETTLEMENT_RECIPIENT = 0x4358f4940283E6357128941a5c508e5F314D79CB;
    /// @dev Ops wallet Safe: EURC's (and every other token's) card-order recipient
    address constant OPS_WALLET = 0x86fBaEB3D6b5247F420590D303a6ffC9cd523790;
    address constant EURC = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;
    /// @dev SETTLEMENT_DISPATCHER_BRIDGER_ROLE holder that calls settle() (the other one is the Operating Safe)
    address constant SETTLEMENT_BRIDGER = 0x23ddE38BA34e378D28c667bC26b44310c7CA0997;
    address constant ZCHF = ZchfProd.ZCHF_OP;
    /// @dev The template: USD₮0 was made debit-spendable on legacy safes the same way (COR-1753)
    address constant USDT0 = 0x01bFF41798a0BcF287b996046Ca68b395DbC1071;
    /// @dev ZCHF's Summer Lend reserve on the cash spoke, registered on the LendGateway (live 2026-10-21)
    uint256 constant ZCHF_RESERVE_ID = 25;

    uint64 constant BORROW_APY = 1;
    uint128 constant MIN_SHARES = type(uint128).max;

    // ---------------------------------------------------------------- fork rehearsal fixtures
    /// @dev Live Debit-mode safes that spent on 2026-10-21: one not migrated (DebtManager path), one
    ///      migrated to the LendGateway. Asserted below, so a changed safe fails loudly.
    address constant LEGACY_DEBIT_SAFE = 0x00620ECAB9cCCCf99CE13A593b096ff4fd0Aa88b;
    address constant LEND_DEBIT_SAFE = 0x00489FF9AEdc29Df85F3EBE63608cED67C525b76;
    /// @dev Live ETHER_FI_WALLET_ROLE holder that sends CashModule.spend
    address constant ETHER_FI_WALLET = 0xdC45DB93c3fC37272f40812bBa9C4Bad91344b46;
    uint256 constant SPEND_USD = 10e6;

    IDebtManager debtManager;
    ILendGatewaySpendLike gateway;
    ICashModule cashModule;
    PriceProviderV2 priceProvider;

    function run() public {
        require(block.chainid == 10, "must be Optimism");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        string memory deployments = readDeploymentFile();
        debtManager = IDebtManager(stdJson.readAddress(deployments, ".addresses.DebtManager"));
        cashModule = ICashModule(stdJson.readAddress(deployments, ".addresses.CashModule"));
        priceProvider = PriceProviderV2(stdJson.readAddress(deployments, ".addresses.PriceProvider"));
        gateway = ILendGatewaySpendLike(stdJson.readAddress(vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/cash-lend.json")), ".lendGateway"));

        _assertPreState();

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _recipientBatch();
        uint256 delay = IAdminTimelock(ADMIN_TIMELOCK).getMinDelay();
        bytes32 operationId = IAdminTimelock(ADMIN_TIMELOCK).hashOperationBatch(targets, values, payloads, PREDECESSOR, SALT);
        require(!IAdminTimelock(ADMIN_TIMELOCK).isOperation(operationId), "operation id already scheduled");
        console.log("ADMIN_TIMELOCK minDelay (s): %s", delay);
        console.log("salt / operation id:");
        console.logBytes32(SALT);
        console.logBytes32(operationId);

        vm.createDir("./output", true);
        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(OPERATING_SAFE));
        txs = _append(txs, ADMIN_TIMELOCK, abi.encodeCall(IAdminTimelock.scheduleBatch, (targets, values, payloads, PREDECESSOR, SALT, delay)), true);
        vm.writeFile(SCHEDULE_PATH, txs);
        console.log("Written: %s", SCHEDULE_PATH);

        txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(OPERATING_SAFE));
        txs = _append(txs, ADMIN_TIMELOCK, abi.encodeCall(IAdminTimelock.executeBatch, (targets, values, payloads, PREDECESSOR, SALT)), false);
        txs = _append(txs, address(debtManager), abi.encodeCall(IDebtManager.supportBorrowToken, (ZCHF, BORROW_APY, MIN_SHARES)), false);
        txs = _append(txs, address(gateway), abi.encodeCall(ILendGatewaySpendLike.setSpendAsset, (ZCHF, true)), true);
        vm.writeFile(EXECUTE_PATH, txs);
        console.log("Written: %s", EXECUTE_PATH);

        // ── fork rehearsal, in signing order ──────────────────────────────────────────────────────
        _assertSpendReverts(LEGACY_DEBIT_SAFE, "pre-legacy");
        _assertSpendReverts(LEND_DEBIT_SAFE, "pre-lend");
        _assertDirectRecipientCallReverts();

        executeGnosisTransactionBundle(SCHEDULE_PATH);
        assertTrue(IAdminTimelock(ADMIN_TIMELOCK).isOperation(operationId), "not scheduled");
        // the execute bundle cannot run early: the timelock leg reverts and takes the whole MultiSend with it
        vm.warp(block.timestamp + delay - 60);
        vm.prank(OPERATING_SAFE);
        (bool early,) = ADMIN_TIMELOCK.call(abi.encodeCall(IAdminTimelock.executeBatch, (targets, values, payloads, PREDECESSOR, SALT)));
        assertFalse(early, "executeBatch ran before the delay");
        vm.warp(block.timestamp + 61);
        executeGnosisTransactionBundle(EXECUTE_PATH);
        assertTrue(IAdminTimelock(ADMIN_TIMELOCK).isOperationDone(operationId), "operation not done");

        _assertPostState();
        _assertSpendSettles(LEGACY_DEBIT_SAFE, "post-legacy");
        _assertSpendSettles(LEND_DEBIT_SAFE, "post-lend");
        _assertSettlesToRecipients();
        console.log("Simulation passed: ZCHF debit-spends on legacy and lend-gateway safes, price %s (6 dec)", priceProvider.price(ZCHF));
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //                                  SETTLEMENT RECIPIENTS
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    /// @dev One setSettlementRecipients per dispatcher, so a signer reads one recipient per call
    function _recipientBatch() internal pure returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads) {
        (address[] memory dispatchers, address[] memory recipients) = _rails();
        targets = dispatchers;
        values = new uint256[](dispatchers.length);
        payloads = new bytes[](dispatchers.length);
        for (uint256 i; i < dispatchers.length; ++i) {
            address[] memory tokens = new address[](1);
            address[] memory to = new address[](1);
            tokens[0] = ZCHF;
            to[0] = recipients[i];
            payloads[i] = abi.encodeCall(ISettlementDispatcherLike.setSettlementRecipients, (tokens, to));
        }
    }

    function _rails() internal pure returns (address[] memory dispatchers, address[] memory recipients) {
        dispatchers = new address[](4);
        recipients = new address[](4);
        (dispatchers[0], recipients[0]) = (DISPATCHER_RAIN, CARD_SETTLEMENT_RECIPIENT);
        (dispatchers[1], recipients[1]) = (DISPATCHER_REAP, CARD_SETTLEMENT_RECIPIENT);
        (dispatchers[2], recipients[2]) = (DISPATCHER_PIX, CARD_SETTLEMENT_RECIPIENT);
        (dispatchers[3], recipients[3]) = (DISPATCHER_CARD_ORDER, OPS_WALLET);
    }

    /// @dev The dispatchers accept only the admin timelock: a direct Operating Safe call must revert
    function _assertDirectRecipientCallReverts() internal {
        (, , bytes[] memory payloads) = _recipientBatch();
        vm.prank(OPERATING_SAFE);
        (bool ok,) = DISPATCHER_RAIN.call(payloads[0]);
        assertFalse(ok, "Operating Safe can set recipients directly: the timelock leg is unnecessary");
    }

    /// @dev settle() on every dispatcher delivers ZCHF to its recipient, the path bridger uses
    function _assertSettlesToRecipients() internal {
        (address[] memory dispatchers, address[] memory recipients) = _rails();
        for (uint256 i; i < dispatchers.length; ++i) {
            deal(ZCHF, dispatchers[i], IERC20(ZCHF).balanceOf(dispatchers[i]) + 1e18);
            uint256 before = IERC20(ZCHF).balanceOf(recipients[i]);
            vm.prank(SETTLEMENT_BRIDGER);
            ISettlementDispatcherLike(dispatchers[i]).settle(ZCHF, 1e18);
            assertEq(IERC20(ZCHF).balanceOf(recipients[i]) - before, 1e18, "settle did not deliver ZCHF");
        }
        console.log("  [OK] settle(ZCHF) delivers to the recipient on Rain, Reap, Pix and CardOrder");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //                                     STATE ASSERTIONS
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    function _assertPreState() internal view {
        IRoleRegistry roleRegistry = IRoleRegistry(IRoleRegistryOf(address(debtManager)).roleRegistry());
        assertEq(IRoleRegistryOf(address(gateway)).roleRegistry(), address(roleRegistry), "gateway on a different RoleRegistry");
        assertTrue(roleRegistry.hasRole(roleRegistry.ADMIN_ROLE(), OPERATING_SAFE), "Operating Safe lacks ADMIN_ROLE");

        // ZCHF is priced and collateral already; this bundle only opens the spend gates
        assertGt(priceProvider.price(ZCHF), 0, "ZCHF not priced");
        assertTrue(debtManager.isCollateralToken(ZCHF), "ZCHF not a DebtManager collateral (supportBorrowToken would revert)");
        assertFalse(debtManager.isBorrowToken(ZCHF), "ZCHF already a DebtManager borrow token");
        assertTrue(gateway.isRegistered(ZCHF), "ZCHF not registered on the LendGateway");
        assertEq(gateway.reserveIdOf(ZCHF), ZCHF_RESERVE_ID, "ZCHF reserve id drifted");
        assertFalse(gateway.isSpendAsset(ZCHF), "ZCHF already a spend asset");

        // The template must still be "spendable, supply blocked": if USDT0's floor were ever lowered,
        // copying the shape would no longer mean "not borrowable"
        IDebtManager.BorrowTokenConfig memory usdt0 = debtManager.borrowTokenConfig(USDT0);
        assertEq(uint256(usdt0.borrowApy), uint256(BORROW_APY), "USDT0 borrowApy changed: re-review the template");
        assertEq(uint256(usdt0.minShares), uint256(MIN_SHARES), "USDT0 minShares changed: re-review the template");

        assertEq(uint8(cashModule.getMode(LEGACY_DEBIT_SAFE)), uint8(Mode.Debit), "legacy fixture not in Debit mode");
        assertFalse(debtManager.hasMigratedToLendGateway(LEGACY_DEBIT_SAFE), "legacy fixture has migrated");
        assertEq(uint8(cashModule.getMode(LEND_DEBIT_SAFE)), uint8(Mode.Debit), "lend fixture not in Debit mode");
        assertTrue(debtManager.hasMigratedToLendGateway(LEND_DEBIT_SAFE), "lend fixture has not migrated");

        // Recipients: none set for ZCHF yet, and the EURC values this mirrors are still live
        IAdminTimelock timelock = IAdminTimelock(ADMIN_TIMELOCK);
        assertTrue(roleRegistry.hasRole(keccak256("ADMIN_TIMELOCK_ROLE"), ADMIN_TIMELOCK), "admin timelock lacks ADMIN_TIMELOCK_ROLE");
        assertTrue(timelock.hasRole(keccak256("PROPOSER_ROLE"), OPERATING_SAFE), "Operating Safe not a proposer");
        assertTrue(timelock.hasRole(keccak256("EXECUTOR_ROLE"), OPERATING_SAFE), "Operating Safe not an executor");
        assertTrue(roleRegistry.hasRole(keccak256("SETTLEMENT_DISPATCHER_BRIDGER_ROLE"), SETTLEMENT_BRIDGER), "bridger fixture lacks its role");
        (address[] memory dispatchers,) = _rails();
        for (uint256 i; i < dispatchers.length; ++i) {
            assertEq(ISettlementDispatcherLike(dispatchers[i]).getSettlementRecipient(ZCHF), address(0), "ZCHF recipient already set");
            assertEq(IRoleRegistryOf(dispatchers[i]).roleRegistry(), address(roleRegistry), "dispatcher on a different RoleRegistry");
        }
        for (uint256 i; i < 3; ++i) {
            (bool ok, bytes memory ret) = dispatchers[i].staticcall(abi.encodeWithSignature("destinationData(address)", EURC));
            require(ok, "destinationData(EURC) failed");
            (, address destRecipient) = abi.decode(ret, (uint32, address));
            assertEq(destRecipient, CARD_SETTLEMENT_RECIPIENT, "EURC bridge recipient != 0x4358...79CB");
        }
        assertEq(ISettlementDispatcherLike(DISPATCHER_CARD_ORDER).getSettlementRecipient(EURC), OPS_WALLET, "EURC card-order recipient != ops wallet");
    }

    function _assertPostState() internal view {
        assertTrue(debtManager.isBorrowToken(ZCHF), "ZCHF not a borrow token");
        IDebtManager.BorrowTokenConfig memory c = debtManager.borrowTokenConfig(ZCHF);
        assertEq(uint256(c.borrowApy), uint256(BORROW_APY), "ZCHF borrowApy");
        assertEq(uint256(c.minShares), uint256(MIN_SHARES), "ZCHF minShares");
        assertEq(c.totalSharesOfBorrowTokens, 0, "ZCHF has supplied liquidity");
        assertEq(c.totalBorrowingAmount, 0, "ZCHF has borrows");
        assertTrue(debtManager.isCollateralToken(ZCHF), "ZCHF lost its collateral status");

        assertTrue(gateway.isSpendAsset(ZCHF), "ZCHF not a spend asset");
        assertEq(gateway.reserveIdOf(ZCHF), ZCHF_RESERVE_ID, "ZCHF reserve id");

        (address[] memory dispatchers, address[] memory recipients) = _rails();
        for (uint256 i; i < dispatchers.length; ++i) {
            assertEq(ISettlementDispatcherLike(dispatchers[i]).getSettlementRecipient(ZCHF), recipients[i], "ZCHF recipient");
        }
        assertEq(ISettlementDispatcherLike(DISPATCHER_CARD_ORDER).getSettlementRecipient(EURC), OPS_WALLET, "EURC card-order recipient changed");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //                                     SPEND REHEARSAL
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    function _assertSpendReverts(address safe, string memory tag) internal {
        deal(ZCHF, safe, IERC20(ZCHF).balanceOf(safe) + 100e18);
        (bool ok,) = _spend(safe, tag);
        assertFalse(ok, string.concat(tag, ": ZCHF spend succeeded before the bundle"));
    }

    function _assertSpendSettles(address safe, string memory tag) internal {
        address dispatcher = cashModule.getSettlementDispatcher(BinSponsor.Rain);
        uint256 safeBefore = IERC20(ZCHF).balanceOf(safe);
        uint256 dispatcherBefore = IERC20(ZCHF).balanceOf(dispatcher);

        (bool ok, bytes memory err) = _spend(safe, tag);
        if (!ok) {
            console.logBytes(err);
            revert(string.concat(tag, ": ZCHF spend reverted after the bundle"));
        }

        uint256 spent = safeBefore - IERC20(ZCHF).balanceOf(safe);
        assertGt(spent, 0, string.concat(tag, ": no ZCHF left the safe"));
        assertEq(IERC20(ZCHF).balanceOf(dispatcher) - dispatcherBefore, spent, string.concat(tag, ": dispatcher did not receive the ZCHF"));
        console.log("  [OK] %s: 10 USD spent as %s ZCHF wei", tag, spent);
    }

    function _spend(address safe, string memory tag) internal returns (bool ok, bytes memory err) {
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = ZCHF;
        amounts[0] = SPEND_USD;
        vm.prank(ETHER_FI_WALLET);
        (ok, err) = address(cashModule).call(abi.encodeCall(ICashModule.spend, (safe, keccak256(abi.encode("COR-1968", tag)), BinSponsor.Rain, tokens, amounts, new Cashback[](0))));
    }

    function _append(string memory txs, address to, bytes memory data, bool isLast) internal pure returns (string memory) {
        return string.concat(txs, _getGnosisTransaction(addressToHex(to), iToHex(data), "0", isLast));
    }
}
