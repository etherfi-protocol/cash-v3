// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { StockTopupConfig } from "./StockTopupConfig.sol";
import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { StockOFTBridgeAdapter } from "../../src/top-up/bridge/StockOFTBridgeAdapter.sol";

/**
 * @title VerifyStockTopupBytecode
 * @author ether.fi
 * @notice Proves the `StockOFTBridgeAdapter` running at its CREATE3 address is the code in THIS
 *         repo at THIS commit. Reverts on mismatch, so it can gate the token-config bundle.
 *
 *         CREATE3 addresses prove WHO deployed but not WHAT — they do not commit to initcode — so
 *         address checks alone would pass a broadcast made from a stale branch. This redeploys the
 *         adapter locally from current source and compares runtime bytecode through
 *         `ContractCodeChecker`.
 *
 * @dev Exact match is the right bar here: the adapter is stateless, unowned and constructor-less
 *      (only ever delegatecalled by `TopUpFactory.bridge()`), so it embeds no addresses — no proxy
 *      self-reference, no linked libraries. Registering a wrong-code adapter would be executed in
 *      the FACTORY's context with the factory's balances and approvals, which is why this is worth
 *      a separate gate rather than trusting the explorer.
 *
 * Env: ENV (dev|mainnet)
 *
 * Run: ENV=mainnet forge script scripts/stock-topup/VerifyStockTopupBytecode.s.sol --rpc-url $MAINNET_RPC -vv
 */
contract VerifyStockTopupBytecode is StockTopupConfig, ContractCodeChecker {
    using stdJson for string;

    function run() public {
        require(block.chainid == 1, "This script must be run on Ethereum mainnet (chain ID 1)");

        address adapter = _adapterAddress();
        console.log("ENV:", getEnv());
        console.log("StockOFTBridgeAdapter:", adapter);

        requireExactCodeMatch("StockOFTBridgeAdapter", adapter, address(new StockOFTBridgeAdapter()));

        // The manifest must agree with the deterministic address: a divergence means a stale or
        // hand-edited record, and every other script reads the manifest.
        string memory deployments = vm.readFile(_ethereumDeploymentPath());
        if (vm.keyExistsJson(deployments, string.concat(".addresses.", ADAPTER_DEPLOYMENT_KEY))) {
            require(deployments.readAddress(string.concat(".addresses.", ADAPTER_DEPLOYMENT_KEY)) == adapter, "recorded adapter != predicted CREATE3 address");
            console.log("  [OK] deployments.json agrees with the CREATE3 address");
        } else {
            console.log("  [WARN] adapter not recorded in", _ethereumDeploymentPath());
        }

        console.log("");
        console.log("VerifyStockTopupBytecode: bytecode check passed");
    }
}
