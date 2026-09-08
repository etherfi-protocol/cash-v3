// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { ITradingSafeFactory } from "../../src/interfaces/ITradingSafeFactory.sol";
import { TopUp } from "../../src/top-up/TopUp.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { TopUpV2 } from "../../src/top-up/TopUpV2.sol";
import { StockTopupConfig } from "../stock-topup/StockTopupConfig.sol";

/**
 * @title DeployDevStockWrapInPlaceEth
 * @notice Moves the Ethereum **dev** stack's raw xStocks (SPYx / QQQx / TBLLx) off the
 *         raw-bridge rail and onto the wrap-in-place rail: upgrades the dev `TopUpFactory` and
 *         its `TopUp` beacon to the implementations carrying `wrapStocks` / `TopUp.wrap` and
 *         `removeTokenConfig`, retires each raw stock's topup route, and registers each raw →
 *         wrapper pair so the raw stock can be converted at the TopUp that holds it.
 *
 * @dev The two rails are mutually exclusive by construction, which is why this is one script and
 *      not three. Today a raw stock is topup-supported with `StockOFTBridgeAdapter` as its bridge
 *      adapter, wrapping inside `bridge()` on the way out; `wrapStocks` refuses any token that
 *      still has a topup configuration (`OnlyUnsupportedTokens`), because an asset with a route of
 *      its own belongs on the sweep rail. So the route has to be retired in the same breath the
 *      wrapper is registered, or the stock spends the gap belonging to neither rail.
 *
 *      Ordering inside the broadcast is load-bearing:
 *        1. Factory impl first — it is what supplies `removeTokenConfig` and `wrapStocks`, so
 *           steps 3 and 4 do not exist on the live impl until it lands.
 *        2. Beacon second — `wrapStocks` calls `TopUp.wrap`, which the current TopUp impl has no
 *           selector for. Nothing else regresses in between: `redirectToTradingSafe`'s wrap leg
 *           moved to an internal `_wrap` with unchanged behaviour, and the factory's `wrapperFor`
 *           has been live since the redirect-wrapping rollout.
 *        3. Retire the raw routes, 4. register the pairs — both inert until the impls are live.
 *
 *      The beacon's replacement impl is derived from what the beacon currently points at rather
 *      than assumed: the ETH beacons are plain `TopUp`, while chains 56/8453/42161/999 run
 *      `TopUpV2(weth, dispatcher)`. The script reads the live impl's `weth()` and probes for
 *      `DISPATCHER()`, and rebuilds the same shape — so it cannot silently drop the recovery
 *      dispatcher if it is ever run against a V2 beacon.
 *
 *      Idempotent: a raw stock whose route is already retired is skipped, and so is a pair already
 *      registered, so a partial run can be repeated. The impls are redeployed on every run, which
 *      is harmless (fresh impl, same bytecode) but not free — check the post-state output before
 *      re-running.
 *
 *      Deliberately NOT asserted: that the wrappers are trading-supported. The redirect rollout
 *      required that because the shares land in a TradingSafe; here they stay at the TopUp, and
 *      wSPYx in particular is not on the dev lens. What the script does instead is report each
 *      wrapper's onward rails — topup-supported (sweep and bridge) and trading-supported (redirect)
 *      — and warn only when a wrapper has neither, which is the one case where wrapping would
 *      leave the balance parked at the TopUp with nothing to carry it.
 *
 * Usage (simulate by dropping --broadcast; the wallet must be the dev RoleRegistry OWNER — the
 * factory upgrade, the beacon upgrade, `removeTokenConfig` and `setRedirectWrappers` are all
 * owner-gated):
 *   source .env && ENV=dev forge script \
 *     scripts/top-up/DeployDevStockWrapInPlaceEth.s.sol:DeployDevStockWrapInPlaceEth \
 *     --rpc-url $MAINNET_RPC --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvv
 */
contract DeployDevStockWrapInPlaceEth is StockTopupConfig {
    function run() public {
        require(block.chainid == 1, "must run on Ethereum (1)");
        require(_isDev(), "dev-only: targets the dev TopUpFactory");

        string memory deployments = readTopUpSourceDeployment();
        TopUpFactory factory = TopUpFactory(payable(stdJson.readAddress(deployments, ".addresses.TopUpSourceFactory")));
        IRoleRegistry roleRegistry = IRoleRegistry(stdJson.readAddress(deployments, ".addresses.RoleRegistry"));

        address sender = vm.addr(vm.envUint("PRIVATE_KEY"));
        require(roleRegistry.owner() == sender, "sender is not the dev RoleRegistry owner");

        StockTopupAsset[] memory assets = _assets();
        _preflight(factory, assets);

        (address[] memory retireTokens, uint256[] memory retireChainIds) = _routesToRetire(factory, assets);
        (address[] memory pairRaws, address[] memory pairWrappers) = _pairsToRegister(factory, assets);

        // The live beacon shape, read before anything is broadcast.
        address currentTopUpImpl = UpgradeableBeacon(factory.beacon()).implementation();
        address weth = TopUp(payable(currentTopUpImpl)).weth();
        address dispatcher = _dispatcherOf(currentTopUpImpl);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // 1. Factory first: it carries `removeTokenConfig` and `wrapStocks`.
        address factoryImpl = address(new TopUpFactory());
        UUPSUpgradeable(address(factory)).upgradeToAndCall(factoryImpl, "");

        // 2. Beacon second: `wrapStocks` calls `TopUp.wrap`, which the old impl lacks.
        address topUpImpl = dispatcher == address(0) ? address(new TopUp(weth)) : address(new TopUpV2(weth, dispatcher));
        factory.upgradeBeaconImplementation(topUpImpl);

        // 3. Retire the raw routes — what makes the stocks eligible to be wrapped at all.
        if (retireTokens.length > 0) factory.removeTokenConfig(retireTokens, retireChainIds);

        // 4. Register the pairs the wrap reads.
        if (pairRaws.length > 0) factory.setRedirectWrappers(pairRaws, pairWrappers);

        vm.stopBroadcast();

        _assertPostState(factory, assets, topUpImpl, dispatcher, weth);

        console.log("TopUpFactory impl   :", factoryImpl);
        console.log("TopUp impl          :", topUpImpl, dispatcher == address(0) ? "(TopUp)" : "(TopUpV2)");
        console.log("routes retired      :", retireTokens.length);
        console.log("pairs registered    :", pairRaws.length);
    }

    /// @dev Fails before the broadcast on anything the chain disagrees with.
    function _preflight(TopUpFactory factory, StockTopupAsset[] memory assets) internal view {
        for (uint256 i = 0; i < assets.length; ++i) {
            StockTopupAsset memory a = assets[i];
            require(a.stock.code.length > 0, string.concat(a.symbol, ": raw stock has no code"));
            require(a.wrapper.code.length > 0, string.concat(a.symbol, ": wrapper has no code"));
            // The same pairing `setRedirectWrappers` re-checks on-chain; asserted here so a wrong
            // constant fails before the upgrade rather than half-way through the broadcast.
            require(IERC4626(a.wrapper).asset() == a.stock, string.concat(a.symbol, ": wrapper is not the ERC-4626 over its raw stock"));

            // A stock that is topup-supported but has no route on the chain this script names
            // cannot be retired here — the caller has to be told which chain to pass rather than
            // have the token silently left on the lane.
            if (factory.isTokenSupported(a.stock)) {
                require(
                    factory.getTokenConfig(a.stock, OP_CHAIN_ID).bridgeAdapter != address(0),
                    string.concat(a.symbol, ": topup-supported with no Optimism route; find its configured chain before retiring")
                );
            }

            // Already-registered pairs must agree with this asset set, or the wrapper the wrap uses
            // is not the one this script vouches for.
            address registered = factory.wrapperFor(a.stock);
            require(registered == address(0) || registered == a.wrapper, string.concat(a.symbol, ": a different wrapper is already registered"));
        }
    }

    /// @dev The (stock, chain) routes still live, so a repeat run doesn't revert `TokenConfigNotSet`.
    function _routesToRetire(TopUpFactory factory, StockTopupAsset[] memory assets) internal view returns (address[] memory tokens, uint256[] memory chainIds) {
        uint256 n;
        for (uint256 i = 0; i < assets.length; ++i) {
            if (factory.getTokenConfig(assets[i].stock, OP_CHAIN_ID).bridgeAdapter != address(0)) ++n;
        }

        tokens = new address[](n);
        chainIds = new uint256[](n);
        uint256 k;
        for (uint256 i = 0; i < assets.length; ++i) {
            if (factory.getTokenConfig(assets[i].stock, OP_CHAIN_ID).bridgeAdapter == address(0)) {
                console.log("skip retire (no OP route):", assets[i].symbol);
                continue;
            }
            tokens[k] = assets[i].stock;
            chainIds[k] = OP_CHAIN_ID;
            ++k;
        }
    }

    /// @dev The pairs not already registered, so a repeat run is a no-op rather than a rewrite.
    function _pairsToRegister(TopUpFactory factory, StockTopupAsset[] memory assets) internal view returns (address[] memory raws, address[] memory wrappers) {
        uint256 n;
        for (uint256 i = 0; i < assets.length; ++i) {
            if (factory.wrapperFor(assets[i].stock) != assets[i].wrapper) ++n;
        }

        raws = new address[](n);
        wrappers = new address[](n);
        uint256 k;
        for (uint256 i = 0; i < assets.length; ++i) {
            if (factory.wrapperFor(assets[i].stock) == assets[i].wrapper) {
                console.log("skip register (already paired):", assets[i].symbol);
                continue;
            }
            raws[k] = assets[i].stock;
            wrappers[k] = assets[i].wrapper;
            ++k;
        }
    }

    /// @dev The current beacon impl's recovery dispatcher, or zero when it is a plain `TopUp`.
    ///      `TopUp` has no fallback, so the staticcall reverts rather than returning garbage.
    function _dispatcherOf(address topUpImpl) internal view returns (address) {
        (bool ok, bytes memory ret) = topUpImpl.staticcall(abi.encodeWithSignature("DISPATCHER()"));
        if (!ok || ret.length != 32) return address(0);
        return abi.decode(ret, (address));
    }

    function _assertPostState(TopUpFactory factory, StockTopupAsset[] memory assets, address topUpImpl, address dispatcher, address weth) internal view {
        address tsFactory = factory.tradingSafeFactory();
        require(UpgradeableBeacon(factory.beacon()).implementation() == topUpImpl, "beacon not upgraded");
        require(TopUp(payable(topUpImpl)).weth() == weth, "new TopUp impl points at a different WETH");
        require(_dispatcherOf(topUpImpl) == dispatcher, "new TopUp impl changed the recovery dispatcher");

        for (uint256 i = 0; i < assets.length; ++i) {
            StockTopupAsset memory a = assets[i];

            // Off the topup lane: both halves, since `bridge` reads the config and everything else
            // reads the set.
            require(!factory.isTokenSupported(a.stock), string.concat(a.symbol, ": raw stock still topup-supported"));
            require(factory.getTokenConfig(a.stock, OP_CHAIN_ID).bridgeAdapter == address(0), string.concat(a.symbol, ": raw stock still has an Optimism route"));

            // On the wrap rail.
            require(factory.wrapperFor(a.stock) == a.wrapper, string.concat(a.symbol, ": wrapper not registered"));

            // Wrapping is only half a journey: the shares still have to leave the TopUp, by the
            // sweep-and-bridge rail (topup-supported) or the redirect rail (trading-supported).
            // Neither is this script's to configure, but a wrapper with neither is a dead end, and
            // that is worth saying out loud rather than discovering with funds parked.
            bool bridgeable = factory.isTokenSupported(a.wrapper);
            bool redirectable = tsFactory != address(0) && ITradingSafeFactory(tsFactory).isSupportedToken(a.wrapper);
            console.log(string.concat("  ", a.symbol, " wrapper onward: bridge="), bridgeable, " redirect=", redirectable);
            if (!bridgeable && !redirectable) {
                console.log("WARNING: neither rail carries this wrapper; wrapped balances will sit at the TopUp:", a.symbol, a.wrapper);
            }
        }
    }
}
