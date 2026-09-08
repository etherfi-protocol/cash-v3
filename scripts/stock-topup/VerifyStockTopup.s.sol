// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { StockTopupConfig } from "./StockTopupConfig.sol";

/**
 * @title VerifyStockTopup
 * @notice Post-deployment verification for the Ethereum stock topup rail. Read-only against
 *         the live chain, REVERTS on any mismatch (non-zero exit for CI/wrappers). Run after
 *         the deploy broadcast and, on prod, after the Safe has executed the wiring bundle.
 *
 * Env: ENV (dev|mainnet)
 *
 * Run: ENV=mainnet forge script scripts/stock-topup/VerifyStockTopup.s.sol --rpc-url $MAINNET_RPC
 */
contract VerifyStockTopup is StockTopupConfig {
    using stdJson for string;

    function run() public view {
        require(block.chainid == 1, "This script must be run on Ethereum mainnet (chain ID 1)");

        _assertAssetWiring();

        string memory deployments = vm.readFile(_ethereumDeploymentPath());
        TopUpFactory factory = TopUpFactory(payable(deployments.readAddress(".addresses.TopUpSourceFactory")));

        // The adapter must live at its deterministic CREATE3 address, and the manifest must
        // agree with it (a divergence means a hijacked or stale record).
        address adapter = _adapterAddress();
        require(adapter.code.length > 0, "StockOFTBridgeAdapter not deployed");
        require(deployments.readAddress(string.concat(".addresses.", ADAPTER_DEPLOYMENT_KEY)) == adapter, "recorded adapter != predicted CREATE3 address");

        address recipient = _topUpDestOptimism();
        StockTopupAsset[] memory assets = _assets();

        console.log("ENV:", getEnv());
        console.log("StockOFTBridgeAdapter:", adapter);
        console.log("recipientOnDestChain (OP TopUpDest):", recipient);

        for (uint256 i = 0; i < assets.length; i++) {
            StockTopupAsset memory a = assets[i];

            TopUpFactory.TokenConfig memory stored = factory.getTokenConfig(a.stock, OP_CHAIN_ID);
            require(stored.bridgeAdapter == adapter, string.concat(a.symbol, ": bridgeAdapter mismatch"));
            require(stored.recipientOnDestChain == recipient, string.concat(a.symbol, ": recipientOnDestChain is not the OP TopUpDest"));
            require(stored.maxSlippageInBps == MAX_SLIPPAGE_BPS, string.concat(a.symbol, ": maxSlippageInBps mismatch"));
            require(keccak256(stored.additionalData) == keccak256(_additionalData(a.oftAdapter)), string.concat(a.symbol, ": additionalData mismatch"));

            // Decode the stored payload the way the adapter does, so a silently re-encoded
            // config (right bytes length, wrong values) still fails here.
            (address oftAdapter, uint32 destEid, uint128 lzReceiveGas) = abi.decode(stored.additionalData, (address, uint32, uint128));
            require(oftAdapter == a.oftAdapter, string.concat(a.symbol, ": oftAdapter mismatch"));
            require(destEid == OP_EID, string.concat(a.symbol, ": destEid mismatch"));
            require(lzReceiveGas == LZ_RECEIVE_GAS, string.concat(a.symbol, ": lzReceiveGas mismatch"));

            // The route must be quotable at the live executor config — the failure mode that
            // empty options / zero slippage produce shows up here, not in storage.
            (, uint256 fee) = factory.getBridgeFee(a.stock, 10 ** 18, OP_CHAIN_ID);
            require(fee > 0, string.concat(a.symbol, ": bridge fee quoted as zero"));

            console.log(string.concat("  [OK] ", a.symbol, " -> OP. Quote for 1e18:"), fee, "wei");
        }
    }
}
