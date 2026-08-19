// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { StdCheats } from "forge-std/StdCheats.sol";

import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { TradingLens } from "../../src/trading-safe/TradingLens.sol";
import { TradingSafeFactory } from "../../src/trading-safe/TradingSafeFactory.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title ListSlvxEth3CP
 * @author ether.fi
 * @notice Lists SLVx (iShares Silver Trust xStock) as a supported trading + redirect asset on the
 *         Ethereum prod stack, in ONE bundle of two ORDERED transactions:
 *
 *           1. TradingLens.addSupportedToken(wSLVx)                 — puts wSLVx on the lens
 *           2. TopUpFactory.setRedirectWrappers([rawSLVx], [wSLVx]) — the raw -> wrapper row
 *
 *         wSLVx (the ERC-4626 `WrappedBackedToken` over raw SLVx) is a real wrapper that was
 *         simply never added to the `TradingLens`, so it fell out of the lens ∩ xstocks-catalogue
 *         intersection that `StockRedirectWrappers.pairs()` is derived from. wGLDx and wPPLTx —
 *         the other two bullion xStocks — are already on the lens and already in that table, so
 *         this is a listing gap, not an asset-class exclusion.
 *
 * @dev THE ORDER IS LOAD-BEARING. `TopUpFactory.redirectToTradingSafe` guards on
 *      `ITradingSafeFactory.isSupportedToken(wrapper == 0 ? token : wrapper)`, which
 *      (`TradingSafeFactory.sol:264-268`) delegates straight to the `TradingLens`. Registering
 *      the raw -> wrapper row before the lens knows wSLVx would leave a redirect configured that
 *      still reverts `TokenNotTradingSupported` on every call. Inside one Safe bundle the gap
 *      never actually exists — both calls execute back-to-back in the same Gnosis Safe
 *      transaction as tx 1 and tx 2 — but the order documents the dependency for anyone reading
 *      or re-deriving this bundle later.
 *
 * @dev WHAT EACH CALL VALIDATES, so a bad row cannot silently be signed.
 *      - `addSupportedToken` reverts `TokenAlreadySupported` if wSLVx is already in the set.
 *        Verified NOT present: `isSupportedToken(wSLVx) == false` on the live prod lens.
 *      - `setRedirectWrappers` reverts `InvalidRedirectWrapper` unless
 *        `IERC4626(wrapper).asset() == token`. Verified: `wSLVx.asset() == rawSLVx`, so a
 *        transposed row (wSLVx paired against the wrong raw stock, or vice versa) is rejected by
 *        the chain itself, not just by this script's precondition checks.
 *
 * @dev WHY NO TIMELOCK. Both calls are gated by roles the OperatingSafe already holds, on TWO
 *      DIFFERENT `RoleRegistry` instances — the prod trading stack and the prod top-up stack do
 *      not share one:
 *        - `TopUpFactory.setRedirectWrappers` is `onlyRoleRegistryOwner` on the TopUpFactory's
 *          OWN RoleRegistry (`factory.roleRegistry()`); that registry's `owner()` is the Safe.
 *        - `TradingLens.addSupportedToken` checks `MULTISIG_ADMIN_ROLE` on the TradingLens's
 *          OWN RoleRegistry (`lens.roleRegistry()`) — a different deployed instance — on which
 *          the Safe separately holds that role directly.
 *      Both are asserted on-chain below rather than assumed identical.
 *
 * @dev PREREQUISITE: 3CP-649 (`StockWrapRedirectEth3CP.s.sol`) must land first — it is what gives
 *      the prod `TopUpFactory` `setRedirectWrappers` / `wrapperFor` at all. At the time this
 *      script was authored that bundle had been generated but not yet signed on real mainnet (the
 *      live factory implementation still lacks the selector), so the fork simulation below
 *      replays 649's recorded output (`output/3CP-649-StockWrapRedirect-eth-1.json`) as a
 *      TEST-HARNESS setup step before testing this bundle, rather than asserting a state that
 *      does not exist yet. That replay is not part of the two transactions this script emits. If
 *      649 has already landed for real by the time this runs, the replay is skipped (idempotence
 *      is checked via `wrapperFor`, which reverts on the pre-649 implementation and succeeds
 *      after).
 *
 * @dev WITHDRAWALS ARE SINGLE-LEG BY PRODUCT RULE, NOT JUST A V1 SIMPLIFICATION. The cash-be
 *      withdrawal submit DTO moves one token at a time — there is no array — so the backend can
 *      never itself construct a multi-leg `Withdrawal[]` call that mixes an unwrap leg (e.g.
 *      wSLVx -> SLVx) with a plain leg in the same transaction. That combined shape is a known
 *      indexer gap: a directly-relayed (not backend-originated) multi-leg call can still produce
 *      it, and the indexer currently suppresses the plain leg's history row when it does (pinned
 *      by an `#[ignore]`d test in cash-event-indexer). Noted here because SLVx's withdraw path is
 *      a wrap/unwrap pair like every other xStock in the redirect table — this bundle does not
 *      create that gap and does not fix it; it is simply unreachable from our own single-leg
 *      rail.
 *
 * Usage (no broadcast — writes ./output/*.json and simulates):
 *   forge script scripts/gnosis-txs/ListSlvxEth3CP.s.sol --rpc-url $MAINNET_RPC
 */
contract ListSlvxEth3CP is Utils, GnosisHelpers, StdCheats {
    using stdJson for string;

    /// @notice Prod Safe (OperatingSafe). Holds `MULTISIG_ADMIN_ROLE` on the TradingLens's
    ///         RoleRegistry directly, and is the owner of the TopUpFactory's RoleRegistry — so it
    ///         can sign both calls with no timelock.
    address internal constant SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    /// @notice Raw iShares Silver Trust xStock. `symbol() == "SLVx"`.
    address internal constant RAW_SLVX = 0x4833e7f4f0460f4B72A3a5879A6C9841bCC5B58B;

    /// @notice ERC-4626 `WrappedBackedToken` over raw SLVx. `asset() == RAW_SLVX`.
    address internal constant WRAPPED_SLVX = 0xB842EacB35Fd9c1bEDA53749072Ef22823f2cA8c;

    /// @dev Path to 3CP-649's recorded bundle, replayed on the fork if this factory predates it.
    string internal constant PREREQ_3CP_649_PATH = "./output/3CP-649-StockWrapRedirect-eth-1.json";

    TopUpFactory internal factory;
    TradingLens internal lens;
    /// @dev Concrete type (not the `ITradingSafeFactory` interface) because `tradingLens()` —
    ///      needed to resolve the lens this bundle configures directly — is not on that
    ///      interface; every consumer that only needs `isSupportedToken` et al. uses the
    ///      interface instead.
    TradingSafeFactory internal tradingSafeFactory;

    function run() public {
        require(block.chainid == 1, "ListSlvxEth3CP: Ethereum mainnet only");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        _loadAddresses();
        _checkPreconditions();

        string memory path = _writeBundle();
        _simulateAndVerify(path);
    }

    // ── Address loading ───────────────────────────────────────────────────────────

    function _loadAddresses() internal {
        string memory deployments = readTopUpSourceDeployment();
        factory = TopUpFactory(payable(deployments.readAddress(".addresses.TopUpSourceFactory")));
        tradingSafeFactory = TradingSafeFactory(factory.tradingSafeFactory());
        lens = TradingLens(tradingSafeFactory.tradingLens());
    }

    // ── Preconditions ─────────────────────────────────────────────────────────────

    function _checkPreconditions() internal view {
        _assertGovernance();
        _assertPair();
    }

    /// @dev The no-timelock premise, for both calls, on their respective RoleRegistry.
    function _assertGovernance() internal view {
        require(address(factory).code.length > 0, "TopUpFactory has no code");
        require(address(lens).code.length > 0, "TradingLens has no code");

        require(
            factory.roleRegistry().owner() == SAFE,
            "TopUpFactory's RoleRegistry owner is not the Safe - setRedirectWrappers would revert"
        );
        require(
            lens.roleRegistry().hasRole(lens.MULTISIG_ADMIN_ROLE(), SAFE),
            "Safe lacks MULTISIG_ADMIN_ROLE on the TradingLens's RoleRegistry - addSupportedToken would revert"
        );
    }

    /// @dev Checked against the chain before signing, even though `addSupportedToken` and
    ///      `setRedirectWrappers` re-check most of this themselves — this only moves the failure
    ///      earlier and gives a readable reason instead of a bare revert selector.
    function _assertPair() internal view {
        require(RAW_SLVX.code.length > 0, "raw SLVx has no code");
        require(WRAPPED_SLVX.code.length > 0, "wSLVx has no code");
        require(IERC4626(WRAPPED_SLVX).asset() == RAW_SLVX, "wSLVx is not the ERC-4626 over raw SLVx");
        require(!lens.isSupportedToken(WRAPPED_SLVX), "wSLVx is already on the TradingLens - addSupportedToken would revert TokenAlreadySupported");
        require(!factory.isTokenSupported(RAW_SLVX), "raw SLVx is topup-supported: it belongs in processTopUp, not the redirect table");
    }

    // ── Bundle construction ───────────────────────────────────────────────────────

    function _writeBundle() internal returns (string memory path) {
        bytes memory addToken = abi.encodeCall(TradingLens.addSupportedToken, (WRAPPED_SLVX));

        address[] memory tokens = new address[](1);
        address[] memory wrappers = new address[](1);
        tokens[0] = RAW_SLVX;
        wrappers[0] = WRAPPED_SLVX;
        bytes memory setWrapper = abi.encodeCall(TopUpFactory.setRedirectWrappers, (tokens, wrappers));

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(address(lens)), iToHex(addToken), "0", false));
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(address(factory)), iToHex(setWrapper), "0", true));

        vm.createDir("./output", true);
        path = "./output/3CP-SLVx-Listing-eth-1.json";
        vm.writeFile(path, txs);
        console.log("Wrote", path);
    }

    // ── Fork simulation ───────────────────────────────────────────────────────────

    function _simulateAndVerify(string memory path) internal {
        _ensurePrerequisite3CP649();

        console.log("");
        console.log("=== Simulating the SLVx listing bundle ===");
        console.log("  lens          :", address(lens));
        console.log("  factory       :", address(factory));

        bool listedBefore = lens.isSupportedToken(WRAPPED_SLVX);
        address wrapperBefore = factory.wrapperFor(RAW_SLVX);
        uint256 lensCountBefore = lens.getSupportedTokens().length;
        bool pausedBefore = factory.paused();

        executeGnosisTransactionBundle(path);

        // ── The two legs ──
        require(!listedBefore, "SIM FAILED: wSLVx was already on the lens before the bundle ran");
        require(lens.isSupportedToken(WRAPPED_SLVX), "SIM FAILED: wSLVx not added to the lens");
        require(lens.getSupportedTokens().length == lensCountBefore + 1, "SIM FAILED: lens grew by more or less than exactly one token");

        require(wrapperBefore == address(0), "SIM FAILED: redirect wrapper was already configured before the bundle ran");
        require(factory.wrapperFor(RAW_SLVX) == WRAPPED_SLVX, "SIM FAILED: redirect wrapper not registered");

        // ── Collateral damage ──
        require(factory.paused() == pausedBefore, "SIM FAILED: factory pause state changed");
        require(!factory.paused(), "SIM FAILED: factory ended up paused");

        _simulateWrappedRedirect();

        console.log("");
        console.log("  [OK] wSLVx added to the TradingLens");
        console.log("  [OK] rawSLVx -> wSLVx redirect wrapper registered");
        console.log("");
        console.log("SLVx listing simulation passed.");
    }

    /// @dev Brings the fork to "post-3CP-649" state if it isn't already there, by replaying that
    ///      bundle's recorded output. This is a TEST-HARNESS step, not part of the two
    ///      transactions this script emits — in reality the Safe only ever signs this bundle
    ///      after 649 has landed for real.
    function _ensurePrerequisite3CP649() internal {
        if (_factoryHasWrapping()) return;

        require(
            vm.exists(PREREQ_3CP_649_PATH),
            "3CP-649 output missing and the live factory predates it; run StockWrapRedirectEth3CP first"
        );

        console.log("");
        console.log("[SETUP] Live TopUpFactory predates 3CP-649 (no wrapperFor/setRedirectWrappers yet).");
        console.log("        Replaying its recorded bundle on this fork before testing the SLVx bundle.");
        executeGnosisTransactionBundle(PREREQ_3CP_649_PATH);

        require(_factoryHasWrapping(), "3CP-649 replay did not give the factory setRedirectWrappers - cannot test on top of it");
    }

    function _factoryHasWrapping() internal view returns (bool) {
        try factory.wrapperFor(RAW_SLVX) returns (address) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Storage equality is not proof the feature WORKS. Drive a REAL redirect of raw SLVx
    ///      through a live prod TopUp and assert the TradingSafe received wSLVx SHARES — the
    ///      whole point of this listing.
    ///
    ///      Two details carried over from `StockWrapRedirectEth3CP`. The TradingSafe is not
    ///      stored on the TopUp: the factory derives it as `getDeterministicAddress(topUp)` and
    ///      requires it to be a deployed EtherFi safe, so a TopUp is only usable here once its
    ///      owner has a trading account — hence the scan for a suitable one. And the raw SLVx is
    ///      sourced by pranking the WRAPPER (which holds raw SLVx as its vault asset) rather than
    ///      `deal`, because this Backed-style xStock is shares-based and cheatcode balance-slot
    ///      discovery fails on it.
    function _simulateWrappedRedirect() internal {
        (address topUp, address tradingSafe) = _findRedirectableTopUp();
        if (topUp == address(0)) {
            console.log("");
            console.log("  [SKIP] no prod TopUp in the scanned window has a deployed TradingSafe;");
            console.log("         the wrapped-redirect leg was not exercised on-chain.");
            return;
        }

        uint256 amount = 1e15;
        if (IERC20(RAW_SLVX).balanceOf(WRAPPED_SLVX) < amount) {
            console.log("");
            console.log("  [SKIP] wSLVx does not hold enough raw SLVx to source the sim");
            return;
        }

        vm.prank(WRAPPED_SLVX);
        IERC20(RAW_SLVX).transfer(topUp, amount);
        require(IERC20(RAW_SLVX).balanceOf(topUp) >= amount, "funding the TopUp with raw SLVx failed");

        uint256 sharesBefore = IERC20(WRAPPED_SLVX).balanceOf(tradingSafe);

        // Read the role AND resolve the registry BEFORE pranking: an external call as part of
        // the pranked statement (even just `factory.roleRegistry()` as the receiver expression)
        // would consume the prank itself, and `grantRole` would then run as this script and
        // revert `EnumerableRolesUnauthorized`.
        bytes32 redirectRole = factory.TOPUP_FACTORY_REDIRECT_ROLE();
        IRoleRegistry topUpRoleRegistry = factory.roleRegistry();
        vm.prank(SAFE);
        topUpRoleRegistry.grantRole(redirectRole, SAFE);
        vm.prank(SAFE);
        factory.redirectToTradingSafe(topUp, RAW_SLVX, amount);

        uint256 gained = IERC20(WRAPPED_SLVX).balanceOf(tradingSafe) - sharesBefore;
        require(gained > 0, "SIM FAILED: TradingSafe received no wSLVx shares");
        require(IERC20(RAW_SLVX).balanceOf(topUp) == 0, "SIM FAILED: raw SLVx left in the TopUp");
        require(IERC20(RAW_SLVX).allowance(topUp, WRAPPED_SLVX) == 0, "SIM FAILED: approval left open on the wrapper");

        console.log("");
        console.log("  [OK] real redirect wrapped raw SLVx -> wSLVx shares. TopUp:", topUp);
        console.log("       raw in:", amount);
        console.log("       shares delivered to the TradingSafe:", gained);
    }

    /// @dev Scans the most recent prod TopUps for one whose derived TradingSafe is deployed.
    function _findRedirectableTopUp() internal view returns (address, address) {
        uint256 total = factory.numContractsDeployed();
        uint256 window = total < 300 ? total : 300;
        address[] memory topUps = factory.getDeployedAddresses(total - window, window);

        for (uint256 i = topUps.length; i > 0; --i) {
            address topUp = topUps[i - 1];
            address safe = tradingSafeFactory.getDeterministicAddress(topUp);
            if (tradingSafeFactory.isEtherFiSafe(safe)) return (topUp, safe);
        }
        return (address(0), address(0));
    }
}
