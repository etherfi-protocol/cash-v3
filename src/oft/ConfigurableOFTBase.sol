// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import { UlnConfig } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import { SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import { OFTCoreUpgradeable } from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTCoreUpgradeable.sol";

import { IConfigurableOFT } from "../interfaces/IConfigurableOFT.sol";
import { IOFTConfigRegistry } from "../interfaces/IOFTConfigRegistry.sol";
import { IRoleRegistry } from "../interfaces/IRoleRegistry.sol";

/// @dev Minimal view into the config registry to resolve the shared RoleRegistry that gates pause.
///      The registry exposes `roleRegistry()` (via UpgradeableProxy); the bridge reads it rather
///      than carrying its own RoleRegistry reference.
interface IRoleRegistrySource {
    function roleRegistry() external view returns (IRoleRegistry);
}

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
 *      chain, like the endpoint); the bridge keeps no per-proxy sync state —
 *      each sync is observable via the {ConfigSynced} event.
 *
 *      Only the DVN/library config (endpoint-side) is synced here. Enforced
 *      options are owner-gated on the OApp and are set separately by the owner.
 *
 *      Pause: the bridge inherits {PausableUpgradeable}; children apply
 *      {whenNotPaused} to `_debit` (send) and `_credit` (receive) so one flag halts
 *      BOTH directions. {pauseBridge}/{unpauseBridge} live and are gated HERE on the
 *      bridge (not routed through the registry) so the emergency control has no
 *      control-path dependency on another mutable contract — matching the weETH OFTs
 *      and our own {PairwiseRateLimiter}. They are gated by the shared RoleRegistry
 *      PAUSER/UNPAUSER roles (the same roles the oracle side uses), resolved by reading
 *      `roleRegistry()` off the immutable {configRegistry}. "Pause everything" is an
 *      off-chain Safe batch of {pauseBridge} calls. State lives in {PausableUpgradeable}'s
 *      own ERC-7201 slot, so an existing beacon proxy gains pause without disturbing its
 *      layout and reads as unpaused by default.
 */
abstract contract ConfigurableOFTBase is OFTCoreUpgradeable, PausableUpgradeable, IConfigurableOFT {
    /// @notice Shared config registry, fixed at impl deploy (one per chain)
    address public immutable override configRegistry;

    /// @dev LayerZero ULN config type id used by `setConfig`
    uint32 private constant CONFIG_TYPE_ULN = 2;

    error RegistryNotSet();
    error UnauthorizedSync();

    event ConfigSynced(uint32[] dstEids);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _configRegistry) {
        configRegistry = _configRegistry;
    }

    /**
     * @notice Pause this bridge — halts both send and receive. Callable by a PAUSER.
     * @dev Gated by the shared RoleRegistry PAUSER role (resolved off {configRegistry}), not the
     *      OApp delegate, so an incident responder can halt the bridge without the heavier config
     *      Safe. Idempotent: a redundant pause is a no-op (OZ {_pause} would otherwise revert).
     *      Emits {Paused} on a real transition. Inbound messages that arrive while paused revert in
     *      {_credit} and become retryable on the endpoint — held, not lost — until {unpauseBridge}.
     */
    function pauseBridge() external {
        _roleRegistry().onlyPauser(msg.sender);
        if (!paused()) _pause();
    }

    /**
     * @notice Unpause this bridge. Callable by an UNPAUSER (held more tightly than PAUSER).
     * @dev Idempotent: a redundant unpause is a no-op. Emits {Unpaused} on a real transition.
     */
    function unpauseBridge() external {
        _roleRegistry().onlyUnpauser(msg.sender);
        if (paused()) _unpause();
    }

    /// @dev The shared RoleRegistry that gates pause, read off the immutable config registry.
    function _roleRegistry() private view returns (IRoleRegistry) {
        return IRoleRegistrySource(configRegistry).roleRegistry();
    }

    /**
     * @notice Pulls the canonical config from the registry and applies it to this
     *         bridge's own endpoint rows for each destination.
     * @dev Only the {configRegistry} may invoke this — operators push via the registry
     *      ({pushTo}/{pushToAll}/{pushToRange}) and factories sync via {syncBridge}. Gating to the
     *      registry stops a third party from forcing a re-pull that would revert an operator's
     *      out-of-band hardening or bypass an incident pause. Self-authorized on the endpoint:
     *      `msg.sender == oapp` lets this bridge call `setConfig` without a delegate. Emits
     *      {ConfigSynced}; the bridge keeps no per-proxy sync state, so verify applied config by
     *      reading the endpoint rows.
     * @param dstEids Destination endpoint IDs to (re)configure
     */
    function syncConfig(uint32[] calldata dstEids) external override {
        address reg = configRegistry;
        if (reg == address(0)) revert RegistryNotSet();
        if (msg.sender != reg) revert UnauthorizedSync();

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

        emit ConfigSynced(dstEids);
    }
}
