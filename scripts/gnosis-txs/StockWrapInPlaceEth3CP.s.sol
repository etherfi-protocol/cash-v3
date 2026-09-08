// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { console } from "forge-std/console.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { BeaconFactory } from "../../src/beacon-factory/BeaconFactory.sol";
import { TopUp } from "../../src/top-up/TopUp.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { TopUpV2 } from "../../src/top-up/TopUpV2.sol";
import { StockRedirectWrappers } from "../top-up/StockRedirectWrappers.sol";
import { StockWrapInPlaceProdConfig } from "../top-up/StockWrapInPlaceProdConfig.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";

/**
 * @title StockWrapInPlaceEth3CP
 * @author ether.fi
 * @notice Moves the Ethereum **prod** SPYx / QQQx / TBLLx off the raw-bridge rail and onto the
 *         wrap-in-place rail, in ONE bundle of ORDERED transactions on the prod `TopUpFactory`:
 *
 *           1. upgradeToAndCall(factoryImpl, "")               — adds removeTokenConfig + wrapStocks
 *           2. upgradeBeaconImplementation(topUpImpl)          — adds TopUp.wrap on every proxy
 *           3. removeTokenConfig([SPYx, QQQx, TBLLx], [10,…])  — retires the raw topup routes
 *           4. setRedirectWrappers(raws, wrappers)             — the raw -> wrapper table the wrap reads
 *           5. setTokenConfig(wrappers, [10,…], cfgs)          — the wrappers' own onward route
 *
 *         Today a raw Backed stock deposited into a TopUp is swept to the factory and wrapped
 *         inside `bridge()` by `StockOFTBridgeAdapter` (3CP-647). After this, the raw stock is
 *         wrapped **at the TopUp** by `wrapStocks` -> `TopUp.wrap`, and what travels onward is the
 *         wrapper — wSPYx / wQQQx / wTBLLx — over the ordinary plain-OFT topup route, landing at
 *         the same OP `TopUpDest` as the same iTOKENs.
 *
 * @dev WHY THIS CANNOT BE SPLIT. The two rails are mutually exclusive by construction:
 *      `wrapStocks` reverts `OnlyUnsupportedTokens` for a token that still has a topup
 *      configuration, and `_validateSweepTokens` reverts `OnlySupportedTokens` for one that does
 *      not. Between tx 3 and tx 4 a raw stock belongs to NEITHER rail — inside one Safe
 *      transaction that window does not exist.
 *
 *      Ordering within the bundle is load-bearing for the same reason it was in 3CP-649, plus one
 *      more: txs 3-5 call selectors the LIVE factory impl does not have, so the factory upgrade
 *      must precede them; and `wrapStocks` calls `TopUp.wrap`, which the live beacon impl does not
 *      have, so the beacon upgrade must land before anyone wraps. Nothing regresses in between —
 *      `redirectToTradingSafe`'s wrap leg moved to an internal `_wrap` with unchanged behaviour.
 *
 * @dev WHY THE WRAPPERS NEED tx 5. Wrapping is only half a journey: the shares still have to leave
 *      the TopUp. `processTopUp` refuses a token with no topup configuration, so without tx 5 the
 *      wrapped balance would sit at the TopUp with no rail to carry it — the raws would be retired
 *      into a dead end. The wrappers cannot inherit the raw route either: its adapter
 *      (`StockOFTBridgeAdapter`) derives the wrapper from the OFT and requires
 *      `IERC4626(wrapper).asset() == token`, so pointing it at the wrapper is unconfigurable. What
 *      the wrapper needs is the plain `EtherFiOFTBridgeAdapter` — it IS the OFT token — which is
 *      exactly the route wTBLLx already runs from 3CP-640. Any wrapper that already has that route
 *      is left alone; tx 5 carries only the ones that are missing (the "if not already added" half).
 *
 * @dev WHY NO TIMELOCK. All five calls are owner-gated and on Ethereum the RoleRegistry owner is
 *      the OperatingSafe itself: `upgradeBeaconImplementation`, `removeTokenConfig`,
 *      `setRedirectWrappers` and `setTokenConfig` are `onlyRoleRegistryOwner`, and the UUPS
 *      `_authorizeUpgrade` calls `roleRegistry.onlyUpgrader(msg.sender)`, which is an
 *      `owner() == account` check. Asserted on-chain below rather than assumed.
 *
 * @dev IDEMPOTENT BY CONSTRUCTION. Every leg is filtered against live state before the bundle is
 *      written: an already-retired route, an already-registered pair, an already-configured wrapper
 *      route and an already-applied upgrade are all dropped. That matters more than convenience
 *      here — `removeTokenConfig` reverts `TokenConfigNotSet` on a route that is already gone and
 *      `setTokenConfig` would silently OVERWRITE a live wrapper route, and either would take the
 *      whole Safe transaction with it.
 *
 * Prerequisite: both impls deployed, pinned in `StockWrapInPlaceProdConfig` and bytecode-verified
 *   scripts/top-up/DeployProdStockWrapInPlaceEth.s.sol   (ENV=mainnet, --verify)
 *   scripts/top-up/VerifyStockWrapInPlaceBytecode.s.sol
 *
 * Usage (no broadcast — writes ./output/*.json and simulates):
 *   forge script scripts/gnosis-txs/StockWrapInPlaceEth3CP.s.sol --rpc-url $MAINNET_RPC
 *
 * Rehearsal BEFORE the impls exist (deploys them on the fork, writes a *-DRYRUN.json that must
 * never be signed):
 *   DRY_RUN=true forge script scripts/gnosis-txs/StockWrapInPlaceEth3CP.s.sol --rpc-url $MAINNET_RPC
 *
 * Optional deeper simulation (adds a real OFT send of the wrapped shares off the factory):
 *   SIMULATE_BRIDGE=true forge script scripts/gnosis-txs/StockWrapInPlaceEth3CP.s.sol --rpc-url $MAINNET_RPC
 */
contract StockWrapInPlaceEth3CP is StockWrapInPlaceProdConfig, GnosisHelpers, StdCheats {
    using stdJson for string;

    /// @dev Ticket this bundle ships under; names the output file.
    string internal constant TICKET = "3CP-656";

    /// @dev ERC-1967 implementation slot, for reading the factory proxy's live impl.
    bytes32 internal constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev BRIDGE DESTINATIONS, not chains this bundle touches. Nothing here is deployed to or
    ///      upgraded — these are `destChainId` keys read off the ETHEREUM factory's own token
    ///      config, to prove each raw stock's only route is the Optimism one being retired.
    ///
    ///      Why it matters: `removeTokenConfig` drops a token from the supported set as soon as ONE
    ///      of its routes is cleared, and the set has no per-chain granularity, so a route left on
    ///      another destination would stay bridgeable while sweeping stops — a half-retired asset.
    ///      A token's configured destinations are not enumerable on-chain, hence this explicit list.
    uint256[] internal otherDestChainIds = [uint256(56), 137, 8453, 42_161, 534_352, 59_144, 999];

    TopUpFactory internal factory;
    IRoleRegistry internal roleRegistry;
    address internal beacon;
    address internal tradingSafeFactory;
    address internal rawBridgeAdapter;
    address internal wrapperBridgeAdapter;
    address internal recipient;

    /// @dev The impls the bundle names. Equal to the pinned constants, except under DRY_RUN.
    address internal factoryImpl;
    address internal topUpImpl;
    bool internal dryRun;

    // The bundle, planned against live state.
    bool internal upgradeFactory;
    bool internal upgradeBeacon;
    address[] internal retireTokens;
    uint256[] internal retireChainIds;
    address[] internal pairRaws;
    address[] internal pairWrappers;
    address[] internal routeTokens;
    uint256[] internal routeChainIds;
    TopUpFactory.TokenConfig[] internal routeConfigs;

    function run() public {
        require(block.chainid == 1, "StockWrapInPlaceEth: Ethereum mainnet only");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        _loadAddresses();
        _resolveImpls();
        _plan();
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

        // The rail being retired. Recorded AND predicted, so a manifest edit cannot quietly point
        // the "expected adapter" check at something else.
        rawBridgeAdapter = _adapterAddress();
        require(deployments.readAddress(string.concat(".addresses.", ADAPTER_DEPLOYMENT_KEY)) == rawBridgeAdapter, "recorded StockOFTBridgeAdapter != predicted CREATE3 address");

        // The rail taking over.
        wrapperBridgeAdapter = _oftBridgeAdapter();
        recipient = _topUpDestOptimism();
    }

    /// @dev Under DRY_RUN the impls are deployed on the fork so the whole plan can be rehearsed
    ///      before the real broadcast. The bundle it writes names fork addresses and is therefore
    ///      unsignable — the filename says so, and so does the log.
    function _resolveImpls() internal {
        factoryImpl = WRAP_IN_PLACE_FACTORY_IMPL;
        topUpImpl = WRAP_IN_PLACE_TOPUP_IMPL;
        if (factoryImpl != address(0) && topUpImpl != address(0)) return;

        require(vm.envOr("DRY_RUN", false), "impls not pinned in StockWrapInPlaceProdConfig - run DeployProdStockWrapInPlaceEth first, or set DRY_RUN=true to rehearse");
        dryRun = true;
        factoryImpl = address(new TopUpFactory());
        topUpImpl = address(new TopUpV2(WETH, RECOVERY_DISPATCHER));
        console.log("DRY RUN: impls deployed on the fork, not pinned. The bundle written is NOT signable.");
    }

    // ── Planning: what of this is not already true on-chain ───────────────────────

    function _plan() internal {
        upgradeFactory = _implOf(address(factory)) != factoryImpl;
        upgradeBeacon = UpgradeableBeacon(beacon).implementation() != topUpImpl;

        StockTopupAsset[] memory assets = _assets();
        for (uint256 i = 0; i < assets.length; ++i) {
            StockTopupAsset memory a = assets[i];

            if (factory.getTokenConfig(a.stock, OP_CHAIN_ID).bridgeAdapter != address(0)) {
                retireTokens.push(a.stock);
                retireChainIds.push(OP_CHAIN_ID);
            } else {
                console.log(string.concat("  skip retire (no OP route): ", a.symbol));
            }

            if (factory.wrapperFor(a.stock) != a.wrapper) {
                pairRaws.push(a.stock);
                pairWrappers.push(a.wrapper);
            } else {
                console.log(string.concat("  skip pair (already registered): ", a.symbol));
            }

            if (factory.getTokenConfig(a.wrapper, OP_CHAIN_ID).bridgeAdapter == address(0)) {
                routeTokens.push(a.wrapper);
                routeChainIds.push(OP_CHAIN_ID);
                routeConfigs.push(_wrapperTokenConfig(wrapperBridgeAdapter, recipient, a.oftAdapter));
            } else {
                console.log(string.concat("  skip wrapper route (already configured): w", a.symbol));
            }
        }

        require(
            upgradeFactory || upgradeBeacon || retireTokens.length > 0 || pairRaws.length > 0 || routeTokens.length > 0,
            "nothing to do: impls current, raws retired, pairs registered and wrapper routes configured"
        );
    }

    // ── Preconditions ─────────────────────────────────────────────────────────────

    function _checkPreconditions() internal view {
        _assertGovernance();
        _assertImpls();
        _assertRawRail();
        _assertWrapperRail();
        _reportRedirectTable();
    }

    /// @dev The no-timelock premise, for all five calls at once.
    function _assertGovernance() internal view {
        require(address(factory).code.length > 0, "TopUpFactory has no code");
        require(address(factory.roleRegistry()) == address(roleRegistry), "factory reads a different RoleRegistry than deployments.json records");
        // Covers `onlyRoleRegistryOwner` (txs 2-5) AND `onlyUpgrader` (tx 1), which is an owner()
        // check on this registry.
        require(roleRegistry.owner() == SAFE, "Ethereum RoleRegistry owner is not the Safe - every call in this bundle would revert");
        require(!factory.paused(), "TopUpFactory is paused - wrapStocks and the sweeps would revert after this lands");
    }

    /// @dev Upgrading every live TopUp proxy to the wrong address is the worst failure this bundle
    ///      could have, and the pinned constants are hand-maintained — so every property that
    ///      matters is re-derived from the chain rather than trusted.
    function _assertImpls() internal view {
        require(factoryImpl.code.length > 0, "TopUpFactory impl has no code");
        require(topUpImpl.code.length > 0, "TopUp impl has no code");
        require(factoryImpl != topUpImpl, "the two implementations are the same address");

        // The V2 immutables are baked into its code and cannot be changed by this bundle. The
        // dispatcher is cross-checked against the LIVE beacon impl too: replacing the beacon with
        // an impl carrying a different dispatcher would quietly break asset recovery everywhere.
        require(TopUpV2(payable(topUpImpl)).DISPATCHER() == RECOVERY_DISPATCHER, "TopUp impl has the wrong DISPATCHER");
        require(TopUpV2(payable(topUpImpl)).weth() == WETH, "TopUp impl has the wrong weth");

        address liveTopUpImpl = UpgradeableBeacon(beacon).implementation();
        require(TopUp(payable(liveTopUpImpl)).weth() == WETH, "live beacon impl points at a different WETH");
        address liveDispatcher = _dispatcherOf(liveTopUpImpl);
        require(liveDispatcher == address(0) || liveDispatcher == RECOVERY_DISPATCHER, "live beacon impl has a different dispatcher - this bundle would change it");

        // Cheap identity checks on the factory impl: confusing the two constants would put a TopUp
        // behind the factory's own proxy, or the factory behind the TopUp beacon.
        require(TopUpFactory(payable(factoryImpl)).MAX_ALLOWED_SLIPPAGE() > 0, "factory impl does not look like a TopUpFactory");
        require(TopUpFactory(payable(factoryImpl)).wrapperFor(address(0)) == address(0), "factory impl predates redirect wrapping");
    }

    /// @dev The rail being retired: every raw stock's whole footprint, so nothing is left
    ///      half-retired, and every pairing the wrap will rely on.
    function _assertRawRail() internal view {
        _assertAssetWiring();

        StockTopupAsset[] memory assets = _assets();
        for (uint256 i = 0; i < assets.length; ++i) {
            StockTopupAsset memory a = assets[i];
            require(a.stock.code.length > 0, string.concat(a.symbol, ": raw stock has no code"));
            require(a.wrapper.code.length > 0, string.concat(a.symbol, ": wrapper has no code"));

            // The same pairing `setRedirectWrappers` re-checks on-chain; asserted here so a wrong
            // constant fails before signing rather than reverting the Safe transaction.
            require(IERC4626(a.wrapper).asset() == a.stock, string.concat(a.symbol, ": wrapper is not the ERC-4626 over its raw stock"));
            require(IERC4626(a.wrapper).previewDeposit(1e15) > 0, string.concat(a.symbol, ": wrapper previews a zero-share deposit"));

            // An already-registered pair must agree with this asset set, or the wrapper the wrap
            // would use is not the one this bundle vouches for.
            address registered = factory.wrapperFor(a.stock);
            require(registered == address(0) || registered == a.wrapper, string.concat(a.symbol, ": a DIFFERENT wrapper is already registered"));

            // A live route must be the rail we think we are retiring.
            TopUpFactory.TokenConfig memory raw = factory.getTokenConfig(a.stock, OP_CHAIN_ID);
            if (raw.bridgeAdapter != address(0)) {
                require(raw.bridgeAdapter == rawBridgeAdapter, string.concat(a.symbol, ": OP route uses an unexpected bridge adapter - investigate before retiring it"));
            } else {
                require(!factory.isTokenSupported(a.stock), string.concat(a.symbol, ": topup-supported with no OP route - find its configured chain before retiring"));
            }

            // Nothing left behind on another bridge destination (read-only; see the field's docs).
            for (uint256 j = 0; j < otherDestChainIds.length; ++j) {
                require(
                    factory.getTokenConfig(a.stock, otherDestChainIds[j]).bridgeAdapter == address(0),
                    string.concat(a.symbol, ": still has a route to another destination chain - add it to the retire list or the asset ends up half-retired")
                );
            }
        }
    }

    /// @dev The rail taking over. The two things storage cannot show — that the route is QUOTABLE
    ///      and that the shares actually move — are left to the simulation.
    function _assertWrapperRail() internal view {
        _assertWrapperRouteWiring();

        require(wrapperBridgeAdapter.code.length > 0, "EtherFiOFTBridgeAdapter has no code at the recorded address");
        require(recipient != address(0), "OP TopUpDest missing from deployments/mainnet/10");
        require(WRAPPER_MAX_SLIPPAGE_BPS > 0, "wrapper slippage must be nonzero or the route cannot be quoted");
        require(WRAPPER_MAX_SLIPPAGE_BPS <= factory.MAX_ALLOWED_SLIPPAGE(), "wrapper slippage exceeds TopUpFactory.MAX_ALLOWED_SLIPPAGE");

        StockTopupAsset[] memory assets = _assets();
        for (uint256 i = 0; i < assets.length; ++i) {
            StockTopupAsset memory a = assets[i];
            TopUpFactory.TokenConfig memory live = factory.getTokenConfig(a.wrapper, OP_CHAIN_ID);
            if (live.bridgeAdapter == address(0)) continue;

            // A pre-existing wrapper route (3CP-640 configured wTBLLx) is left untouched — but only
            // if it sends where this bundle expects, since it is what the retired raws now depend on.
            require(live.recipientOnDestChain == recipient, string.concat("w", a.symbol, ": existing route pays a DIFFERENT recipient than the OP TopUpDest"));
            require(live.maxSlippageInBps > 0, string.concat("w", a.symbol, ": existing route has zero slippage and cannot be quoted"));
            require(factory.isTokenSupported(a.wrapper), string.concat("w", a.symbol, ": has a route but is not in the supported set"));
        }
    }

    /// @dev Informational: the 90-pair redirect table from 3CP-649 is what makes every OTHER raw
    ///      xStock wrappable. Not a precondition for these three, but if it is missing then that
    ///      bundle has not executed and its last leg is still outstanding — worth knowing before
    ///      this one is signed on top.
    function _reportRedirectTable() internal view {
        (address[] memory raws, address[] memory wrappers) = StockRedirectWrappers.pairs();
        uint256 registered;
        for (uint256 i = 0; i < raws.length; ++i) {
            if (factory.wrapperFor(raws[i]) == wrappers[i]) ++registered;
        }
        console.log("3CP-649 redirect table registered:", registered, "of", raws.length);
        if (registered < raws.length) console.log("NOTE: redirect-wrapper table incomplete - 3CP-649's setRedirectWrappers leg is still outstanding.");
    }

    // ── Bundle construction ───────────────────────────────────────────────────────

    function _writeBundle() internal returns (string memory path) {
        address[] memory targets = new address[](5);
        bytes[] memory datas = new bytes[](5);
        uint256 n;

        if (upgradeFactory) {
            targets[n] = address(factory);
            datas[n++] = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (factoryImpl, ""));
        }
        if (upgradeBeacon) {
            targets[n] = address(factory);
            datas[n++] = abi.encodeCall(BeaconFactory.upgradeBeaconImplementation, (topUpImpl));
        }
        if (retireTokens.length > 0) {
            (address[] memory tokens, uint256[] memory chainIds) = _retireArgs();
            targets[n] = address(factory);
            datas[n++] = abi.encodeCall(TopUpFactory.removeTokenConfig, (tokens, chainIds));
        }
        if (pairRaws.length > 0) {
            (address[] memory raws, address[] memory wrappers) = _pairArgs();
            targets[n] = address(factory);
            datas[n++] = abi.encodeCall(TopUpFactory.setRedirectWrappers, (raws, wrappers));
        }
        if (routeTokens.length > 0) {
            (address[] memory tokens, uint256[] memory chainIds, TopUpFactory.TokenConfig[] memory configs) = _routeArgs();
            targets[n] = address(factory);
            datas[n++] = abi.encodeWithSelector(TopUpFactory.setTokenConfig.selector, tokens, chainIds, configs);
        }

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
        for (uint256 i = 0; i < n; ++i) {
            txs = string.concat(txs, _getGnosisTransaction(addressToHex(targets[i]), iToHex(datas[i]), "0", i == n - 1));
        }

        vm.createDir("./output", true);
        path = string.concat("./output/", TICKET, "-StockWrapInPlace-eth-", vm.toString(block.chainid), dryRun ? "-DRYRUN.json" : ".json");
        vm.writeFile(path, txs);

        console.log("");
        console.log("Wrote", path);
        console.log("  transactions       :", n);
        console.log("  routes retired     :", retireTokens.length);
        console.log("  pairs registered   :", pairRaws.length);
        console.log("  wrapper routes set :", routeTokens.length);
        if (dryRun) console.log("  DRY RUN - names fork-deployed impls. Do NOT sign this file.");
    }

    /// @dev Storage arrays copied to memory: the encoders take memory, and a copy keeps the planned
    ///      bundle and the simulated bundle reading from one source.
    function _retireArgs() internal view returns (address[] memory tokens, uint256[] memory chainIds) {
        tokens = new address[](retireTokens.length);
        chainIds = new uint256[](retireChainIds.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            tokens[i] = retireTokens[i];
            chainIds[i] = retireChainIds[i];
        }
    }

    function _pairArgs() internal view returns (address[] memory raws, address[] memory wrappers) {
        raws = new address[](pairRaws.length);
        wrappers = new address[](pairWrappers.length);
        for (uint256 i = 0; i < raws.length; ++i) {
            raws[i] = pairRaws[i];
            wrappers[i] = pairWrappers[i];
        }
    }

    function _routeArgs() internal view returns (address[] memory tokens, uint256[] memory chainIds, TopUpFactory.TokenConfig[] memory configs) {
        tokens = new address[](routeTokens.length);
        chainIds = new uint256[](routeChainIds.length);
        configs = new TopUpFactory.TokenConfig[](routeConfigs.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            tokens[i] = routeTokens[i];
            chainIds[i] = routeChainIds[i];
            configs[i] = routeConfigs[i];
        }
    }

    // ── Fork simulation ───────────────────────────────────────────────────────────

    function _simulateAndVerify(string memory path) internal {
        console.log("");
        console.log("=== Simulating the wrap-in-place bundle ===");
        console.log("  factory        :", address(factory));
        console.log("  beacon         :", beacon);
        console.log("  live TopUps     ", factory.numContractsDeployed());
        console.log("  raw adapter    :", rawBridgeAdapter);
        console.log("  wrapper adapter:", wrapperBridgeAdapter);
        console.log("  OP TopUpDest   :", recipient);

        address ownerBefore = roleRegistry.owner();
        uint256 topUpsBefore = factory.numContractsDeployed();
        (address[] memory redirectRaws,) = StockRedirectWrappers.pairs();
        address redirectSampleBefore = factory.wrapperFor(redirectRaws[0]);

        executeGnosisTransactionBundle(path);

        // ── The upgrade legs ──
        require(_implOf(address(factory)) == factoryImpl, "SIM FAILED: factory impl not upgraded");
        require(UpgradeableBeacon(beacon).implementation() == topUpImpl, "SIM FAILED: beacon impl not upgraded");
        require(TopUpV2(payable(topUpImpl)).DISPATCHER() == RECOVERY_DISPATCHER, "SIM FAILED: DISPATCHER changed");

        // ── The configuration legs ──
        StockTopupAsset[] memory assets = _assets();
        for (uint256 i = 0; i < assets.length; ++i) {
            StockTopupAsset memory a = assets[i];

            // Off the topup lane: BOTH halves, since `bridge` reads the config and everything else
            // reads the supported set.
            require(!factory.isTokenSupported(a.stock), string.concat("SIM FAILED: ", a.symbol, " still topup-supported"));
            require(factory.getTokenConfig(a.stock, OP_CHAIN_ID).bridgeAdapter == address(0), string.concat("SIM FAILED: ", a.symbol, " still has an OP route"));

            // On the wrap rail.
            require(factory.wrapperFor(a.stock) == a.wrapper, string.concat("SIM FAILED: ", a.symbol, " wrapper not registered"));

            // The wrapper's onward rail exists, is stored as intended, and — the only check that
            // proves anything about the live executor config — is QUOTABLE.
            TopUpFactory.TokenConfig memory route = factory.getTokenConfig(a.wrapper, OP_CHAIN_ID);
            require(route.bridgeAdapter != address(0), string.concat("SIM FAILED: w", a.symbol, " has no onward route"));
            require(route.recipientOnDestChain == recipient, string.concat("SIM FAILED: w", a.symbol, " route recipient"));
            require(factory.isTokenSupported(a.wrapper), string.concat("SIM FAILED: w", a.symbol, " not in the supported set"));

            (, uint256 fee) = factory.getBridgeFee(a.wrapper, 1e15, OP_CHAIN_ID);
            require(fee > 0, string.concat("SIM FAILED: w", a.symbol, " quoted a zero bridge fee - route not quotable"));
            console.log(string.concat("  [OK] w", a.symbol, " route quotable. Fee for 1e15 (wei):"), fee);
        }

        // The retired raws must now be REFUSED by the permissionless sweeps: anything else would
        // let a caller pull a raw stock into the factory, out of reach of the wrap.
        address[] memory rawOnly = new address[](1);
        rawOnly[0] = assets[0].stock;
        vm.expectRevert(TopUpFactory.OnlySupportedTokens.selector);
        factory.processTopUp(rawOnly, 0, 1);

        // ── Collateral damage ──
        require(roleRegistry.owner() == ownerBefore, "SIM FAILED: RoleRegistry owner changed");
        require(factory.numContractsDeployed() == topUpsBefore, "SIM FAILED: TopUp set changed");
        require(factory.tradingSafeFactory() == tradingSafeFactory, "SIM FAILED: tradingSafeFactory changed");
        require(!factory.paused(), "SIM FAILED: factory ended up paused");
        require(factory.wrapperFor(redirectRaws[0]) == redirectSampleBefore, "SIM FAILED: an unrelated redirect wrapper changed");

        _simulateWrapAndSweep();

        console.log("");
        console.log("  [OK] factory impl ->", factoryImpl);
        console.log("  [OK] beacon impl   ->", topUpImpl);
        console.log("  [OK] raws retired, pairs registered, wrapper routes quotable");
        console.log("");
        console.log(string.concat(TICKET, " simulation passed."));
    }

    /**
     * @dev Storage equality is not proof the rail WORKS. Drive the whole new path on a real prod
     *      TopUp: raw stock in -> `wrapStocks` -> shares held by the same TopUp -> permissionless
     *      sweep to the factory -> (optionally) a real OFT send to Optimism.
     *
     *      Unlike the redirect path, this one needs no TradingSafe: `wrapStocks` credits the shares
     *      to the TopUp itself, so any factory-deployed TopUp will do. The raw stock is sourced by
     *      pranking the WRAPPER — which holds the raw token as its vault asset — rather than `deal`,
     *      because these Backed tokens are shares-based and cheatcode balance-slot discovery fails
     *      on them.
     */
    function _simulateWrapAndSweep() internal {
        address topUp = factory.getDeployedAddresses(factory.numContractsDeployed() - 1, 1)[0];

        (StockTopupAsset memory a, uint256 amount, bool found) = _fundableAsset(topUp);
        if (!found) {
            console.log("");
            console.log("  [SKIP] no wrapper holds enough raw stock to source the wrap simulation");
            return;
        }

        address[] memory one = new address[](1);
        one[0] = a.stock;

        uint256 sharesBefore = IERC20(a.wrapper).balanceOf(topUp);
        factory.wrapStocks(topUp, one);
        uint256 shares = IERC20(a.wrapper).balanceOf(topUp) - sharesBefore;

        require(shares > 0, string.concat("SIM FAILED: ", a.symbol, " wrap minted no shares"));
        require(IERC20(a.stock).allowance(topUp, a.wrapper) == 0, string.concat("SIM FAILED: ", a.symbol, " approval left open on the wrapper"));

        // `wrapStocks` deposits the TopUp's WHOLE balance, so what may be left is rounding dust and
        // nothing else. These Backed stocks are shares-based, so each assets<->shares conversion
        // truncates by up to a wei: the wrap reads the balance in assets and the vault pulls it in
        // shares, which is why this is a dust bound and not a zero check. Anything beyond dust
        // would mean part of the deposit did not happen.
        uint256 dust = IERC20(a.stock).balanceOf(topUp);
        require(dust <= 2, string.concat("SIM FAILED: ", a.symbol, " raw stock left at the TopUp beyond rounding dust"));

        console.log("");
        console.log(string.concat("  [OK] wrapStocks converted ", a.symbol, " at a live TopUp:"), topUp);
        console.log("       raw in :", amount);
        console.log("       shares :", shares);
        console.log("       dust   :", dust);

        // The onward rail, exercised rather than asserted: the wrapper must be sweepable off the
        // TopUp, which is exactly what the raws lose and the wrappers gain in this bundle.
        one[0] = a.wrapper;
        address[] memory topUps = new address[](1);
        topUps[0] = topUp;
        uint256 factoryBefore = IERC20(a.wrapper).balanceOf(address(factory));
        factory.processTopUpFromContracts(one, topUps);
        uint256 swept = IERC20(a.wrapper).balanceOf(address(factory)) - factoryBefore;
        require(swept >= shares, string.concat("SIM FAILED: w", a.symbol, " shares did not sweep to the factory"));
        console.log(string.concat("  [OK] sweep moved the w", a.symbol, " shares to the factory:"), swept);

        if (vm.envOr("SIMULATE_BRIDGE", false)) _simulateBridge(a);
    }

    /// @dev Opt-in end-to-end leg (`SIMULATE_BRIDGE=true`): a real OFT send of the swept shares, so
    ///      the LayerZero pathway is exercised rather than just quoted. Off by default because it
    ///      grants a role on the fork and spends fee value, neither of which should be able to block
    ///      bundle generation.
    function _simulateBridge(StockTopupAsset memory a) internal {
        uint256 amount = IERC20(a.wrapper).balanceOf(address(factory));
        require(amount > 0, "nothing to bridge");

        // `bridge` charges the CALLER: the quoted fee has to arrive as msg.value, not merely sit on
        // the factory. That is how the keeper pays for it in production too.
        (, uint256 fee) = factory.getBridgeFee(a.wrapper, amount, OP_CHAIN_ID);
        vm.deal(SAFE, fee * 2);

        uint256 lockedBefore = IERC20(a.wrapper).balanceOf(a.oftAdapter);

        bytes32 bridgerRole = factory.TOPUP_FACTORY_BRIDGER_ROLE();
        vm.prank(SAFE);
        roleRegistry.grantRole(bridgerRole, SAFE);
        vm.prank(SAFE);
        factory.bridge{ value: fee }(a.wrapper, amount, OP_CHAIN_ID);

        uint256 locked = IERC20(a.wrapper).balanceOf(a.oftAdapter) - lockedBefore;
        uint256 residue = IERC20(a.wrapper).balanceOf(address(factory));
        require(locked > 0, string.concat("SIM FAILED: w", a.symbol, " OFT adapter locked no shares"));

        // Conservation: everything that left the factory is locked by the OFT, and what stayed is
        // the OFT's shared-decimals truncation and nothing more. The Backed OFTs use 6 shared
        // decimals against an 18-decimal wrapper, so anything at or above 1e12 would mean the send
        // silently moved less than it was asked to — the thing `maxSlippageInBps` exists to bound.
        require(locked + residue == amount, string.concat("SIM FAILED: w", a.symbol, " shares unaccounted for"));
        require(residue < 1e12, string.concat("SIM FAILED: w", a.symbol, " left more than dust behind"));

        console.log(string.concat("  [OK] real OFT send of w", a.symbol, ". Shares locked:"), locked);
        console.log("       dust left at the factory:", residue);
    }

    /**
     * @dev Moves some raw stock into `topUp` by pranking its wrapper, and returns the asset and the
     *      amount moved.
     *
     *      The amount returned is what ARRIVED, not what was sent. These Backed stocks are
     *      shares-based (stETH-style): a transfer converts assets to shares and rounds down, so the
     *      recipient's balance lands a wei or two short of the requested amount. Asserting the
     *      requested amount arrived exactly is what silently skipped this leg on the first run.
     */
    function _fundableAsset(address topUp) internal returns (StockTopupAsset memory, uint256, bool) {
        StockTopupAsset[] memory assets = _assets();

        uint256 best;
        uint256 bestIdx;
        for (uint256 i = 0; i < assets.length; ++i) {
            uint256 held = IERC20(assets[i].stock).balanceOf(assets[i].wrapper);
            console.log(string.concat("       ", assets[i].symbol, " held by its wrapper:"), held);
            if (held > best) {
                best = held;
                bestIdx = i;
            }
        }

        StockTopupAsset memory a = assets[bestIdx];
        uint256 send = best > 2e15 ? 1e15 : best / 2;
        if (send == 0 || IERC4626(a.wrapper).previewDeposit(send) == 0) return (a, 0, false);

        uint256 before = IERC20(a.stock).balanceOf(topUp);
        vm.prank(a.wrapper);
        IERC20(a.stock).transfer(topUp, send);

        uint256 arrived = IERC20(a.stock).balanceOf(topUp) - before;
        if (arrived == 0) return (a, 0, false);
        return (a, arrived, true);
    }

    /// @dev The impl's recovery dispatcher, or zero when it is a plain `TopUp`. `TopUp` has no
    ///      fallback, so the staticcall reverts rather than returning garbage.
    function _dispatcherOf(address impl) internal view returns (address) {
        (bool ok, bytes memory ret) = impl.staticcall(abi.encodeWithSignature("DISPATCHER()"));
        if (!ok || ret.length != 32) return address(0);
        return abi.decode(ret, (address));
    }

    function _implOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967_IMPL_SLOT))));
    }
}
