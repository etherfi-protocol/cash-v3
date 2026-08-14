// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { TopUpV2 } from "../../src/top-up/TopUpV2.sol";
import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { StockWrapProdConfig } from "./StockWrapProdConfig.sol";

/**
 * @title VerifyStockWrapBytecode
 * @author ether.fi
 * @notice Proves the two implementations the Ethereum prod stock-wrap 3CP upgrades to are the code
 *         in THIS repo at THIS commit. Reverts on mismatch, so it can gate the bundle.
 *
 *         This is the highest-stakes bytecode check in the rollout: the beacon impl is shared by
 *         83,000+ live prod TopUp proxies, and the factory impl is the contract that holds every
 *         TopUp's funds-movement authority. CREATE3 proves WHO deployed but not WHAT — it does not
 *         commit to initcode — so a broadcast from a stale branch would pass every address check.
 *
 * @dev `TopUpV2` is compared with `requireCodeMatchAllowingAddressEmbeds` because its constructor
 *      args (`weth`, `DISPATCHER`) bake into runtime code as immutables — which is exactly what
 *      makes the comparison valuable: it proves the deployed impl was built with OUR dispatcher,
 *      not merely that it shares source. The immutables are additionally read back directly.
 *      `TopUpFactory` is a UUPS implementation, so it embeds its own deploy address (`__self`) and
 *      needs the same tolerant compare; a plain byte compare would reject a CORRECT deployment.
 *
 * @dev The two comparators used here are additions to the shared `ContractCodeChecker`, whose
 *      original `verifyContractByteCodeMatch` only console.logs Success/Fail. A verification script
 *      has to REVERT to be a gate, and neither of these implementations can pass a plain compare.
 *
 * Env: ENV=mainnet
 *
 * Run: ENV=mainnet forge script scripts/top-up/VerifyStockWrapBytecode.s.sol --rpc-url $MAINNET_RPC -vv
 */
contract VerifyStockWrapBytecode is StockWrapProdConfig, ContractCodeChecker {
    function run() public {
        require(block.chainid == 1, "must run on Ethereum (1)");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        address factoryImpl = TOPUP_FACTORY_IMPL;
        address topUpV2Impl = TOPUP_V2_IMPL;

        console.log("TopUpFactory impl :", factoryImpl);
        console.log("TopUpV2 impl      :", topUpV2Impl);
        console.log("  weth            :", WETH);
        console.log("  dispatcher      :", RECOVERY_DISPATCHER);

        requireCodeMatchAllowingAddressEmbeds("TopUpFactoryImpl", factoryImpl, address(new TopUpFactory()));
        requireCodeMatchAllowingAddressEmbeds("TopUpV2Impl", topUpV2Impl, address(new TopUpV2(WETH, RECOVERY_DISPATCHER)));

        // Immutables are the reason the V2 comparison is meaningful; assert them directly too.
        require(TopUpV2(payable(topUpV2Impl)).DISPATCHER() == RECOVERY_DISPATCHER, "TopUpV2 DISPATCHER mismatch");
        require(TopUpV2(payable(topUpV2Impl)).weth() == WETH, "TopUpV2 weth mismatch");
        console.log("  [OK] immutables verified: weth + DISPATCHER");

        console.log("");
        console.log("VerifyStockWrapBytecode: all bytecode checks passed");
    }
}
