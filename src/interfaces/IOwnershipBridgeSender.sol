// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IOwnershipBridgeSender
 * @author ether.fi
 * @notice Source-chain (OP) singleton that publishes safe owner-mutating operations to
 *         configured destination chains via LayerZero. Called by EtherFiSafes from inside
 *         their owner-mutating functions after the change has been applied locally.
 */
interface IOwnershipBridgeSender {
    /**
     * @notice Emitted when a destination chain is added or its LZ options are updated.
     * @param destEid LayerZero EID of the destination chain.
     * @param options Per-destination LZ options (executor gas, msg type, etc.).
     * @param enabled Always true for this event; the destination is active.
     */
    event DestinationConfigured(uint32 indexed destEid, bytes options, bool enabled);

    /**
     * @notice Emitted when a destination chain is removed from the publish set.
     * @param destEid LayerZero EID of the removed destination.
     */
    event DestinationRemoved(uint32 indexed destEid);

    /**
     * @notice Emitted when a `configureOwners` operation has been published to all destinations.
     * @param safe Source-chain safe whose owners are changing.
     * @param owners Owners to add or remove.
     * @param shouldAdd Per-owner add (true) / remove (false) flag.
     * @param threshold New signature threshold after the change.
     * @param destEids Destination LayerZero EIDs in publish order; parallel to `lzGuids`.
     * @param lzGuids LayerZero message GUIDs, one per destination in publish order.
     */
    event ConfigureOwnersPublished(
        address indexed safe,
        address[] owners,
        bool[] shouldAdd,
        uint8 threshold,
        uint32[] destEids,
        bytes32[] lzGuids
    );

    /**
     * @notice Emitted when a `setThreshold` operation has been published.
     * @param safe Source-chain safe.
     * @param threshold New signature threshold.
     * @param destEids Destination LayerZero EIDs in publish order; parallel to `lzGuids`.
     * @param lzGuids LayerZero message GUIDs, one per destination.
     */
    event SetThresholdPublished(address indexed safe, uint8 threshold, uint32[] destEids, bytes32[] lzGuids);

    /**
     * @notice Emitted when a `recover` operation has been published.
     * @param safe Source-chain safe.
     * @param newOwner Incoming owner that will take effect after the destination's timelock.
     * @param incomingOwnerEffectiveAt Source-chain UNIX timestamp at which `newOwner` should activate.
     * @param destEids Destination LayerZero EIDs in publish order; parallel to `lzGuids`.
     * @param lzGuids LayerZero message GUIDs, one per destination.
     */
    event RecoverPublished(
        address indexed safe,
        address newOwner,
        uint256 incomingOwnerEffectiveAt,
        uint32[] destEids,
        bytes32[] lzGuids
    );

    /**
     * @notice Emitted when a `cancelRecovery` operation has been published.
     * @param safe Source-chain safe.
     * @param destEids Destination LayerZero EIDs in publish order; parallel to `lzGuids`.
     * @param lzGuids LayerZero message GUIDs, one per destination.
     */
    event CancelRecoveryPublished(address indexed safe, uint32[] destEids, bytes32[] lzGuids);

    /**
     * @notice Emitted when ownership bridging is enabled for a safe on a specific destination.
     * @dev Idempotent — re-enabling an already-enabled (safe, destEid) pair does not re-emit.
     *      Set by holders of `ETHER_FI_WALLET_ROLE` (the `TradingBridgeModule` for the
     *      Send-to-Trading path; the BE keeper for the misroute-redirect path).
     * @param safe The safe whose enabled set changed.
     * @param destEid Destination LayerZero EID newly enabled for the safe.
     */
    event OwnershipBridgeEnabled(address indexed safe, uint32 indexed destEid);

    /**
     * @notice Emitted when a publish call is short-circuited because the safe has no enabled destinations.
     * @dev The caller's `msg.value` is refunded; no LZ message is sent.
     * @param safe Source-chain safe.
     * @param kind The `OpKind` of the operation that would have been published, as `uint8`.
     */
    event OwnershipBridgeSkipped(address indexed safe, uint8 kind);

    /// @notice Reverts when `msg.sender` is not the safe being published.
    error CallerNotSafe();

    /// @notice Reverts when `enable` is called by an account without `ETHER_FI_WALLET_ROLE`.
    error OnlyEtherFiWallet();

    /**
     * @notice Reverts when `enable` or `_dispatch` references a destination that is not globally configured.
     * @param destEid The destination EID that is missing from the configured destinations list.
     */
    error DestinationNotConfigured(uint32 destEid);

    /// @notice Reverts when the input parameters are invalid.
    error InvalidInput();

    /// @notice Reverts when the safe address isn't recognised by `EtherFiDataProvider`.
    error NotEtherFiSafe();

    /// @notice Reverts when `configureDestination(eid, _, false)` is called for a destination that isn't present.
    error DestinationAlreadyInState();

    /**
     * @notice Reverts when an enabled destination has no LayerZero peer configured.
     * @param destEid The destination EID that is missing a peer.
     */
    error PeerNotConfigured(uint32 destEid);

    /**
     * @notice Reverts when `msg.value` doesn't cover the total LZ fee across all destinations.
     * @param supplied The `msg.value` actually provided.
     * @param required The cumulative native fee required at the point of failure.
     */
    error InsufficientFee(uint256 supplied, uint256 required);

    /// @notice Reverts when the refund of excess `msg.value` to the safe fails.
    error RefundFailed();

    /// @notice Reverts when `owners.length != shouldAdd.length` on a `configureOwners` publish.
    error ArrayLengthMismatch();

    /**
     * @notice Publishes a `configureOwners` operation to every configured destination chain.
     * @dev Callable only by the safe itself (`msg.sender == safe`) and only if the safe is
     *      registered in `EtherFiDataProvider`. The safe forwards `msg.value` to cover total
     *      LZ fees; excess is refunded to the safe. Per-destination EIDs and the resulting LZ
     *      GUIDs are surfaced via `ConfigureOwnersPublished`.
     * @param safe Source-chain safe whose owners are changing.
     * @param owners Owners to add or remove.
     * @param shouldAdd Per-owner add (true) / remove (false) flag.
     * @param threshold New signature threshold after the change is applied locally.
     * @custom:throws CallerNotSafe If `msg.sender != safe`.
     * @custom:throws NotEtherFiSafe If `safe` isn't registered.
     * @custom:throws ArrayLengthMismatch If `owners.length != shouldAdd.length`.
     * @custom:throws DestinationNotConfigured If an enabled destEid was later removed from the global config.
     * @custom:throws PeerNotConfigured If an enabled destination has no LZ peer set.
     * @custom:throws InsufficientFee If `msg.value` is below the total LZ fee.
     */
    function publishConfigureOwners(
        address safe,
        address[] calldata owners,
        bool[] calldata shouldAdd,
        uint8 threshold
    ) external payable;

    /**
     * @notice Publishes a `setThreshold` operation to every configured destination chain.
     * @dev Per-destination EIDs and resulting LZ GUIDs are surfaced via `SetThresholdPublished`.
     * @param safe Source-chain safe.
     * @param threshold New signature threshold.
     * @custom:throws CallerNotSafe If `msg.sender != safe`.
     * @custom:throws NotEtherFiSafe If `safe` isn't registered.
     * @custom:throws DestinationNotConfigured If an enabled destEid was later removed from the global config.
     * @custom:throws PeerNotConfigured If an enabled destination has no LZ peer set.
     * @custom:throws InsufficientFee If `msg.value` is below the total LZ fee.
     */
    function publishSetThreshold(address safe, uint8 threshold) external payable;

    /**
     * @notice Publishes a `recover` operation (timelocked owner replacement) to every destination.
     * @dev Per-destination EIDs and resulting LZ GUIDs are surfaced via `RecoverPublished`. The
     *      `incomingOwnerEffectiveAt` timestamp is shipped to the destination so its timelock
     *      target mirrors the source-chain decision instead of being recomputed locally.
     * @param safe Source-chain safe.
     * @param newOwner Incoming owner that will take effect after the destination's timelock.
     * @param incomingOwnerEffectiveAt Source-chain UNIX timestamp at which `newOwner` activates on destinations.
     * @custom:throws CallerNotSafe If `msg.sender != safe`.
     * @custom:throws NotEtherFiSafe If `safe` isn't registered.
     * @custom:throws DestinationNotConfigured If an enabled destEid was later removed from the global config.
     * @custom:throws PeerNotConfigured If an enabled destination has no LZ peer set.
     * @custom:throws InsufficientFee If `msg.value` is below the total LZ fee.
     */
    function publishRecover(address safe, address newOwner, uint256 incomingOwnerEffectiveAt) external payable;

    /**
     * @notice Publishes a `cancelRecovery` operation to every destination.
     * @dev Per-destination EIDs and resulting LZ GUIDs are surfaced via `CancelRecoveryPublished`.
     * @param safe Source-chain safe.
     * @custom:throws CallerNotSafe If `msg.sender != safe`.
     * @custom:throws NotEtherFiSafe If `safe` isn't registered.
     * @custom:throws DestinationNotConfigured If an enabled destEid was later removed from the global config.
     * @custom:throws PeerNotConfigured If an enabled destination has no LZ peer set.
     * @custom:throws InsufficientFee If `msg.value` is below the total LZ fee.
     */
    function publishCancelRecovery(address safe) external payable;

    /**
     * @notice Adds, updates, or removes a destination chain.
     * @dev Admin (Ownable owner) only.
     * @param destEid LayerZero EID of the destination chain.
     * @param options Per-destination LZ options (executor gas, msg type, etc.). Ignored when removing.
     * @param enabled True to add or update; false to remove.
     * @custom:throws DestinationAlreadyInState If removing a destination that isn't present.
     */
    function configureDestination(uint32 destEid, bytes calldata options, bool enabled) external;

    /**
     * @notice Returns the list of currently enabled destination EIDs.
     * @return Array of destination EIDs in publish order.
     */
    function getDestinations() external view returns (uint32[] memory);

    /**
     * @notice Returns the per-destination LZ options configured for `destEid`.
     * @param destEid The destination LayerZero EID.
     * @return The configured options bytes (empty if not configured).
     */
    function getDestinationOptions(uint32 destEid) external view returns (bytes memory);

    /**
     * @notice Quotes the total native LZ fee for a `configureOwners` publish across all destinations.
     * @param safe Source-chain safe (echoed into the envelope; not used in the quote).
     * @param owners Owners to add or remove.
     * @param shouldAdd Per-owner add / remove flag.
     * @param threshold New signature threshold.
     * @return totalFee Sum of native fees across configured destinations.
     */
    function quoteConfigureOwners(
        address safe,
        address[] calldata owners,
        bool[] calldata shouldAdd,
        uint8 threshold
    ) external view returns (uint256 totalFee);

    /**
     * @notice Quotes the total native LZ fee for a `setThreshold` publish.
     * @param safe Source-chain safe (echoed into the envelope; not used in the quote).
     * @param threshold New signature threshold.
     * @return totalFee Sum of native fees across configured destinations.
     */
    function quoteSetThreshold(address safe, uint8 threshold) external view returns (uint256 totalFee);

    /**
     * @notice Quotes the total native LZ fee for a `recover` publish.
     * @param safe Source-chain safe (echoed into the envelope; not used in the quote).
     * @param newOwner Incoming owner address.
     * @param incomingOwnerEffectiveAt Source-chain UNIX timestamp at which `newOwner` activates.
     * @return totalFee Sum of native fees across configured destinations.
     */
    function quoteRecover(address safe, address newOwner, uint256 incomingOwnerEffectiveAt) external view returns (uint256 totalFee);

    /**
     * @notice Quotes the total native LZ fee for a `cancelRecovery` publish.
     * @param safe Source-chain safe (echoed into the envelope; not used in the quote).
     * @return totalFee Sum of native fees across configured destinations.
     */
    function quoteCancelRecovery(address safe) external view returns (uint256 totalFee);

    /**
     * @notice Enables ownership bridging for a `(safe, destEid)` pair. Idempotent.
     * @dev Callable only by accounts holding `ETHER_FI_WALLET_ROLE` (e.g. `TradingBridgeModule`
     *      on the Send-to-Trading path; BE keeper on the misroute-redirect follow-up).
     *      Until enabled for at least one destination, publish calls for this safe
     *      short-circuit + refund without touching LayerZero — preventing "fake sends" for
     *      users who haven't yet activated their trading account on any destination.
     * @param safe Safe whose enabled set is being extended.
     * @param destEid Destination LayerZero EID to enable.
     * @custom:throws OnlyEtherFiWallet If caller lacks `ETHER_FI_WALLET_ROLE`.
     * @custom:throws NotEtherFiSafe If `safe` isn't registered with `EtherFiDataProvider`.
     * @custom:throws DestinationNotConfigured If `destEid` is not in the global destinations list.
     */
    function enable(address safe, uint32 destEid) external;

    /**
     * @notice Returns whether ownership bridging has been enabled for a `(safe, destEid)` pair.
     * @param safe Safe address to query.
     * @param destEid Destination LayerZero EID to query.
     * @return True if enabled.
     */
    function isEnabled(address safe, uint32 destEid) external view returns (bool);

    /**
     * @notice Returns the set of destination EIDs enabled for `safe`.
     * @param safe Safe address to query.
     * @return Array of destination EIDs the safe is enabled for, in insertion order.
     */
    function getEnabledDestinations(address safe) external view returns (uint32[] memory);

    /**
     * @notice Convenience view for the safe wiring: returns true iff a publish for `safe`
     *         would actually result in LZ sends.
     * @dev Folds in pause state and per-safe enabled-destination configuration so the safe
     *      can do a single view call to decide whether to bother calling `publish*`.
     * @param safe Safe address to query.
     * @return True iff `getEnabledDestinations(safe).length > 0 && !paused()`.
     */
    function isPublishLive(address safe) external view returns (bool);
}
