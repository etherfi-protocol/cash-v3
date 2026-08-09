// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { IPriceRelayLike, IRelayPriceProviderLike, ITradingLensLike, WspyxPaxgProd as C } from "./WspyxPaxgProdConfig.sol";

/**
 * @title RemovePaxgWspyxEthereum3CP
 * @notice Generates the OPERATING SAFE (0xA6cf…AAC4) Ethereum bundle that retires the PAXG relay
 *         leg and drops both listing assets from the trading-account registry:
 *
 *           1. PriceRelay.unsubscribe(PAXG)               — the keeper's poke stops shipping PAXG
 *           2. RelayPriceProvider.removeTokenConfig(PAXG) — the relay price source is deleted
 *           3. TradingLens.removeSupportedToken(wSPYx)    — no longer a trading-account asset
 *           4. TradingLens.removeSupportedToken(PAXG)     — no longer a trading-account asset
 *
 *         The wSPYx relay entry is deliberately untouched: the iwSPYx price on Optimism (cash
 *         PriceProviderV2 and the Summer Lend OracleSinkPriceFeed) is the relayed wSPYx -> SPYx
 *         rate, so wSPYx must stay subscribed with its RelayPriceProvider config intact.
 *
 *         EXECUTION ORDER: strictly after the Operating Safe OP bundle
 *         (ConfigureWspyxPaxgCashOP3CP). Until iPAXG is repointed to the native Chainlink feed,
 *         unsubscribing here would let the OP sink entry go stale and brick iPAXG pricing.
 *
 * Usage:
 *   forge script scripts/wspyx-paxg/RemovePaxgWspyxEthereum3CP.s.sol --rpc-url $MAINNET_RPC
 */
contract RemovePaxgWspyxEthereum3CP is GnosisHelpers, Utils, Test {
    string constant OUTPUT_PATH = "./output/RemovePaxgWspyxEthereum3CP-1.json";

    function run() public {
        require(block.chainid == 1, "must be Ethereum");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        ITradingLensLike lens = ITradingLensLike(stdJson.readAddress(vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/1/trading-account.json")), ".TradingLens"));

        // Pre-state sanity: everything being removed is present, and wSPYx currently relays
        require(_isSubscribed(C.PAXG_MAINNET), "PAXG not subscribed on the PriceRelay");
        require(_isSubscribed(C.WSPYX_MAINNET), "wSPYx expected subscribed on the PriceRelay");
        require(lens.isSupportedToken(C.WSPYX_MAINNET), "wSPYx not on the TradingLens");
        require(lens.isSupportedToken(C.PAXG_MAINNET), "PAXG not on the TradingLens");
        uint256 wspyxRateBefore = IRelayPriceProviderLike(C.RELAY_PRICE_PROVIDER).price(C.WSPYX_MAINNET);

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(C.OPERATING_SAFE));
        txs = _append(txs, C.PRICE_RELAY, abi.encodeCall(IPriceRelayLike.unsubscribe, (C.PAXG_MAINNET)), false);
        txs = _append(txs, C.RELAY_PRICE_PROVIDER, abi.encodeCall(IRelayPriceProviderLike.removeTokenConfig, (C.PAXG_MAINNET)), false);
        txs = _append(txs, address(lens), abi.encodeCall(ITradingLensLike.removeSupportedToken, (C.WSPYX_MAINNET)), false);
        txs = _append(txs, address(lens), abi.encodeCall(ITradingLensLike.removeSupportedToken, (C.PAXG_MAINNET)), true);

        vm.createDir("./output", true);
        vm.writeFile(OUTPUT_PATH, txs);
        console.log("Written: %s", OUTPUT_PATH);

        executeGnosisTransactionBundle(OUTPUT_PATH);

        // Post-state: PAXG fully retired on the ETH side, the wSPYx relay leg untouched
        assertFalse(_isSubscribed(C.PAXG_MAINNET), "PAXG still subscribed");
        assertTrue(_isSubscribed(C.WSPYX_MAINNET), "wSPYx must stay subscribed");
        (bool ok,) = C.RELAY_PRICE_PROVIDER.staticcall(abi.encodeCall(IRelayPriceProviderLike.price, (C.PAXG_MAINNET)));
        assertFalse(ok, "relay provider still prices PAXG");
        assertEq(IRelayPriceProviderLike(C.RELAY_PRICE_PROVIDER).price(C.WSPYX_MAINNET), wspyxRateBefore, "wSPYx relay source changed");
        assertFalse(lens.isSupportedToken(C.WSPYX_MAINNET), "wSPYx still on the TradingLens");
        assertFalse(lens.isSupportedToken(C.PAXG_MAINNET), "PAXG still on the TradingLens");

        console.log("Simulation passed. PAXG relay leg retired; wSPYx rate still relaying at %s (6 decimals).", wspyxRateBefore);
    }

    function _isSubscribed(address token) internal view returns (bool) {
        address[] memory subscribed = IPriceRelayLike(C.PRICE_RELAY).subscribedTokens();
        for (uint256 i; i < subscribed.length; ++i) {
            if (subscribed[i] == token) return true;
        }
        return false;
    }

    function _append(string memory txs, address to, bytes memory data, bool isLast) internal pure returns (string memory) {
        return string.concat(txs, _getGnosisTransaction(addressToHex(to), iToHex(data), "0", isLast));
    }
}
