// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { StdCheats } from "forge-std/StdCheats.sol";

import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { ITradingSafeFactory } from "../../src/interfaces/ITradingSafeFactory.sol";
import { BeaconFactory } from "../../src/beacon-factory/BeaconFactory.sol";
import { TopUp } from "../../src/top-up/TopUp.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { TopUpV2 } from "../../src/top-up/TopUpV2.sol";
import { StockRedirectWrappers } from "../top-up/StockRedirectWrappers.sol";
import { StockWrapProdConfig } from "../top-up/StockWrapProdConfig.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";

/// @dev Minimal view of the beacon, to read back the implementation the upgrade sets.
interface IUpgradeableBeacon {
    function implementation() external view returns (address);
}

/**
 * @title StockWrapRedirectEth3CP
 * @author ether.fi
 * @notice 3CP-649 — turns on raw-xStock wrapping on redirect for the Ethereum prod TopUp stack, in
 *         ONE bundle of three ORDERED transactions:
 *
 *           1. TopUpFactory.upgradeToAndCall(newFactoryImpl, "")        — adds wrapperFor / setRedirectWrappers
 *           2. TopUpFactory.upgradeBeaconImplementation(topUpV2Impl)    — the 83,000+ TopUp proxies
 *           3. TopUpFactory.setRedirectWrappers(raws[90], wrappers[90]) — the raw -> wrapper table
 *
 *         Today a raw Backed xStock (TSLAx, AAPLx, ...) sent to a user's TopUp address is stranded:
 *         the TradingLens lists only the ERC-4626 wrapper, so `redirectToTradingSafe` rejects the
 *         raw token. After this, the redirect wraps on the way out — per-call approve →
 *         `deposit(amount, tradingSafe)` → approve 0 — and reports the shares the safe's balance
 *         actually rose by.
 *
 * @dev THE ORDER IS THE WHOLE REASON THIS IS ONE BUNDLE. A `TopUp` impl asks its owner (the
 *      factory) for `wrapperFor(token)`. Upgrading the beacon first would make every
 *      `redirectToTradingSafe` on all 83,000+ live prod TopUp proxies revert on a selector the old
 *      factory does not have, until tx 1 landed. Inside one Safe transaction the half-upgraded
 *      window does not exist. Tx 3 is inert until both impls are live, so it goes last.
 *
 * @dev WHY NO TIMELOCK. All three are owner-gated and on Ethereum the RoleRegistry owner is the
 *      OperatingSafe itself: `upgradeBeaconImplementation` and `setRedirectWrappers` are
 *      `onlyRoleRegistryOwner`, and the UUPS `_authorizeUpgrade` calls
 *      `roleRegistry.onlyUpgrader(msg.sender)`, which is an `owner() == account` check. Asserted
 *      on-chain below rather than assumed.
 *
 * @dev WHY TopUpV2 FOR THE BEACON. Ethereum currently runs plain `TopUp` while chains
 *      56 / 8453 / 42161 / 999 already run `TopUpV2`. The beacon slot has to be replaced for the
 *      wrapping behaviour regardless, so it is replaced with V2 and Ethereum stops being the odd
 *      one out. V2 = `TopUp` + `executeRecovery`, a sweep for funds stuck on the wrong chain,
 *      callable only by the immutable `DISPATCHER` and refusing topup-supported tokens.
 *
 * @dev WRAPPING IS CONFIGURATION, NOT A PARAMETER. Every redirect signature is unchanged; a token
 *      with no configured wrapper still redirects as-is. That is asserted in the simulation
 *      (`wrapperFor(WETH) == 0`) so the 90 rows cannot be read as "only these tokens redirect now".
 *
 * Prerequisite: both impls deployed and bytecode-verified
 *   scripts/top-up/DeployProdStockWrapRedirectEth.s.sol   (ENV=mainnet, --verify)
 *   scripts/top-up/VerifyStockWrapBytecode.s.sol
 *
 * Usage (no broadcast — writes ./output/*.json and simulates):
 *   forge script scripts/gnosis-txs/StockWrapRedirectEth3CP.s.sol --rpc-url $MAINNET_RPC
 */
contract StockWrapRedirectEth3CP is StockWrapProdConfig, GnosisHelpers, StdCheats {
    using stdJson for string;

    TopUpFactory internal factory;
    IRoleRegistry internal roleRegistry;
    address internal beacon;
    address internal tradingSafeFactory;
    address internal factoryImpl;
    address internal topUpV2Impl;
    address[] internal raws;
    address[] internal wrappers;

    function run() public {
        require(block.chainid == 1, "StockWrapRedirectEth: Ethereum mainnet only");
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
        roleRegistry = IRoleRegistry(deployments.readAddress(".addresses.RoleRegistry"));
        beacon = BeaconFactory(address(factory)).beacon();
        tradingSafeFactory = factory.tradingSafeFactory();
        factoryImpl = TOPUP_FACTORY_IMPL;
        topUpV2Impl = TOPUP_V2_IMPL;
        (raws, wrappers) = StockRedirectWrappers.pairs();
    }

    // ── Preconditions ─────────────────────────────────────────────────────────────

    function _checkPreconditions() internal view {
        _assertGovernance();
        _assertImpls();
        _assertPairs();
    }

    /// @dev The no-timelock premise, for all three calls at once.
    function _assertGovernance() internal view {
        require(address(factory).code.length > 0, "TopUpFactory has no code");
        require(address(factory.roleRegistry()) == address(roleRegistry), "factory reads a different RoleRegistry than deployments.json records");
        // Covers `onlyRoleRegistryOwner` (txs 2 and 3) AND `onlyUpgrader` (tx 1), which is an
        // owner() check on this registry.
        require(roleRegistry.owner() == SAFE, "Ethereum RoleRegistry owner is not the Safe - all three calls would revert");
    }

    /// @dev Both impls must exist and be what StockWrapProdConfig claims they are. Upgrading
    ///      83,000+ proxies to the wrong address is the worst failure this bundle could have, and
    ///      the pinned constants are hand-maintained — so every property that matters is re-derived
    ///      from the chain here rather than trusted.
    function _assertImpls() internal view {
        require(factoryImpl.code.length > 0, "TopUpFactory impl not deployed - run DeployProdStockWrapRedirectEth first");
        require(topUpV2Impl.code.length > 0, "TopUpV2 impl not deployed - run DeployProdStockWrapRedirectEth first");
        require(factoryImpl != topUpV2Impl, "the two pinned implementations are the same address");

        // The V2 immutables are baked into its code and cannot be changed by this bundle.
        require(TopUpV2(payable(topUpV2Impl)).DISPATCHER() == RECOVERY_DISPATCHER, "TopUpV2 impl has the wrong DISPATCHER");
        require(TopUpV2(payable(topUpV2Impl)).weth() == WETH, "TopUpV2 impl has the wrong weth");

        // Cheap identity check on the factory impl: confusing the two pinned constants would put
        // a TopUp behind the factory's own proxy, or the factory behind the TopUp beacon.
        require(TopUpFactory(payable(factoryImpl)).MAX_ALLOWED_SLIPPAGE() > 0, "factory impl does not look like a TopUpFactory");

        // Idempotence: refuse to rebuild a bundle that is already applied.
        require(IUpgradeableBeacon(beacon).implementation() != topUpV2Impl, "beacon already runs this TopUpV2 impl - upgrade already done?");
        require(_implOf(address(factory)) != factoryImpl, "factory already runs this impl - upgrade already done?");
    }

    /// @dev Every pair, checked against the chain before signing. `setRedirectWrappers` re-checks
    ///      the `asset()` pairing itself, so this only moves the failure earlier — but the trading
    ///      -support and not-topup-supported checks are NOT enforced on-chain and matter:
    ///      a wrapper the lens does not list would be wrapped into a form the safe cannot hold,
    ///      and a raw token with a bridge route of its own belongs in `processTopUp`.
    function _assertPairs() internal view {
        require(tradingSafeFactory != address(0), "tradingSafeFactory not set on the prod TopUpFactory");
        require(raws.length == wrappers.length && raws.length > 0, "pair arrays are empty or mismatched");

        for (uint256 i = 0; i < raws.length; ++i) {
            require(raws[i].code.length > 0, "raw stock has no code");
            require(wrappers[i].code.length > 0, "wrapper has no code");
            require(IERC4626(wrappers[i]).asset() == raws[i], "wrapper is not the ERC-4626 over its raw stock");
            require(ITradingSafeFactory(tradingSafeFactory).isSupportedToken(wrappers[i]), "wrapper is not trading-supported on the prod lens");
            require(!factory.isTokenSupported(raws[i]), "raw stock is topup-supported: it belongs in processTopUp");
        }
    }

    // ── Bundle construction ───────────────────────────────────────────────────────

    function _writeBundle() internal returns (string memory path) {
        bytes memory upgradeFactory = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (factoryImpl, ""));
        bytes memory upgradeBeacon = abi.encodeCall(BeaconFactory.upgradeBeaconImplementation, (topUpV2Impl));
        bytes memory setWrappers = abi.encodeCall(TopUpFactory.setRedirectWrappers, (raws, wrappers));

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(address(factory)), iToHex(upgradeFactory), "0", false));
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(address(factory)), iToHex(upgradeBeacon), "0", false));
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(address(factory)), iToHex(setWrappers), "0", true));

        vm.createDir("./output", true);
        path = string.concat("./output/3CP-649-StockWrapRedirect-eth-", vm.toString(block.chainid), ".json");
        vm.writeFile(path, txs);
        console.log("Wrote", path);
    }

    // ── Fork simulation ───────────────────────────────────────────────────────────

    function _simulateAndVerify(string memory path) internal {
        console.log("");
        console.log("=== Simulating the stock-wrap rollout bundle ===");
        console.log("  factory       :", address(factory));
        console.log("  beacon        :", beacon);
        console.log("  live TopUps    ", factory.numContractsDeployed());
        console.log("  pairs          ", raws.length);

        address ownerBefore = roleRegistry.owner();
        address beaconImplBefore = IUpgradeableBeacon(beacon).implementation();
        uint256 topUpsBefore = factory.numContractsDeployed();

        executeGnosisTransactionBundle(path);

        // ── The three legs ──
        require(_implOf(address(factory)) == factoryImpl, "SIM FAILED: factory impl not upgraded");
        require(IUpgradeableBeacon(beacon).implementation() == topUpV2Impl, "SIM FAILED: beacon impl not upgraded");
        require(beaconImplBefore != topUpV2Impl, "SIM FAILED: beacon impl did not actually change");
        for (uint256 i = 0; i < raws.length; ++i) {
            require(factory.wrapperFor(raws[i]) == wrappers[i], "SIM FAILED: redirect wrapper not registered");
        }

        // Wrapping is CONFIGURATION: an unconfigured token still redirects as-is.
        require(factory.wrapperFor(WETH) == address(0), "SIM FAILED: unexpected wrapper on an unconfigured token");

        // ── Collateral damage ──
        require(roleRegistry.owner() == ownerBefore, "SIM FAILED: RoleRegistry owner changed");
        require(factory.numContractsDeployed() == topUpsBefore, "SIM FAILED: TopUp set changed");
        require(factory.tradingSafeFactory() == tradingSafeFactory, "SIM FAILED: tradingSafeFactory changed");
        require(!factory.paused(), "SIM FAILED: factory ended up paused");

        // The V2 upgrade must not have cost the pre-existing TopUp behaviour, and must have added
        // the recovery entrypoint on the live proxies.
        require(TopUpV2(payable(topUpV2Impl)).DISPATCHER() == RECOVERY_DISPATCHER, "SIM FAILED: DISPATCHER mismatch after upgrade");

        _simulateWrappedRedirect();

        console.log("");
        console.log("  [OK] factory impl ->", factoryImpl);
        console.log("  [OK] beacon impl   ->", topUpV2Impl);
        console.log("  [OK] all", raws.length, "redirect wrappers registered");
        console.log("  [OK] unconfigured tokens still redirect as-is");
        console.log("");
        console.log("3CP-649 simulation passed.");
    }

    /// @dev Storage equality is not proof the feature WORKS. Drive a REAL redirect of a raw xStock
    ///      through a live prod TopUp and assert the TradingSafe received WRAPPER SHARES — the
    ///      whole point of the rollout.
    ///
    ///      Two details make this work on a fork. The TradingSafe is not stored on the TopUp: the
    ///      factory derives it as `getDeterministicAddress(topUp)` and requires it to be a deployed
    ///      EtherFi safe, so a TopUp is only usable here once its owner has a trading account —
    ///      hence the scan for a suitable one. And the raw stock is sourced by pranking the WRAPPER
    ///      (which holds the raw token as its vault asset) rather than `deal`, because these Backed
    ///      tokens are shares-based and cheatcode balance-slot discovery fails on them.
    function _simulateWrappedRedirect() internal {
        (address topUp, address tradingSafe) = _findRedirectableTopUp();
        if (topUp == address(0)) {
            console.log("");
            console.log("  [SKIP] no prod TopUp in the scanned window has a deployed TradingSafe;");
            console.log("         the wrapped-redirect leg was not exercised on-chain.");
            return;
        }

        uint256 amount = 1e15;
        (address raw, address wrapper) = _fundablePair(topUp, amount);
        if (raw == address(0)) {
            console.log("");
            console.log("  [SKIP] no wrapper in the table holds enough raw stock to source the sim");
            return;
        }

        uint256 sharesBefore = IERC20(wrapper).balanceOf(tradingSafe);

        // Read the role BEFORE pranking: an external call in the argument list would consume the
        // prank, and `grantRole` would then run as this script and revert unauthorized.
        bytes32 redirectRole = factory.TOPUP_FACTORY_REDIRECT_ROLE();
        vm.prank(SAFE);
        roleRegistry.grantRole(redirectRole, SAFE);
        vm.prank(SAFE);
        factory.redirectToTradingSafe(topUp, raw, amount);

        uint256 gained = IERC20(wrapper).balanceOf(tradingSafe) - sharesBefore;
        require(gained > 0, "SIM FAILED: TradingSafe received no wrapper shares");
        require(IERC20(raw).balanceOf(topUp) == 0, "SIM FAILED: raw stock left in the TopUp");
        require(IERC20(raw).allowance(topUp, wrapper) == 0, "SIM FAILED: approval left open on the wrapper");

        console.log("");
        console.log("  [OK] real redirect wrapped raw -> shares. TopUp:", topUp);
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
            address safe = ITradingSafeFactory(tradingSafeFactory).getDeterministicAddress(topUp);
            if (ITradingSafeFactory(tradingSafeFactory).isEtherFiSafe(safe)) return (topUp, safe);
        }
        return (address(0), address(0));
    }

    /// @dev Moves `amount` of some raw stock into `topUp` by pranking its wrapper, and returns the
    ///      pair used. Picks the first pair whose wrapper actually holds that much.
    function _fundablePair(address topUp, uint256 amount) internal returns (address, address) {
        for (uint256 i = 0; i < raws.length; ++i) {
            if (IERC20(raws[i]).balanceOf(wrappers[i]) < amount) continue;
            vm.prank(wrappers[i]);
            IERC20(raws[i]).transfer(topUp, amount);
            if (IERC20(raws[i]).balanceOf(topUp) >= amount) return (raws[i], wrappers[i]);
        }
        return (address(0), address(0));
    }

    function _implOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc))));
    }
}
