// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IOAppPeers
 * @author ether.fi
 * @notice Minimal LayerZero OApp view used by deploy/verification scripts to cross-check peering
 *         off-line, before anything is broadcast or bundled.
 * @dev Declared here rather than imported from the LayerZero packages so script configs carry no
 *      LayerZero remapping of their own. Both ShadowOFTs and OFTAdapters are OApps, so a single
 *      interface covers either end of a rail.
 */
interface IOAppPeers {
    /**
     * @notice The trusted remote OApp for an endpoint ID, as bytes32.
     * @param eid The remote endpoint ID.
     * @return The peer, left-padded into bytes32 (zero when unset).
     */
    function peers(uint32 eid) external view returns (bytes32);
}
