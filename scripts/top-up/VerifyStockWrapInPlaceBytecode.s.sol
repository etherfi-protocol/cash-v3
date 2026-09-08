// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { BeaconFactory } from "../../src/beacon-factory/BeaconFactory.sol";
import { TopUp } from "../../src/top-up/TopUp.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { TopUpV2 } from "../../src/top-up/TopUpV2.sol";
import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { StockWrapInPlaceProdConfig } from "./StockWrapInPlaceProdConfig.sol";

/**
 * @title VerifyStockWrapInPlaceBytecode
 * @author ether.fi
 * @notice Proves the two implementations the wrap-in-place 3CP upgrades to are the code in THIS
 *         repo at THIS commit. Reverts on mismatch, so it can gate the bundle.
 *
 *         Highest-stakes check in the rollout, for the same reason as its redirect-wrapping
 *         predecessor: the beacon impl is shared by every live prod TopUp proxy, and the factory
 *         impl holds every TopUp's funds-movement authority. Nothing about the deploy commits to
 *         initcode, so a broadcast from a stale branch would pass every address check — and here a
 *         stale branch is the specific hazard, because the bundle's two configuration calls
 *         (`removeTokenConfig`, `wrapStocks`'s prerequisites) exist ONLY on this generation. An
 *         impl without `removeTokenConfig` would take the whole Safe transaction down; one without
 *         `TopUp.wrap` would leave the stocks retired and unwrappable.
 *
 * @dev Both comparisons tolerate embedded addresses. `TopUpV2` bakes its constructor args (`weth`,
 *      `DISPATCHER`) into runtime code as immutables — which is what makes the comparison valuable,
 *      since it proves the impl was built with OUR dispatcher and not merely from the same source —
 *      and `TopUpFactory` is a UUPS implementation, so it embeds its own deploy address (`__self`).
 *      A plain byte compare would reject a CORRECT deployment of either.
 *
 * @dev THERE IS NO MANIFEST FILE. The pinned constants plus the chain are the only sources of truth.
 *      The constructor arguments are cross-checked against what the LIVE beacon impl runs rather
 *      than against a hand-written record, which is strictly stronger: a manifest can be edited to
 *      agree with a wrong constant, the live beacon cannot.
 *
 * Env: ENV=mainnet
 *
 * Run: ENV=mainnet forge script scripts/top-up/VerifyStockWrapInPlaceBytecode.s.sol --rpc-url $MAINNET_RPC -vv
 */
contract VerifyStockWrapInPlaceBytecode is StockWrapInPlaceProdConfig, ContractCodeChecker {
    using stdJson for string;

    function run() public {
        require(block.chainid == 1, "must run on Ethereum (1)");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        address factoryImpl = WRAP_IN_PLACE_FACTORY_IMPL;
        address topUpImpl = WRAP_IN_PLACE_TOPUP_IMPL;
        require(factoryImpl != address(0) && topUpImpl != address(0), "impls not pinned in StockWrapInPlaceProdConfig - run DeployProdStockWrapInPlaceEth first");
        require(factoryImpl.code.length > 0 && topUpImpl.code.length > 0, "a pinned impl has no code on this chain");
        require(factoryImpl != topUpImpl, "the two pinned implementations are the same address");

        // The constructor arguments, checked against the deployment they are about to serve rather
        // than against a written-down copy of themselves. A plain `TopUp` on the beacon has no
        // DISPATCHER to compare, which is a valid pre-state and not a mismatch.
        address beacon = BeaconFactory(readTopUpSourceDeployment().readAddress(".addresses.TopUpSourceFactory")).beacon();
        address liveTopUpImpl = UpgradeableBeacon(beacon).implementation();
        require(TopUp(payable(liveTopUpImpl)).weth() == WETH, "WETH constant disagrees with the live beacon impl");
        (bool ok, bytes memory ret) = liveTopUpImpl.staticcall(abi.encodeWithSignature("DISPATCHER()"));
        require(!ok || ret.length != 32 || abi.decode(ret, (address)) == RECOVERY_DISPATCHER, "RECOVERY_DISPATCHER constant disagrees with the live beacon impl");

        console.log("TopUpFactory impl :", factoryImpl);
        console.log("TopUpV2 impl      :", topUpImpl);
        console.log("  weth            :", WETH);
        console.log("  dispatcher      :", RECOVERY_DISPATCHER);
        console.log("live beacon impl  :", liveTopUpImpl);

        requireCodeMatchAllowingAddressEmbeds("TopUpFactoryImpl", factoryImpl, address(new TopUpFactory()));
        requireCodeMatchAllowingAddressEmbeds("TopUpV2Impl", topUpImpl, address(new TopUpV2(WETH, RECOVERY_DISPATCHER)));

        // Immutables are the reason the V2 comparison is meaningful; assert them directly too.
        require(TopUpV2(payable(topUpImpl)).DISPATCHER() == RECOVERY_DISPATCHER, "TopUpV2 DISPATCHER mismatch");
        require(TopUpV2(payable(topUpImpl)).weth() == WETH, "TopUpV2 weth mismatch");
        console.log("  [OK] immutables verified: weth + DISPATCHER");

        console.log("");
        console.log("VerifyStockWrapInPlaceBytecode: all bytecode checks passed");
    }
}
