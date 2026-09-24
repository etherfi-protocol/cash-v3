// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { ISpokeLike, LendRails } from "../../scripts/stock-listing/StockLendConfig.sol";
import { ConfigureStockWrappersCashOP3CP } from "../../scripts/stock-migration/ConfigureStockWrappersCashOP3CP.s.sol";
import { FlipStockPricesCashOP3CP } from "../../scripts/stock-migration/FlipStockPricesCashOP3CP.s.sol";
import { FlipStockReservesSummerLend3CP } from "../../scripts/stock-migration/FlipStockReservesSummerLend3CP.s.sol";
import { ListStockWrappersSummerLend3CP } from "../../scripts/stock-migration/ListStockWrappersSummerLend3CP.s.sol";
import { PauseStockRailsOptimism3CP, UnpauseStockRailsOptimism3CP } from "../../scripts/stock-migration/PauseStockRails3CP.s.sol";
import { PauseStockReservesSummerLend3CP } from "../../scripts/stock-migration/PauseStockReservesSummerLend3CP.s.sol";
import { MigratedStock, StockMigration } from "../../scripts/stock-migration/StockMigrationConfig.sol";
import { BinSponsor, Cashback, ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";

interface ISpokeUserSupply {
    function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256);
}

interface IAccessManagerLike {
    function grantRole(uint64 roleId, address account, uint32 executionDelay) external;
}

/**
 * @notice Runs the OP-side stock migration bundles in order against live Optimism and checks that a real
 *         safe holding mirror collateral with debt can still spend, borrow, repay and withdraw at each stage.
 *         The payout and lend sweep are simulated by dealing the wrapper 1:1 for the safe's mirror supply.
 *
 *         The bundle scripts write their JSON to ./output; the test skips if any of those files already
 *         exist and deletes the ones it wrote when it finishes.
 *
 * Run:
 *   source .env && forge test --match-contract StockMigrationActionsForkTest -vv
 *   Optional env: MIGRATION_TEST_SAFE (default below), FORK_BLOCK (0 / unset = latest)
 */
contract StockMigrationActionsForkTest is Test {
    address constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant CASH_MODULE = 0x7Ca0b75E67E33c0014325B739A8d019C4FE445F0;
    address constant LEND_GATEWAY = 0x01F8cDFb1694eA8fE4ED6c38a0fD78d1188E03F4;
    address constant ROLE_REGISTRY = 0x5C1E3D653fcbC54Ae25c2AD9d59548D2082C687B;
    address constant AAVE_ACCESS_MANAGER = 0x188d7173772499FB6375F23FdFd130CE6107286b;
    address constant LEND_TIMELOCK = 0xbaCa0cD6B69Eef3257e2D122b22ddEE8AeE5e283;
    /// @dev A Credit-mode gateway safe with iwSPYx supplied and USDC debt.
    address constant DEFAULT_SAFE = 0x4426B67eC6793dF4BCc337b11d2406749d235622;
    uint256 constant ACTION_USD = 10e6;

    string[7] outputs = ["./output/ListStockWrappersSummerLend3CP-10.json", "./output/ConfigureStockWrappersCashOP3CP-10.json", "./output/PauseStockReservesSummerLend3CP-10.json", "./output/PauseStockRailsOptimism3CP-10.json", "./output/FlipStockReservesSummerLend3CP-10.json", "./output/FlipStockPricesCashOP3CP-10.json", "./output/UnpauseStockRailsOptimism3CP-10.json"];

    struct Result {
        bool spend;
        bool borrow;
        bool repay;
        bool withdraw;
    }

    ICashModule cashModule = ICashModule(CASH_MODULE);
    LendGateway gw = LendGateway(LEND_GATEWAY);
    address safe;
    address wallet = makeAddr("etherFiWallet");
    uint256 nonce;

    function setUp() public {
        string memory rpc = vm.envOr("OPTIMISM_RPC", string("https://optimism-rpc.publicnode.com"));
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pin);

        for (uint256 i = 0; i < outputs.length; ++i) {
            if (vm.exists(outputs[i])) {
                console.log("Skipping: bundle already exists, not overwriting it:", outputs[i]);
                vm.skip(true);
            }
        }

        safe = vm.envOr("MIGRATION_TEST_SAFE", DEFAULT_SAFE);
        require(cashModule.usesLendGateway(safe), "test safe is not on the lend gateway");
        require(ISpokeUserSupply(LendRails.CASH_SPOKE).getUserSuppliedAssets(StockMigration.all()[0].oldReserveId, safe) > 0, "test safe holds no iwSPYx");

        IRoleRegistry rr = IRoleRegistry(ROLE_REGISTRY);
        vm.prank(rr.owner());
        rr.grantRole(keccak256("ETHER_FI_WALLET_ROLE"), wallet);

        // Fork only: since 2026-09-19 the listing (200, 400) roles sit with the 24h lend timelock, not the
        // Lend Owner Safe the bundles target. Hand them back here so the actions can be checked end to end.
        vm.startPrank(LEND_TIMELOCK);
        IAccessManagerLike(AAVE_ACCESS_MANAGER).grantRole(200, LendRails.LEND_OWNER_SAFE, 0);
        IAccessManagerLike(AAVE_ACCESS_MANAGER).grantRole(400, LendRails.LEND_OWNER_SAFE, 0);
        vm.stopPrank();
    }

    function test_fork_majorActionsAcrossMigration() public {
        MigratedStock[] memory stocks = StockMigration.all();

        _requireAll(_checkStage("0 baseline", stocks[0].iToken));

        new ListStockWrappersSummerLend3CP().run();
        new ConfigureStockWrappersCashOP3CP().run();
        _requireAll(_checkStage("1 wrappers listed at placeholder", stocks[0].iToken));

        new PauseStockReservesSummerLend3CP().run();
        new PauseStockRailsOptimism3CP().run();
        Result memory weekend = _checkStage("2 mirrors paused (weekend)", stocks[0].iToken);
        assertTrue(weekend.spend, "spend blocked while mirrors are paused");
        assertTrue(weekend.repay, "repay blocked while mirrors are paused");

        _simulatePayoutAndSweep(stocks);
        uint256 hfBefore = gw.healthFactor(safe);
        new FlipStockReservesSummerLend3CP().run();
        new FlipStockPricesCashOP3CP().run();
        uint256 hfAfter = gw.healthFactor(safe);
        console.log("health factor before flip", hfBefore, "after flip", hfAfter);
        assertApproxEqRel(hfAfter, hfBefore, 0.005e18, "health factor moved across the flip");
        _requireAll(_checkStage("3 flipped", stocks[0].wrapper));

        new UnpauseStockRailsOptimism3CP().run();
        _requireAll(_checkStage("4 modules unpaused", stocks[0].wrapper));

        _cleanup();
    }

    // ----------------------------------------------------------------- stages

    /// @dev Deals each stock's wrapper 1:1 for the safe's mirror supply and supplies it as collateral.
    function _simulatePayoutAndSweep(MigratedStock[] memory stocks) internal {
        ISpokeUserSupply spoke = ISpokeUserSupply(LendRails.CASH_SPOKE);
        for (uint256 i = 0; i < stocks.length; ++i) {
            uint256 mirror = spoke.getUserSuppliedAssets(stocks[i].oldReserveId, safe);
            if (mirror == 0) continue;
            deal(stocks[i].wrapper, safe, IERC20(stocks[i].wrapper).balanceOf(safe) + mirror);
            vm.startPrank(CASH_MODULE);
            gw.supply(safe, stocks[i].wrapper, mirror);
            gw.setUsingAsCollateral(safe, stocks[i].wrapper, true);
            vm.stopPrank();
            console.log(string.concat("  ", stocks[i].symbol, ": supplied wrapper for mirror"), mirror);
        }
    }

    /// @dev Tries each action from the same state and rolls it back, so every stage starts clean.
    function _checkStage(string memory name, address collateral) internal returns (Result memory r) {
        console.log(string.concat("Stage ", name, ", health factor"), gw.healthFactor(safe));
        r.spend = _try(name, "spend", abi.encodeCall(this.actSpend, ()));
        r.borrow = _try(name, "borrow", abi.encodeCall(this.actBorrow, ()));
        r.repay = _try(name, "repay", abi.encodeCall(this.actRepay, ()));
        r.withdraw = _try(name, "withdraw", abi.encodeCall(this.actWithdraw, (collateral)));
    }

    function _try(string memory stage, string memory action, bytes memory call) internal returns (bool) {
        uint256 snap = vm.snapshotState();
        (bool ok, bytes memory err) = address(this).call(call);
        vm.revertToState(snap);
        if (ok) console.log(string.concat("  ", action, ": ok"));
        else console.log(string.concat("  ", action, ": REVERTED at stage ", stage, ", error"), vm.toString(err));
        return ok;
    }

    function _requireAll(Result memory r) internal pure {
        require(r.spend && r.borrow && r.repay && r.withdraw, "a major action reverted; see the log above");
    }

    // ----------------------------------------------------------------- actions (external for rollback)

    function actSpend() external {
        address[] memory tokens = new address[](1);
        tokens[0] = USDC;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = ACTION_USD;
        vm.prank(wallet);
        cashModule.spend(safe, keccak256(abi.encode("stock-migration-fork", ++nonce)), BinSponsor.Rain, tokens, amounts, new Cashback[](0));
    }

    function actBorrow() external {
        vm.prank(CASH_MODULE);
        gw.borrow(safe, USDC, ACTION_USD, safe);
    }

    function actRepay() external {
        deal(USDC, safe, IERC20(USDC).balanceOf(safe) + ACTION_USD);
        vm.prank(wallet);
        cashModule.repay(safe, USDC, ACTION_USD);
    }

    function actWithdraw(address collateral) external {
        uint256 amount = gw.suppliedOf(safe, collateral) / 100;
        require(amount > 0, "nothing supplied to withdraw");
        vm.prank(CASH_MODULE);
        gw.withdraw(safe, collateral, amount, safe);
    }

    function _cleanup() internal {
        for (uint256 i = 0; i < outputs.length; ++i) {
            if (vm.exists(outputs[i])) vm.removeFile(outputs[i]);
        }
    }
}
