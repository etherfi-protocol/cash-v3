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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
        __Pausable_init();
    }

    /// @inheritdoc IOFTConfigRegistry
    function setPathwayConfig(uint32 dstEid, PathwayConfig calldata cfg) external override whenNotPaused {
        if (!roleRegistry().hasRole(CONFIG_ADMIN_ROLE, msg.sender)) revert OnlyConfigAdmin();
        if (cfg.sendLib == address(0) || cfg.receiveLib == address(0) || cfg.requiredDVNs.length == 0) revert InvalidInput();

        OFTConfigRegistryStorage storage $ = _getStorage();
        $.pathway[dstEid] = cfg;
        $.activeDstEidSet.add(dstEid); // idempotent: a re-configured destination is not double-listed
        unchecked {
            $.version += 1;
        }
        emit PathwayConfigSet(dstEid, $.version);
    }

    /// @inheritdoc IOFTConfigRegistry
    function getPathwayConfig(uint32 dstEid) external view override returns (PathwayConfig memory) {
        return _getStorage().pathway[dstEid];
    }

    /// @inheritdoc IOFTConfigRegistry
    function configVersion() external view override returns (uint256) {
        return _getStorage().version;
    }

    /// @inheritdoc IOFTConfigRegistry
    function activeDstEids() external view override returns (uint32[] memory eids) {
        uint256[] memory raw = _getStorage().activeDstEidSet.values();
        eids = new uint32[](raw.length);
        for (uint256 i; i < raw.length;) {
            eids[i] = uint32(raw[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IOFTConfigRegistry
    function registerBridge(address bridge) external override whenNotPaused {
        if (!roleRegistry().hasRole(CONFIG_REGISTRAR_ROLE, msg.sender)) revert OnlyRegistrar();
        if (bridge == address(0)) revert InvalidInput();
        _getStorage().bridgeSet.add(bridge);
        emit BridgeRegistered(bridge);
    }

    /// @inheritdoc IOFTConfigRegistry
    function getBridges(uint256 start, uint256 n) external view override returns (address[] memory bridges) {
        OFTConfigRegistryStorage storage $ = _getStorage();
        uint256 len = $.bridgeSet.length();
        if (start >= len) return new address[](0);
        if (start + n > len) n = len - start;
        bridges = new address[](n);
        for (uint256 i; i < n;) {
            bridges[i] = $.bridgeSet.at(start + i);
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IOFTConfigRegistry
    function numBridges() external view override returns (uint256) {
        return _getStorage().bridgeSet.length();
    }

    /// @inheritdoc IOFTConfigRegistry
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

    /// @inheritdoc IOFTConfigRegistry
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

    /// @inheritdoc IOFTConfigRegistry
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

    function _getStorage() private pure returns (OFTConfigRegistryStorage storage $) {
        assembly {
            $.slot := OFTConfigRegistryStorageLocation
        }
    }
}
