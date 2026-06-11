// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IOFTConfigRegistry
 * @author ether.fi
 * @notice Single source of truth for the LayerZero security config (DVN stack +
 *         libraries) that every OFT bridge on this chain pulls from. Lets us
 *         update the canonical config once and push it to all bridges.
 */
interface IOFTConfigRegistry {
    /// @notice Canonical LZ config for one destination pathway (per dstEid)
    struct PathwayConfig {
        address sendLib; // LZ SendUln302
        address receiveLib; // LZ ReceiveUln302
        uint64 confirmations; // block confirmations before delivery
        uint8 optionalDVNThreshold; // how many optional DVNs must sign
        address[] requiredDVNs; // sorted ascending, no duplicates
        address[] optionalDVNs; // sorted ascending, no duplicates
    }

    event PathwayConfigSet(uint32 indexed dstEid, uint256 version);
    event PathwayRemoved(uint32 indexed dstEid, uint256 version);
    event BridgeRegistered(address indexed bridge);
    event BridgeDeregistered(address indexed bridge);
    event ConfigPushed(address indexed bridge, uint32[] dstEids);

    error InvalidInput();
    error OnlyConfigAdmin();
    error OnlyRegistrar();
    error DVNsNotSortedOrUnique();
    error TooManyDVNs();
    error InvalidOptionalDVNThreshold();
    error PathwayNotFound();
    error BridgeNotFound();

    /// @notice Set/replace the canonical config for a destination (bumps version)
    function setPathwayConfig(uint32 dstEid, PathwayConfig calldata cfg) external;
    /// @notice Remove a destination's pathway so it stops propagating (admin only)
    function removePathway(uint32 dstEid) external;

    function getPathwayConfig(uint32 dstEid) external view returns (PathwayConfig memory);
    function configVersion() external view returns (uint256);
    function activeDstEids() external view returns (uint32[] memory);

    /// @notice Record a bridge so {pushToAll} can enumerate it (registrar only)
    function registerBridge(address bridge) external;
    /// @notice Drop a bridge from the push set so it stops receiving config (admin only)
    function deregisterBridge(address bridge) external;
    function getBridges(uint256 start, uint256 n) external view returns (address[] memory);
    function numBridges() external view returns (uint256);

    /// @notice Make a single bridge re-pull config (registrar only; the factory auto-sync path)
    function syncBridge(address bridge, uint32[] calldata dstEids) external;
    /// @notice Make the given bridges re-pull config (admin only)
    function pushTo(address[] calldata bridges, uint32[] calldata dstEids) external;
    /// @notice Make every registered bridge re-pull config (admin only)
    function pushToAll(uint32[] calldata dstEids) external;
    /// @notice Paginated {pushToAll} for large bridge sets (admin only)
    function pushToRange(uint256 start, uint256 count, uint32[] calldata dstEids) external;
}
