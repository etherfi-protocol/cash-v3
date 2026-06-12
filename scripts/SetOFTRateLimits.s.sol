// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { EtherFiOFTAdapter } from "../src/oft/EtherFiOFTAdapter.sol";
import { EtherFiShadowOFT } from "../src/oft/EtherFiShadowOFT.sol";
import { PairwiseRateLimiter } from "../src/oft/PairwiseRateLimiter.sol";

import { Utils } from "./utils/Utils.sol";

/**
 * @title SetOFTRateLimits
 * @author ether.fi
 * @notice Sets the per-bridge throughput cap (outbound + inbound) for a pathway. Used to (a) lift a
 *         live bridge out of the fail-closed state right after {UpgradeOFTRateLimiter}, and (b)
 *         re-tune a cap later without redeploying. Setting limits is gated to the OApp owner
 *         (the delegate), so PRIVATE_KEY here must be the bridge's delegate.
 * @dev Chain-aware: on mainnet (1) it caps the adapter's pathway to Optimism (EID 30111); on
 *      Optimism (10) it caps the shadow's pathway to Ethereum (EID 30101). The bridge proxy and
 *      the limit/window are env-overridable so this script is reusable across assets:
 *
 *        OFT_BRIDGE             bridge proxy address (default: the PEPE / iPEPE bridge from deployments.json)
 *        OFT_PEER_EID           peer endpoint id     (default: the cross-pathway eid for this chain)
 *        OFT_RATE_LIMIT_TOKENS  cap in WHOLE tokens, scaled to the asset's decimals (default: placeholder)
 *        OFT_RATE_WINDOW        window seconds       (default: 1 hour)
 *
 *        PRIVATE_KEY=<delegate> forge script scripts/SetOFTRateLimits.s.sol --rpc-url <mainnet|optimism> --broadcast
 */
contract SetOFTRateLimits is Utils {
    uint32 constant ETH_EID = 30_101;
    uint32 constant OP_EID = 30_111;

    // Placeholder cap in WHOLE tokens — the risk team sets the real number per asset. The script
    // scales this to the asset's decimals, so it means the same thing for a 6-/8-/18-decimal token.
    uint256 constant DEFAULT_LIMIT_TOKENS = 1_000_000;
    uint256 constant DEFAULT_WINDOW = 1 hours;

    function run() public {
        bool isMainnet = block.chainid == 1;
        require(isMainnet || block.chainid == 10, "run on Ethereum mainnet (1) or Optimism (10)");

        uint256 pk = vm.envUint("PRIVATE_KEY");

        string memory deployments = readDeploymentFile();
        string memory defaultBridgeKey = isMainnet ? ".addresses.OFTAdapter_PEPE" : ".addresses.ShadowOFT_iPEPE";
        address bridge = vm.envOr("OFT_BRIDGE", stdJson.readAddress(deployments, defaultBridgeKey));

        // The peer on the other side of this chain's only pathway.
        uint32 defaultPeerEid = isMainnet ? OP_EID : ETH_EID;
        uint32 peerEid = uint32(vm.envOr("OFT_PEER_EID", uint256(defaultPeerEid)));

        // Read the bridge's local decimals so the whole-token cap scales correctly per asset. The
        // adapter's LD is its underlying's decimals; the shadow iTOKEN exposes decimals() directly.
        uint8 decimals = isMainnet ? IERC20Metadata(EtherFiOFTAdapter(bridge).token()).decimals() : EtherFiShadowOFT(bridge).decimals();
        uint256 limitTokens = vm.envOr("OFT_RATE_LIMIT_TOKENS", DEFAULT_LIMIT_TOKENS);
        uint256 limit = limitTokens * (10 ** decimals);
        uint256 window = vm.envOr("OFT_RATE_WINDOW", DEFAULT_WINDOW);

        PairwiseRateLimiter.RateLimitConfig[] memory cfg = new PairwiseRateLimiter.RateLimitConfig[](1);
        cfg[0] = PairwiseRateLimiter.RateLimitConfig({ peerEid: peerEid, limit: limit, window: window });

        vm.startBroadcast(pk);
        PairwiseRateLimiter(bridge).setOutboundRateLimits(cfg);
        PairwiseRateLimiter(bridge).setInboundRateLimits(cfg);
        vm.stopBroadcast();

        console.log("Set OFT rate limits on chainId", block.chainid);
        console.log("  bridge:        ", bridge);
        console.log("  peer eid:      ", peerEid);
        console.log("  limit (tokens):", limitTokens);
        console.log("  limit (raw LD):", limit);
        console.log("  window:        ", window);
    }
}
