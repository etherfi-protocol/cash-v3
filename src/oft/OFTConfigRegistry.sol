// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { IConfigurableOFT } from "../interfaces/IConfigurableOFT.sol";
import { IOFTConfigRegistry } from "../interfaces/IOFTConfigRegistry.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title OFTConfigRegistry
 * @author ether.fi
 * @notice Single source of truth (per chain) for the LayerZero security config
 *         (DVN stack + libraries) used by every OFT bridge. Bridges pull from it
 *         via {IConfigurableOFT-syncConfig}; admins update it once and push to all.
 * @dev UUPS-upgradeable via {UpgradeableProxy} (gated by the RoleRegistry owner).
 *      Config edits require CONFIG_ADMIN_ROLE; factories that auto-register new
 *      bridges hold CONFIG_REGISTRAR_ROLE.
 */
contract OFTConfigRegistry is IOFTConfigRegistry, UpgradeableProxy {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using EnumerableSetLib for EnumerableSetLib.Uint256Set;

    /// @custom:storage-location erc7201:etherfi.storage.OFTConfigRegistry
    struct OFTConfigRegistryStorage {
        mapping(uint32 dstEid => PathwayConfig) pathway;
        EnumerableSetLib.AddressSet bridgeSet;
        EnumerableSetLib.Uint256Set activeDstEidSet;
        uint256 version;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.OFTConfigRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OFTConfigRegistryStorageLocation = 0x8af526858b42bae478f5f49bbcba7c9c8d3658bf37ed842573174e7417591900;

    /// @notice Role allowed to edit canonical config + trigger pushes
    bytes32 public constant CONFIG_ADMIN_ROLE = keccak256("OFT_CONFIG_ADMIN_ROLE");
    /// @notice Role allowed to register new bridges (the factories)
    bytes32 public constant CONFIG_REGISTRAR_ROLE = keccak256("OFT_CONFIG_REGISTRAR_ROLE");

    /// @dev Max DVNs per side. Mirrors LayerZero {UlnBase}'s MAX_COUNT = (type(uint8).max - 1) / 2,
    ///      which caps total DVNs (required + optional) so the on-chain config stays within uint8.
    uint256 private constant MAX_DVN_COUNT = 127;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
        __Pausable_init();
    }

    /**
     * @notice Set/replace the canonical config for a destination (bumps version)
     * @dev Restricted to CONFIG_ADMIN_ROLE. Reverts on a zero send/receive lib or empty required DVN set,
     *      and validates the DVN stack against the same invariants LayerZero's {UlnBase} enforces
     *      ({_assertConfigValid}) so a malformed config fails fast here instead of being stored, listed,
     *      and then reverting on every {syncConfig}/{pushTo}/factory auto-deploy for this dstEid.
     * @param dstEid LayerZero destination endpoint id
     * @param cfg Full pathway config (libraries, confirmations, DVN stack)
     */
    function setPathwayConfig(uint32 dstEid, PathwayConfig calldata cfg) external override whenNotPaused {
        if (!roleRegistry().hasRole(CONFIG_ADMIN_ROLE, msg.sender)) revert OnlyConfigAdmin();
        if (cfg.sendLib == address(0) || cfg.receiveLib == address(0) || cfg.requiredDVNs.length == 0) revert InvalidInput();
        _assertConfigValid(cfg);

        OFTConfigRegistryStorage storage $ = _getStorage();
        $.pathway[dstEid] = cfg;
        $.activeDstEidSet.add(dstEid); // idempotent: a re-configured destination is not double-listed
        unchecked {
            $.version += 1;
        }
        emit PathwayConfigSet(dstEid, $.version);
    }

    /**
     * @notice Remove a destination's pathway (admin only, bumps version)
     * @dev Restricted to CONFIG_ADMIN_ROLE. Deletes the stored config and drops the destination from
     *      {activeDstEids}, so it stops propagating to bridges deployed/synced afterwards. It does NOT
     *      rewrite config already applied to a bridge's endpoint rows — to neutralize an in-flight
     *      pathway (e.g. a compromised DVN), the operator must also unset the peer or push a
     *      restrictive config directly. Reverts if the destination was never configured.
     * @param dstEid LayerZero destination endpoint id to remove
     */
    function removePathway(uint32 dstEid) external override whenNotPaused {
        if (!roleRegistry().hasRole(CONFIG_ADMIN_ROLE, msg.sender)) revert OnlyConfigAdmin();
        OFTConfigRegistryStorage storage $ = _getStorage();
        if (!$.activeDstEidSet.remove(dstEid)) revert PathwayNotFound();
        delete $.pathway[dstEid];
        unchecked {
            $.version += 1;
        }
        emit PathwayRemoved(dstEid, $.version);
    }

    /**
     * @notice Returns the canonical config for a destination pathway
     * @param dstEid LayerZero destination endpoint id
     * @return The stored pathway config (zero-valued if never set)
     */
    function getPathwayConfig(uint32 dstEid) external view override returns (PathwayConfig memory) {
        return _getStorage().pathway[dstEid];
    }

    /**
     * @notice Current config version, bumped on every {setPathwayConfig}
     * @return The monotonic config version
     */
    function configVersion() external view override returns (uint256) {
        return _getStorage().version;
    }

    /**
     * @notice All destination endpoint ids that have a configured pathway
     * @return eids The active destination endpoint ids
     */
    function activeDstEids() external view override returns (uint32[] memory) {
        uint256[] memory raw = _getStorage().activeDstEidSet.values();
        uint32[] memory eids = new uint32[](raw.length);
        for (uint256 i; i < raw.length;) {
            eids[i] = uint32(raw[i]);
            unchecked {
                ++i;
            }
        }
        return eids;
    }

    /**
     * @notice Record a bridge so {pushToAll} can enumerate it (registrar only)
     * @dev Restricted to CONFIG_REGISTRAR_ROLE (the factories). Reverts on a zero address; idempotent.
     * @param bridge The OFT bridge to register
     */
    function registerBridge(address bridge) external override whenNotPaused {
        if (!roleRegistry().hasRole(CONFIG_REGISTRAR_ROLE, msg.sender)) revert OnlyRegistrar();
        if (bridge == address(0)) revert InvalidInput();
        // Gate the event on a genuine insertion so re-registering a known bridge is a silent no-op.
        if (_getStorage().bridgeSet.add(bridge)) emit BridgeRegistered(bridge);
    }

    /**
     * @notice Drop a bridge from the push set (admin only)
     * @dev Restricted to CONFIG_ADMIN_ROLE. After removal the bridge is no longer enumerated by
     *      {pushToAll}/{pushToRange}, so a deprecated or compromised bridge stops receiving config.
     *      It does NOT touch config already on the bridge's endpoint rows. Reverts if not registered.
     * @param bridge The OFT bridge to deregister
     */
    function deregisterBridge(address bridge) external override whenNotPaused {
        if (!roleRegistry().hasRole(CONFIG_ADMIN_ROLE, msg.sender)) revert OnlyConfigAdmin();
        if (!_getStorage().bridgeSet.remove(bridge)) revert BridgeNotFound();
        emit BridgeDeregistered(bridge);
    }

    /**
     * @notice Paginated enumeration of registered bridges
     * @param start Starting index in the bridge set
     * @param n Maximum number of entries to return
     * @return bridges Array of registered bridge addresses
     */
    function getBridges(uint256 start, uint256 n) external view override returns (address[] memory) {
        OFTConfigRegistryStorage storage $ = _getStorage();
        uint256 len = $.bridgeSet.length();
        if (start >= len) return new address[](0);
        if (start + n > len) n = len - start;
        address[] memory bridges = new address[](n);
        for (uint256 i; i < n;) {
            bridges[i] = $.bridgeSet.at(start + i);
            unchecked {
                ++i;
            }
        }
        return bridges;
    }

    /**
     * @notice Total number of registered bridges
     * @return Number of registered bridges
     */
    function numBridges() external view override returns (uint256) {
        return _getStorage().bridgeSet.length();
    }

    /**
     * @notice Make a single bridge re-pull config (registrar only)
     * @dev Restricted to CONFIG_REGISTRAR_ROLE. This is the path the factories use to sync a bridge
     *      right after deploy: a bridge's {IConfigurableOFT-syncConfig} only accepts calls from this
     *      registry, so the factory routes its post-deploy sync through here rather than calling the
     *      bridge directly.
     * @param bridge Bridge to refresh
     * @param dstEids Destination endpoint ids to (re)configure on the bridge
     */
    function syncBridge(address bridge, uint32[] calldata dstEids) external override whenNotPaused {
        if (!roleRegistry().hasRole(CONFIG_REGISTRAR_ROLE, msg.sender)) revert OnlyRegistrar();
        IConfigurableOFT(bridge).syncConfig(dstEids);
        emit ConfigPushed(bridge, dstEids);
    }

    /**
     * @notice Make the given bridges re-pull config (admin only)
     * @dev Restricted to CONFIG_ADMIN_ROLE. Calls {IConfigurableOFT-syncConfig} on each bridge.
     * @param bridges Bridges to refresh
     * @param dstEids Destination endpoint ids to (re)configure on each bridge
     */
    function pushTo(address[] calldata bridges, uint32[] calldata dstEids) external override whenNotPaused {
        if (!roleRegistry().hasRole(CONFIG_ADMIN_ROLE, msg.sender)) revert OnlyConfigAdmin();
        for (uint256 i; i < bridges.length;) {
            IConfigurableOFT(bridges[i]).syncConfig(dstEids);
            emit ConfigPushed(bridges[i], dstEids);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Make every registered bridge re-pull config (admin only)
     * @dev Restricted to CONFIG_ADMIN_ROLE. Iterates the full bridge set; for large sets that
     *      risk the block gas limit, use {pushToRange} to paginate.
     * @param dstEids Destination endpoint ids to (re)configure on each bridge
     */
    function pushToAll(uint32[] calldata dstEids) external override whenNotPaused {
        if (!roleRegistry().hasRole(CONFIG_ADMIN_ROLE, msg.sender)) revert OnlyConfigAdmin();
        OFTConfigRegistryStorage storage $ = _getStorage();
        uint256 len = $.bridgeSet.length();
        for (uint256 i; i < len;) {
            address b = $.bridgeSet.at(i);
            IConfigurableOFT(b).syncConfig(dstEids);
            emit ConfigPushed(b, dstEids);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Paginated {pushToAll} for large bridge sets (admin only)
     * @dev Restricted to CONFIG_ADMIN_ROLE.
     * @param start Starting index in the bridge set
     * @param count Maximum number of bridges to refresh
     * @param dstEids Destination endpoint ids to (re)configure on each bridge
     */
    function pushToRange(uint256 start, uint256 count, uint32[] calldata dstEids) external override whenNotPaused {
        if (!roleRegistry().hasRole(CONFIG_ADMIN_ROLE, msg.sender)) revert OnlyConfigAdmin();
        OFTConfigRegistryStorage storage $ = _getStorage();
        uint256 len = $.bridgeSet.length();
        if (start >= len) return;
        if (start + count > len) count = len - start;
        for (uint256 i; i < count;) {
            address b = $.bridgeSet.at(start + i);
            IConfigurableOFT(b).syncConfig(dstEids);
            emit ConfigPushed(b, dstEids);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Reject any config the LayerZero ULN library would reject at apply time. Mirrors
     *      {UlnBase}._setConfig for the non-DEFAULT/non-NIL case this registry always produces
     *      (requiredDVNs is non-empty): both DVN lists sorted ascending + deduped, each within
     *      MAX_DVN_COUNT, and optionalDVNThreshold == 0 iff there are no optional DVNs, else in
     *      (0, optionalDVNs.length].
     */
    function _assertConfigValid(PathwayConfig calldata cfg) private pure {
        if (cfg.requiredDVNs.length > MAX_DVN_COUNT || cfg.optionalDVNs.length > MAX_DVN_COUNT) revert TooManyDVNs();
        _assertSortedAndUnique(cfg.requiredDVNs);
        _assertSortedAndUnique(cfg.optionalDVNs);
        if (cfg.optionalDVNs.length == 0) {
            if (cfg.optionalDVNThreshold != 0) revert InvalidOptionalDVNThreshold();
        } else if (cfg.optionalDVNThreshold == 0 || cfg.optionalDVNThreshold > cfg.optionalDVNs.length) {
            revert InvalidOptionalDVNThreshold();
        }
    }

    /// @dev Strictly-ascending check: each entry must exceed the previous, which also forbids
    ///      duplicates and a leading address(0) (a zero DVN). Mirrors {UlnBase}._assertNoDuplicates.
    function _assertSortedAndUnique(address[] calldata dvns) private pure {
        address last = address(0);
        for (uint256 i; i < dvns.length;) {
            if (dvns[i] <= last) revert DVNsNotSortedOrUnique();
            last = dvns[i];
            unchecked {
                ++i;
            }
        }
    }

    function _getStorage() private pure returns (OFTConfigRegistryStorage storage $) {
        assembly {
            $.slot := OFTConfigRegistryStorageLocation
        }
    }
}
