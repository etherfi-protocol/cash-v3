// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UlnConfig } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import { SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import { OFTCoreUpgradeable } from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTCoreUpgradeable.sol";

import { IConfigurableOFT } from "../interfaces/IConfigurableOFT.sol";
import { IOFTConfigRegistry } from "../interfaces/IOFTConfigRegistry.sol";

/**
 * @title ConfigurableOFTBase
 * @author ether.fi
 * @notice Shared mixin for the beacon OFT impls (adapter + shadow). Adds a
 *         pull-based LayerZero security-config sync: the bridge reads the
 *         canonical DVN/library config from a shared {OFTConfigRegistry} and
 *         writes it to ITS OWN rows on the endpoint.
 * @dev Self-configuration works because LayerZero authorizes
 *      `msg.sender == oapp` for `setConfig` (verified in EndpointV2), so no
 *      delegate transfer is needed. The registry address is immutable (one per
 *      chain, like the endpoint); the synced version lives in per-proxy storage.
 *
 *      Only the DVN/library config (endpoint-side) is synced here. Enforced
 *      options are owner-gated on the OApp and are set separately by the owner.
 */
abstract contract ConfigurableOFTBase is OFTCoreUpgradeable, IConfigurableOFT {
    /// @notice Shared config registry, fixed at impl deploy (one per chain)
    address public immutable override configRegistry;

    /// @custom:storage-location erc7201:etherfi.storage.ConfigurableOFT
    struct ConfigurableOFTStorage {
        /// @notice Registry config version this proxy last synced to
        uint256 syncedVersion;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.ConfigurableOFT")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ConfigurableOFTStorageLocation = 0xd18e887461873c61ac61602c54f3a01e3e69d73cf3dd7f9579b5f219dabfca00;

    /// @dev LayerZero ULN config type id used by `setConfig`
    uint32 private constant CONFIG_TYPE_ULN = 2;

    error RegistryNotSet();

    event ConfigSynced(uint32[] dstEids, uint256 version);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _configRegistry) {
        configRegistry = _configRegistry;
    }

    /**
     * @notice The registry config version this bridge last synced to
     * @return The last-synced config version (per-proxy)
     */
    function syncedConfigVersion() public view override returns (uint256) {
        return _getConfigurableOFTStorage().syncedVersion;
    }

    /**
     * @notice Pulls the canonical config from the registry and applies it to this
     *         bridge's own endpoint rows for each destination.
     * @dev Self-authorized: `msg.sender == oapp` lets this bridge call `setConfig` on the
     *      endpoint without a delegate. Records the synced version in per-proxy storage.
     * @param dstEids Destination endpoint IDs to (re)configure
     */
    function syncConfig(uint32[] calldata dstEids) external override {
        address reg = configRegistry;
        if (reg == address(0)) revert RegistryNotSet();

        for (uint256 i; i < dstEids.length;) {
            IOFTConfigRegistry.PathwayConfig memory c = IOFTConfigRegistry(reg).getPathwayConfig(dstEids[i]);

            UlnConfig memory uln = UlnConfig({ confirmations: c.confirmations, requiredDVNCount: uint8(c.requiredDVNs.length), optionalDVNCount: uint8(c.optionalDVNs.length), optionalDVNThreshold: c.optionalDVNThreshold, requiredDVNs: c.requiredDVNs, optionalDVNs: c.optionalDVNs });

            SetConfigParam[] memory params = new SetConfigParam[](1);
            params[0] = SetConfigParam({ eid: dstEids[i], configType: CONFIG_TYPE_ULN, config: abi.encode(uln) });

            // Self-authorized: msg.sender (this bridge) == oapp. No delegate needed.
            endpoint.setConfig(address(this), c.sendLib, params);
            endpoint.setConfig(address(this), c.receiveLib, params);

            unchecked {
                ++i;
            }
        }

        uint256 v = IOFTConfigRegistry(reg).configVersion();
        _getConfigurableOFTStorage().syncedVersion = v;
        emit ConfigSynced(dstEids, v);
    }

    function _getConfigurableOFTStorage() private pure returns (ConfigurableOFTStorage storage $) {
        assembly {
            $.slot := ConfigurableOFTStorageLocation
        }
    }
}
