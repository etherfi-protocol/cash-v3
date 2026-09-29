// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { IPriceRelayLike, IRoleRegistryAwareLike, IRoleRegistryLike, ZchfProd as C } from "./ZchfProdConfig.sol";

/**
 * @title ConfigureZchfRelayEthereum3CP
 * @notice Generates the OPERATING SAFE (0xA6cf…AAC4) Ethereum bundle that starts relaying the ZCHF
 *         price to Optimism — the ETH half of the PAXG setup from 3CP 621 (tx 9 + 11), nothing else
 *         (no OFT: ZCHF is a native OP token, no top-up rail):
 *
 *           1. RelayPriceProvider.setTokenConfig([ZCHF], …) — Chainlink CHF / USD, 8 decimals,
 *              26h bound (24h heartbeat + buffer), direct (no base asset), NOT a stable snap
 *           2. PriceRelay.subscribe(ZCHF)                    — the keeper's poke ships it
 *
 *         Keyed by MAINNET ZCHF (0xB58E…21cB): the relay ships mainnet token addresses, the sink
 *         and the Aave feed on OP read the same key. Executes FIRST; the OP sink window
 *         (ConfigureZchfSinkOP3CP) can go out at the same time.
 *
 * Usage:
 *   forge script scripts/zchf/ConfigureZchfRelayEthereum3CP.s.sol --rpc-url $MAINNET_RPC
 */
contract ConfigureZchfRelayEthereum3CP is GnosisHelpers, Utils, Test {
    string constant OUTPUT_PATH = "./output/ConfigureZchfRelayEthereum3CP-1.json";

    function run() public {
        require(block.chainid == 1, "must be Ethereum");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        PriceProviderV2 pp = PriceProviderV2(C.RELAY_PRICE_PROVIDER);
        IPriceRelayLike relay = IPriceRelayLike(C.PRICE_RELAY);
        IAggregatorV3 aggregator = IAggregatorV3(C.CHF_USD_AGGREGATOR);

        // Roles: read off the contracts, then checked on the registry they point at
        IRoleRegistryLike registry = IRoleRegistryLike(IRoleRegistryAwareLike(address(pp)).roleRegistry());
        require(address(registry) == relay.roleRegistry(), "provider and relay disagree on the RoleRegistry");
        require(registry.hasRole(pp.PRICE_PROVIDER_ADMIN_ROLE(), C.OPERATING_SAFE), "Operating Safe lacks PRICE_PROVIDER_ADMIN_ROLE");
        require(registry.hasRole(relay.PRICE_RELAY_ADMIN_ROLE(), C.OPERATING_SAFE), "Operating Safe lacks PRICE_RELAY_ADMIN_ROLE");

        // Pre-state: nothing ZCHF-shaped on the relay yet, and the source is alive
        require(pp.tokenConfig(C.ZCHF_MAINNET).oracle == address(0), "ZCHF already has a relay price source");
        require(!_isSubscribed(C.ZCHF_MAINNET), "ZCHF already subscribed on the PriceRelay");
        require(aggregator.decimals() == 8, "CHF / USD aggregator is not 8 decimals");
        (, int256 answer,, uint256 updatedAt,) = aggregator.latestRoundData();
        require(answer > 0, "CHF / USD aggregator dead");
        require(block.timestamp - updatedAt <= C.CHF_USD_RELAY_MAX_STALENESS, "CHF / USD aggregator stale against the relay bound");

        _writeBundle(pp);
        console.log("Written: %s", OUTPUT_PATH);

        executeGnosisTransactionBundle(OUTPUT_PATH);

        // Post-state: stored config field by field, subscription, and the 6-decimal relayed price
        PriceProviderV2.Config memory config = pp.tokenConfig(C.ZCHF_MAINNET);
        assertEq(config.oracle, C.CHF_USD_AGGREGATOR, "oracle");
        assertEq(config.priceFunctionCalldata.length, 0, "priceFunctionCalldata");
        assertTrue(config.isChainlinkType, "isChainlinkType");
        assertEq(uint256(config.oraclePriceDecimals), 8, "oraclePriceDecimals");
        assertEq(uint256(config.maxStaleness), C.CHF_USD_RELAY_MAX_STALENESS, "maxStaleness");
        assertEq(uint256(config.dataType), uint256(PriceProviderV2.ReturnType.Int256), "dataType");
        assertFalse(config.isStableToken, "isStableToken must be false: CHF is not USD");
        assertEq(config.baseAsset, address(0), "baseAsset");
        assertTrue(_isSubscribed(C.ZCHF_MAINNET), "ZCHF not subscribed");
        uint256 relayed = pp.price(C.ZCHF_MAINNET);
        assertApproxEqAbs(relayed, uint256(answer) / 1e2, 1, "relayed price is not CHF / USD at 6 decimals");

        console.log("Simulation passed. ZCHF relay source live: CHF / USD %s (6 decimals)", relayed);
    }

    function _writeBundle(PriceProviderV2 pp) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = C.ZCHF_MAINNET;
        PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](1);
        configs[0] = PriceProviderV2.Config({
            oracle: C.CHF_USD_AGGREGATOR,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: C.CHF_USD_RELAY_MAX_STALENESS,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(C.OPERATING_SAFE));
        txs = _append(txs, address(pp), abi.encodeWithSelector(PriceProviderV2.setTokenConfig.selector, tokens, configs), false);
        txs = _append(txs, C.PRICE_RELAY, abi.encodeCall(IPriceRelayLike.subscribe, (C.ZCHF_MAINNET)), true);

        vm.createDir("./output", true);
        vm.writeFile(OUTPUT_PATH, txs);
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
