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

/**
 * @title ConfigureZchfSpendOP3CP
 * @notice COR-1968: makes ZCHF (Frankencoin, 0xD4dD…5553 on Optimism) debit-spendable on the card, on
 *         both kinds of Cash safe. Swiss banking rail deposits arrive as ZCHF, which is already priced
 *         (PriceProviderV2, OracleSink CHF / USD), a DebtManager collateral and Summer Lend reserve 25
 *         registered on the LendGateway. What it lacks is the debit-spend gate:
 *
 *           1. DebtManager.supportBorrowToken(ZCHF, 1, type(uint128).max)
 *                Legacy (not migrated) safes: CashLendLib._sourceLegacyDebits reverts UnsupportedToken
 *                unless debtManager.isBorrowToken(token). The config mirrors USDT / USDT0 exactly
 *                (borrowApy 1, minShares uint128 max): DebtManagerCore.supply cannot reach that share
 *                floor, so no ZCHF liquidity can be supplied and none can be borrowed. Spendable, not
 *                borrowable.
 *           2. LendGateway.setSpendAsset(ZCHF, true)
 *                Lend-gateway safes: CashLendLib._sourceDebitToken reverts UnsupportedToken unless
 *                gateway.isSpendAsset(token). Requires the asset to be registered (it is, reserve 25).
 *
 *         Both calls are onlyAdmin (RoleRegistry ADMIN_ROLE), held by the Operating Safe; no timelock.
 *
 *         Rehearsal: before the bundle, a 10 USD ZCHF debit spend reverts on a live legacy debit safe and
 *         a live lend-gateway debit safe; after it, the same spends settle ZCHF into the Rain dispatcher.
 *
 *         Not in this bundle: settlement recipients for ZCHF on the dispatchers (EURC is a live spend
 *         asset with none either; ZCHF that reaches a dispatcher is moved by ops), credit-mode spend in
 *         ZCHF, top-up rails.
 *
 * Usage:
 *   forge script scripts/zchf-spend/ConfigureZchfSpendOP3CP.s.sol --rpc-url $OPTIMISM_RPC
 */
contract ConfigureZchfSpendOP3CP is GnosisHelpers, Utils, Test {
    string constant OUTPUT_PATH = "./output/ConfigureZchfSpendOP3CP-10.json";

    address constant OPERATING_SAFE = ZchfProd.OPERATING_SAFE;
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

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(OPERATING_SAFE));
        txs = _append(txs, address(debtManager), abi.encodeCall(IDebtManager.supportBorrowToken, (ZCHF, BORROW_APY, MIN_SHARES)), false);
        txs = _append(txs, address(gateway), abi.encodeCall(ILendGatewaySpendLike.setSpendAsset, (ZCHF, true)), true);

        vm.createDir("./output", true);
        vm.writeFile(OUTPUT_PATH, txs);
        console.log("Written: %s", OUTPUT_PATH);

        // ── fork rehearsal ────────────────────────────────────────────────────────────────────────
        _assertSpendReverts(LEGACY_DEBIT_SAFE, "pre-legacy");
        _assertSpendReverts(LEND_DEBIT_SAFE, "pre-lend");

        executeGnosisTransactionBundle(OUTPUT_PATH);

        _assertPostState();
        _assertSpendSettles(LEGACY_DEBIT_SAFE, "post-legacy");
        _assertSpendSettles(LEND_DEBIT_SAFE, "post-lend");
        console.log("Simulation passed: ZCHF debit-spends on legacy and lend-gateway safes, price %s (6 dec)", priceProvider.price(ZCHF));
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
