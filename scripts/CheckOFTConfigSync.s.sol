// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UlnConfig } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import { ILayerZeroEndpointV2 } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { IOFTConfigRegistry } from "../src/interfaces/IOFTConfigRegistry.sol";

import { Utils } from "./utils/Utils.sol";

/// @dev Minimal view of the bridge's endpoint getter (OAppCoreUpgradeable's public immutable).
interface IBridgeEndpoint {
    function endpoint() external view returns (address);
}

/**
 * @title CheckOFTConfigSync
 * @author ether.fi
 * @notice Read-only staleness check: for every registered bridge x active destination, compares
 *         the ULN config actually applied on the LayerZero endpoint against the registry's
 *         canonical {IOFTConfigRegistry.getPathwayConfig}. The bridges keep no per-proxy sync
 *         state (see {ConfigurableOFTBase}), and the registry's `version` is a single global
 *         counter that bumps on ANY pathway edit — so a version number can't tell you whether a
 *         specific bridge x dstEid is current. The endpoint rows are the only source of truth.
 * @dev View-only: no broadcast, no PRIVATE_KEY. Run PER CHAIN (registry, bridges, and endpoint
 *      are all per-chain). Set REVERT_IF_STALE=true to make the run exit nonzero when anything is
 *      stale (CI gate); default just logs. Mirrors {ConfigurableOFTBase.syncConfig}: only the ULN
 *      config (configType 2) on the canonical send/receive libs is validated — library SELECTION
 *      (setSendLibrary/setReceiveLibrary) is a separate concern and out of scope.
 *
 *        forge script scripts/CheckOFTConfigSync.s.sol --rpc-url mainnet
 *        forge script scripts/CheckOFTConfigSync.s.sol --rpc-url optimism
 */
contract CheckOFTConfigSync is Utils {
    /// @dev LayerZero ULN config type id, matching ConfigurableOFTBase.
    uint32 constant CONFIG_TYPE_ULN = 2;

    /// @dev Result of evaluating one (bridge, dstEid): whether the endpoint rows read, whether the
    ///      applied config matches canonical, and the configs themselves for field-level diff logging.
    struct PathwayEval {
        bool readOk;
        bool inSync;
        UlnConfig want;
        UlnConfig sendCfg;
        UlnConfig recvCfg;
    }

    function run() public view {
        IOFTConfigRegistry registry = IOFTConfigRegistry(stdJson.readAddress(readDeploymentFile(), ".addresses.OFTConfigRegistry"));
        uint256 staleCount = check(registry);
        if (staleCount != 0 && vm.envOr("REVERT_IF_STALE", false)) revert("config drift detected");
    }

    /// @notice Enumerate every registered bridge x active destination, log each pathway's status,
    ///         and return the number of stale (or unreadable) entries. Pure read — safe to call
    ///         from tests against a live-endpoint harness.
    function check(IOFTConfigRegistry registry) public view returns (uint256) {
        uint32[] memory dstEids = registry.activeDstEids();
        address[] memory bridges = registry.getBridges(0, registry.numBridges());
        uint256 staleCount;

        console.log("OFT config staleness check");
        console.log("  chainId:    ", block.chainid);
        console.log("  registry:   ", address(registry));
        console.log("  version:    ", registry.configVersion());
        console.log("  bridges:    ", bridges.length);
        console.log("  active eids:", dstEids.length);

        for (uint256 b; b < bridges.length; ++b) {
            console.log("");
            console.log("bridge", bridges[b]);

            for (uint256 e; e < dstEids.length; ++e) {
                uint32 dstEid = dstEids[e];
                PathwayEval memory ev = _evaluate(registry, bridges[b], dstEid);

                if (!ev.readOk) {
                    staleCount++;
                    console.log("  dstEid", dstEid, "READ FAILED (lib not a registered messagelib?)");
                } else if (ev.inSync) {
                    console.log("  dstEid", dstEid, "IN SYNC");
                } else {
                    staleCount++;
                    console.log("  dstEid", dstEid, "STALE");
                    if (!_eq(ev.want, ev.sendCfg)) _logDiff("    send", ev.want, ev.sendCfg);
                    if (!_eq(ev.want, ev.recvCfg)) _logDiff("    recv", ev.want, ev.recvCfg);
                }
            }
        }

        console.log("");
        console.log("stale entries:", staleCount);
        return staleCount;
    }

    /// @notice Status of a single (bridge, dstEid): whether the endpoint rows could be read, and
    ///         whether the applied send+receive ULN config matches the registry's canonical config.
    function pathwayStatus(IOFTConfigRegistry registry, address bridge, uint32 dstEid) public view returns (bool, bool) {
        PathwayEval memory ev = _evaluate(registry, bridge, dstEid);
        return (ev.readOk, ev.inSync);
    }

    /// @dev Build expected config + read both endpoint rows + compare. Returns the configs too so
    ///      the caller can log field-level diffs without a second read.
    function _evaluate(IOFTConfigRegistry registry, address bridge, uint32 dstEid) internal view returns (PathwayEval memory) {
        IOFTConfigRegistry.PathwayConfig memory c = registry.getPathwayConfig(dstEid);
        UlnConfig memory want = _expected(c);

        address ep = IBridgeEndpoint(bridge).endpoint();
        (bool sendRead, UlnConfig memory sendCfg) = _read(ep, bridge, c.sendLib, dstEid);
        (bool recvRead, UlnConfig memory recvCfg) = _read(ep, bridge, c.receiveLib, dstEid);

        bool readOk = sendRead && recvRead;
        bool inSync = readOk && _eq(want, sendCfg) && _eq(want, recvCfg);
        return PathwayEval(readOk, inSync, want, sendCfg, recvCfg);
    }

    /// @dev Build the UlnConfig the bridge WOULD write, identically to ConfigurableOFTBase.syncConfig.
    function _expected(IOFTConfigRegistry.PathwayConfig memory c) internal pure returns (UlnConfig memory) {
        return UlnConfig({ confirmations: c.confirmations, requiredDVNCount: uint8(c.requiredDVNs.length), optionalDVNCount: uint8(c.optionalDVNs.length), optionalDVNThreshold: c.optionalDVNThreshold, requiredDVNs: c.requiredDVNs, optionalDVNs: c.optionalDVNs });
    }

    /// @dev Read+decode the effective ULN config for (bridge, lib, dstEid). `ok=false` if the lib
    ///      isn't a registered messagelib (getConfig reverts) rather than aborting the whole sweep.
    function _read(address ep, address bridge, address lib, uint32 dstEid) internal view returns (bool, UlnConfig memory) {
        UlnConfig memory cfg;
        try ILayerZeroEndpointV2(ep).getConfig(bridge, lib, dstEid, CONFIG_TYPE_ULN) returns (bytes memory raw) {
            return (true, abi.decode(raw, (UlnConfig)));
        } catch {
            return (false, cfg);
        }
    }

    /// @dev Field-by-field equality. NOTE: getConfig returns the EFFECTIVE config (the bridge's
    ///      custom config, or the LZ default if it never synced — a never-synced bridge correctly
    ///      reports STALE). For these pathways every field is set explicitly, so a direct compare is
    ///      exact; if a pathway ever stores confirmations==0 ("use default" sentinel) it would need
    ///      special handling here.
    function _eq(UlnConfig memory a, UlnConfig memory b) internal pure returns (bool) {
        if (a.confirmations != b.confirmations) return false;
        if (a.requiredDVNCount != b.requiredDVNCount) return false;
        if (a.optionalDVNCount != b.optionalDVNCount) return false;
        if (a.optionalDVNThreshold != b.optionalDVNThreshold) return false;
        if (a.requiredDVNs.length != b.requiredDVNs.length) return false;
        if (a.optionalDVNs.length != b.optionalDVNs.length) return false;
        for (uint256 i; i < a.requiredDVNs.length; ++i) {
            if (a.requiredDVNs[i] != b.requiredDVNs[i]) return false;
        }
        for (uint256 i; i < a.optionalDVNs.length; ++i) {
            if (a.optionalDVNs[i] != b.optionalDVNs[i]) return false;
        }
        return true;
    }

    function _logDiff(string memory tag, UlnConfig memory want, UlnConfig memory got) internal pure {
        console.log(string.concat(tag, " confirmations want/got"), want.confirmations, got.confirmations);
        console.log(string.concat(tag, " requiredDVNs  want/got"), want.requiredDVNCount, got.requiredDVNCount);
        console.log(string.concat(tag, " optionalDVNs  want/got"), want.optionalDVNCount, got.optionalDVNCount);
    }
}
