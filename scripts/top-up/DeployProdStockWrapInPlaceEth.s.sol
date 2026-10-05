// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { BeaconFactory } from "../../src/beacon-factory/BeaconFactory.sol";
import { TopUp } from "../../src/top-up/TopUp.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { TopUpV2 } from "../../src/top-up/TopUpV2.sol";
import { StockWrapInPlaceProdConfig } from "./StockWrapInPlaceProdConfig.sol";

/**
 * @title DeployProdStockWrapInPlaceEth
 * @author ether.fi
 * @notice Deploys the two Ethereum **prod** implementations the wrap-in-place rollout needs, and
 *         nothing else: a `TopUpFactory` impl carrying `removeTokenConfig` + `wrapStocks`, and a
 *         `TopUpV2` impl carrying `TopUp.wrap` for the beacon.
 *
 *         Both are plain implementation contracts — no proxy, no state, no privileged call — so
 *         this script is completely unprivileged and can be broadcast by any funded EOA. The
 *         privileged calls that switch prod over live in
 *         scripts/gnosis-txs/StockWrapInPlaceEth3CP.s.sol; on prod the RoleRegistry owner is the
 *         Safe, not this EOA.
 *
 * @dev THE CONSTRUCTOR ARGUMENTS ARE READ OFF THE LIVE BEACON, NOT ASSUMED. `TopUpV2`'s `weth` and
 *      `DISPATCHER` are immutables baked into runtime code, so getting either wrong would ship a
 *      beacon impl that silently loses the recovery path (or wraps the wrong native token) on
 *      83,000+ proxies. The pinned constants are cross-checked against what the beacon currently
 *      points at before anything is deployed, and read back from the new impl afterwards.
 *
 * @dev The Ethereum beacon is expected to already run `TopUpV2` (3CP-649 put it there). If it still
 *      runs plain `TopUp`, this script says so and proceeds with V2 anyway — same decision 3CP-649
 *      made, for the same reason: the slot has to be replaced for the wrap behaviour regardless, and
 *      V2 is `TopUp` + the dispatcher-gated `executeRecovery`.
 *
 * Env: PRIVATE_KEY, ENV=mainnet
 *      SKIP_TOPUP_IMPL=true / SKIP_FACTORY_IMPL=true — reuse the pinned impl instead of deploying
 *      that half. Use when only one contract drifted: re-shipping both moves an address that has
 *      already been bytecode-reviewed and forces the 3CP hashes to be regenerated for nothing.
 *
 * Usage (simulate by dropping --broadcast):
 *   source .env && ENV=mainnet forge script \
 *     scripts/top-up/DeployProdStockWrapInPlaceEth.s.sol:DeployProdStockWrapInPlaceEth \
 *     --rpc-url $MAINNET_RPC --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvv
 *
 * After broadcast: pin the two addresses in StockWrapInPlaceProdConfig.sol, then
 *   ENV=mainnet forge script scripts/top-up/VerifyStockWrapInPlaceBytecode.s.sol --rpc-url $MAINNET_RPC -vv
 *   forge script scripts/gnosis-txs/StockWrapInPlaceEth3CP.s.sol --rpc-url $MAINNET_RPC
 */
contract DeployProdStockWrapInPlaceEth is StockWrapInPlaceProdConfig {
    using stdJson for string;

    function run() public {
        require(block.chainid == 1, "must run on Ethereum (1)");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        require(WETH.code.length > 0, "WETH has no code on this chain");
        require(RECOVERY_DISPATCHER.code.length > 0, "AssetRecoveryDispatcher has no code on this chain");

        string memory deployments = readTopUpSourceDeployment();
        TopUpFactory factory = TopUpFactory(payable(deployments.readAddress(".addresses.TopUpSourceFactory")));
        IRoleRegistry roleRegistry = IRoleRegistry(deployments.readAddress(".addresses.RoleRegistry"));
        require(address(factory.roleRegistry()) == address(roleRegistry), "factory reads a different RoleRegistry than deployments.json records");

        // The live beacon is the authority on the two immutables — see the notice above.
        address beacon = BeaconFactory(address(factory)).beacon();
        address liveTopUpImpl = UpgradeableBeacon(beacon).implementation();
        require(TopUp(payable(liveTopUpImpl)).weth() == WETH, "live beacon impl points at a different WETH than the pinned constant");

        address liveDispatcher = _dispatcherOf(liveTopUpImpl);
        if (liveDispatcher == address(0)) {
            console.log("NOTE: the live beacon impl is plain TopUp (no DISPATCHER); shipping TopUpV2, as 3CP-649 does.");
        } else {
            require(liveDispatcher == RECOVERY_DISPATCHER, "live beacon impl has a DIFFERENT dispatcher than the pinned constant - do not deploy");
        }

        address ownerBefore = roleRegistry.owner();

        // Either impl can be redeployed on its own: source drift in `TopUpFactory` does not touch
        // `TopUpV2` (it only imports the unchanged `ITopUpFactory` interface), so re-shipping the
        // factory should not move the beacon impl and force a second bytecode review.
        bool skipTopUp = vm.envOr("SKIP_TOPUP_IMPL", false);
        bool skipFactory = vm.envOr("SKIP_FACTORY_IMPL", false);
        require(!skipTopUp || !skipFactory, "both impls skipped - nothing to deploy");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address factoryImpl = skipFactory ? WRAP_IN_PLACE_FACTORY_IMPL : address(new TopUpFactory());
        address topUpImpl = skipTopUp ? WRAP_IN_PLACE_TOPUP_IMPL : address(new TopUpV2(WETH, RECOVERY_DISPATCHER));
        vm.stopBroadcast();

        if (skipFactory) require(factoryImpl.code.length > 0, "SKIP_FACTORY_IMPL set but the pinned impl has no code");
        if (skipTopUp) require(topUpImpl.code.length > 0, "SKIP_TOPUP_IMPL set but the pinned impl has no code");
        require(factoryImpl != topUpImpl, "the two implementations are the same address");

        // Read the immutables back off the deployed code — they are the reason V2 needs its own
        // deploy per chain, and they cannot be changed afterwards.
        require(TopUpV2(payable(topUpImpl)).DISPATCHER() == RECOVERY_DISPATCHER, "VERIFY FAILED: DISPATCHER mismatch");
        require(TopUpV2(payable(topUpImpl)).weth() == WETH, "VERIFY FAILED: weth mismatch");

        // Cheap identity checks only. That these impls actually CARRY `wrapStocks` /
        // `removeTokenConfig` / `wrap` — i.e. that the broadcast did not come off a stale branch —
        // is proven by VerifyStockWrapInPlaceBytecode, which compares the deployed runtime code
        // against this repo at this commit. Probing individual selectors here would be weaker.
        require(TopUpFactory(payable(factoryImpl)).MAX_ALLOWED_SLIPPAGE() > 0, "VERIFY FAILED: factory impl does not look like a TopUpFactory");
        require(TopUpFactory(payable(factoryImpl)).wrapperFor(address(0)) == address(0), "VERIFY FAILED: factory impl predates redirect wrapping");

        // Deploying an implementation must not touch governance.
        require(roleRegistry.owner() == ownerBefore, "CRITICAL: role registry owner changed!");

        console.log("TopUpFactory impl :", factoryImpl);
        console.log("TopUpV2 impl      :", topUpImpl);
        console.log("  weth            :", WETH);
        console.log("  dispatcher      :", RECOVERY_DISPATCHER);
        console.log("beacon            :", beacon);
        console.log("  current impl    :", liveTopUpImpl);

        if (factoryImpl != WRAP_IN_PLACE_FACTORY_IMPL || topUpImpl != WRAP_IN_PLACE_TOPUP_IMPL) {
            console.log("");
            console.log("ACTION REQUIRED: pin these in scripts/top-up/StockWrapInPlaceProdConfig.sol");
            console.log("  WRAP_IN_PLACE_FACTORY_IMPL =", factoryImpl);
            console.log("  WRAP_IN_PLACE_TOPUP_IMPL   =", topUpImpl);
            console.log("Those constants are the whole record - the verifier and the 3CP generator");
            console.log("read them and re-derive everything else from the chain. No manifest file.");
        }

        console.log("");
        console.log("Next: ENV=mainnet forge script scripts/top-up/VerifyStockWrapInPlaceBytecode.s.sol --rpc-url $MAINNET_RPC -vv");
        console.log("Then: forge script scripts/gnosis-txs/StockWrapInPlaceEth3CP.s.sol --rpc-url $MAINNET_RPC");
    }

    /// @dev The impl's recovery dispatcher, or zero when it is a plain `TopUp`. `TopUp` has no
    ///      fallback, so the staticcall reverts rather than returning garbage.
    function _dispatcherOf(address topUpImpl) internal view returns (address) {
        (bool ok, bytes memory ret) = topUpImpl.staticcall(abi.encodeWithSignature("DISPATCHER()"));
        if (!ok || ret.length != 32) return address(0);
        return abi.decode(ret, (address));
    }
}
