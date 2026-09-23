// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { IOracleSinkAdminLike, IRoleRegistryLike, ZchfProd as C } from "./ZchfProdConfig.sol";

/**
 * @title ConfigureZchfSinkOP3CP
 * @notice Generates the OPERATING SAFE (0xA6cf…AAC4) Optimism bundle that opens the OracleSink for
 *         the relayed ZCHF price — the OP half of the PAXG setup from 3CP 622 (tx 10):
 *
 *           1. OracleSink.setMaxStaleness(ZCHF, 7 days) — a zero window serves no price at all;
 *              7 days is the fixed sink window (LendRails.ORACLE_SINK_MAX_STALENESS), the Aave
 *              feed above it enforces the tighter 3-day relay bound
 *
 *         Keyed by MAINNET ZCHF (0xB58E…21cB), the address the relay subscribes. Deliberately no
 *         cash-side call (PriceProviderV2 / DebtManager / CashModule): this rollout lists ZCHF on
 *         Summer Lend only. Independent of the Ethereum bundle; the relay keeper delivers the first
 *         price once both have executed.
 *
 * Usage:
 *   forge script scripts/zchf/ConfigureZchfSinkOP3CP.s.sol --rpc-url $OPTIMISM_RPC
 */
contract ConfigureZchfSinkOP3CP is GnosisHelpers, Utils, Test {
    string constant OUTPUT_PATH = "./output/ConfigureZchfSinkOP3CP-10.json";

    function run() public {
        require(block.chainid == 10, "must be Optimism");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        IOracleSinkAdminLike sink = IOracleSinkAdminLike(C.ORACLE_SINK);
        IRoleRegistryLike registry = IRoleRegistryLike(sink.roleRegistry());
        require(registry.hasRole(sink.ORACLE_SINK_ADMIN_ROLE(), C.OPERATING_SAFE), "Operating Safe lacks ORACLE_SINK_ADMIN_ROLE");
        require(sink.decimals() == 6, "OracleSink is not 6 decimals");
        require(sink.maxStaleness(C.ZCHF_MAINNET) == 0, "ZCHF sink window already set");

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(C.OPERATING_SAFE));
        txs = _append(txs, C.ORACLE_SINK, abi.encodeCall(IOracleSinkAdminLike.setMaxStaleness, (C.ZCHF_MAINNET, C.ORACLE_SINK_MAX_STALENESS)), true);
        vm.createDir("./output", true);
        vm.writeFile(OUTPUT_PATH, txs);
        console.log("Written: %s", OUTPUT_PATH);

        executeGnosisTransactionBundle(OUTPUT_PATH);

        assertEq(uint256(sink.maxStaleness(C.ZCHF_MAINNET)), uint256(C.ORACLE_SINK_MAX_STALENESS), "sink window");
        (bool hasPrice,) = C.ORACLE_SINK.staticcall(abi.encodeCall(IOracleSinkAdminLike.latestRoundData, (C.ZCHF_MAINNET)));
        console.log(hasPrice ? "Simulation passed. The sink already holds a ZCHF price." : "Simulation passed. No ZCHF price on the sink yet: the relay keeper must poke before the Aave feed can price.");
    }

    function _append(string memory txs, address to, bytes memory data, bool isLast) internal pure returns (string memory) {
        return string.concat(txs, _getGnosisTransaction(addressToHex(to), iToHex(data), "0", isLast));
    }
}
