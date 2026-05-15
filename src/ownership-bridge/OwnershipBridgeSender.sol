// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { OAppSender, MessagingFee, MessagingReceipt } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import { OAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppCore.sol";

import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { IOwnershipBridgeSender } from "../interfaces/IOwnershipBridgeSender.sol";
import { IRoleRegistry } from "../interfaces/IRoleRegistry.sol";
import { OwnershipBridgeMessageLib } from "../libraries/OwnershipBridgeMessageLib.sol";

/**
 * @title OwnershipBridgeSender
 * @author ether.fi
 * @notice Source-chain (OP) singleton. Called by EtherFiSafes from inside their
 *         owner-mutating functions to publish the operation to every configured destination
 *         chain via LayerZero. The safe passes the operation args directly — this contract
 *         never reads the safe's storage and never re-verifies signatures (the safe already
 *         did that locally before calling).
 */
contract OwnershipBridgeSender is IOwnershipBridgeSender, OAppSender, Pausable {
    using OwnershipBridgeMessageLib for OwnershipBridgeMessageLib.Envelope;
    using EnumerableSet for EnumerableSet.UintSet;

    /// @notice Role required to enable a safe for ownership bridging.
    bytes32 public constant ETHER_FI_WALLET_ROLE = keccak256("ETHER_FI_WALLET_ROLE");

    /// @notice Data provider used to validate that publish callers are real EtherFiSafes and
    ///         to look up the role registry for pause control.
    IEtherFiDataProvider public immutable etherFiDataProvider;

    /// @custom:storage-location erc7201:etherfi.storage.OwnershipBridgeSender
    struct OwnershipBridgeSenderStorage {
        /// @dev Configured destination EIDs. `uint32` values packed into the set's `uint256` element type.
        EnumerableSet.UintSet destinations;
        /// @dev Per-destination LZ options (gas/executor). Admin-managed.
        mapping(uint32 destEid => bytes options) destOptions;
        /// @dev Per-safe set of enabled destination EIDs. Until non-empty, all publish calls
        ///      short-circuit (refund + skip) to prevent wasted LZ fees on users who never
        ///      activate their trading account on any destination. 
        mapping(address safe => EnumerableSet.UintSet) enabledEids;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.OwnershipBridgeSender")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OwnershipBridgeSenderStorageLocation = 0xc4ea5a47ff0099ecbcb53131fb2d44654b52b7061bf536c7278a04325422e000;

    function _getOwnershipBridgeSenderStorage() private pure returns (OwnershipBridgeSenderStorage storage $) {
        assembly {
            $.slot := OwnershipBridgeSenderStorageLocation
        }
    }

    /**
     * @notice Deploys the sender.
     * @param _dataProvider Address of `EtherFiDataProvider` used for safe / role lookups.
     * @param _endpoint LayerZero v2 endpoint on this chain.
     * @param _delegate Initial Ownable owner and LZ delegate.
     */
    constructor(address _dataProvider, address _endpoint, address _delegate) OAppCore(_endpoint, _delegate) Ownable(_delegate) {
        if (_dataProvider == address(0)) revert InvalidInput();
        etherFiDataProvider = IEtherFiDataProvider(_dataProvider);
    }

    // ------------------------------------------------------------------
    // Publish surface — one method per source-side operation kind.
    // Each is callable only by an EtherFiSafe publishing about itself.
    // ------------------------------------------------------------------

    /**
     * @notice Publishes a `configureOwners` operation to every configured destination chain.
     * @dev Callable only by the safe itself (`msg.sender == safe`) and only if the safe is
     *      registered in `EtherFiDataProvider`. The safe forwards `msg.value` to cover total
     *      LZ fees; excess is refunded to the safe. If the safe has no enabled destinations,
     *      the call short-circuits with a full refund and emits `OwnershipBridgeSkipped`.
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
    ) external payable whenNotPaused onlyEtherFiSafe(safe) {
        if (_skipIfNotEnabled(safe, OwnershipBridgeMessageLib.OpKind.ConfigureOwners)) return;
        if (owners.length != shouldAdd.length) revert ArrayLengthMismatch();

        bytes memory opData = OwnershipBridgeMessageLib.encodeConfigureOwners(owners, shouldAdd, threshold);
        (bytes32[] memory guids, uint32[] memory destEids) = _dispatch(safe, OwnershipBridgeMessageLib.OpKind.ConfigureOwners, opData);

        emit ConfigureOwnersPublished(safe, owners, shouldAdd, threshold, destEids, guids);
    }

    /**
     * @notice Publishes a `setThreshold` operation to every configured destination chain.
     * @dev Callable only by the safe itself; short-circuits with refund if the safe has no
     *      enabled destinations.
     * @param safe Source-chain safe.
     * @param threshold New signature threshold.
     * @custom:throws CallerNotSafe If `msg.sender != safe`.
     * @custom:throws NotEtherFiSafe If `safe` isn't registered.
     * @custom:throws DestinationNotConfigured If an enabled destEid was later removed from the global config.
     * @custom:throws PeerNotConfigured If an enabled destination has no LZ peer set.
     * @custom:throws InsufficientFee If `msg.value` is below the total LZ fee.
     */
    function publishSetThreshold(address safe, uint8 threshold) external payable whenNotPaused onlyEtherFiSafe(safe) {
        if (_skipIfNotEnabled(safe, OwnershipBridgeMessageLib.OpKind.SetThreshold)) return;

        bytes memory opData = OwnershipBridgeMessageLib.encodeSetThreshold(threshold);
        (bytes32[] memory guids, uint32[] memory destEids) = _dispatch(safe, OwnershipBridgeMessageLib.OpKind.SetThreshold, opData);

        emit SetThresholdPublished(safe, threshold, destEids, guids);
    }

    /**
     * @notice Publishes a `recover` operation (timelocked owner replacement) to every destination.
     * @dev Callable only by the safe itself; short-circuits with refund if the safe has no
     *      enabled destinations.
     * @param safe Source-chain safe.
     * @param newOwner Incoming owner that will take effect after the destination's timelock.
     * @param incomingOwnerEffectiveAt Source-chain UNIX timestamp at which `newOwner` activates on destinations.
     * @custom:throws CallerNotSafe If `msg.sender != safe`.
     * @custom:throws NotEtherFiSafe If `safe` isn't registered.
     * @custom:throws DestinationNotConfigured If an enabled destEid was later removed from the global config.
     * @custom:throws PeerNotConfigured If an enabled destination has no LZ peer set.
     * @custom:throws InsufficientFee If `msg.value` is below the total LZ fee.
     */
    function publishRecover(address safe, address newOwner, uint256 incomingOwnerEffectiveAt) external payable whenNotPaused onlyEtherFiSafe(safe) {
        if (_skipIfNotEnabled(safe, OwnershipBridgeMessageLib.OpKind.Recover)) return;

        bytes memory opData = OwnershipBridgeMessageLib.encodeRecover(newOwner, incomingOwnerEffectiveAt);
        (bytes32[] memory guids, uint32[] memory destEids) = _dispatch(safe, OwnershipBridgeMessageLib.OpKind.Recover, opData);

        emit RecoverPublished(safe, newOwner, incomingOwnerEffectiveAt, destEids, guids);
    }

    /**
     * @notice Publishes a `cancelRecovery` operation to every destination.
     * @dev Callable only by the safe itself; short-circuits with refund if the safe has no
     *      enabled destinations.
     * @param safe Source-chain safe.
     * @custom:throws CallerNotSafe If `msg.sender != safe`.
     * @custom:throws NotEtherFiSafe If `safe` isn't registered.
     * @custom:throws DestinationNotConfigured If an enabled destEid was later removed from the global config.
     * @custom:throws PeerNotConfigured If an enabled destination has no LZ peer set.
     * @custom:throws InsufficientFee If `msg.value` is below the total LZ fee.
     */
    function publishCancelRecovery(address safe) external payable whenNotPaused onlyEtherFiSafe(safe) {
        if (_skipIfNotEnabled(safe, OwnershipBridgeMessageLib.OpKind.CancelRecovery)) return;

        bytes memory opData = OwnershipBridgeMessageLib.encodeCancelRecovery();
        (bytes32[] memory guids, uint32[] memory destEids) = _dispatch(safe, OwnershipBridgeMessageLib.OpKind.CancelRecovery, opData);

        emit CancelRecoveryPublished(safe, destEids, guids);
    }

    // ------------------------------------------------------------------
    // Quote surface — view-only fee estimates for each op kind.
    // ------------------------------------------------------------------

    /**
     * @notice Quotes the total native LZ fee for a `configureOwners` publish across destinations enabled for `safe`.
     * @param safe Source-chain safe; only its enabled destinations are iterated.
     * @param owners Owners to add or remove.
     * @param shouldAdd Per-owner add / remove flag.
     * @param threshold New signature threshold.
     * @return totalFee Sum of native fees across the safe's enabled destinations.
     */
    function quoteConfigureOwners(
        address safe,
        address[] calldata owners,
        bool[] calldata shouldAdd,
        uint8 threshold
    ) external view returns (uint256 totalFee) {
        bytes memory opData = OwnershipBridgeMessageLib.encodeConfigureOwners(owners, shouldAdd, threshold);
        totalFee = _quoteTotal(safe, OwnershipBridgeMessageLib.OpKind.ConfigureOwners, opData);
    }

    /**
     * @notice Quotes the total native LZ fee for a `setThreshold` publish across destinations enabled for `safe`.
     * @param safe Source-chain safe; only its enabled destinations are iterated.
     * @param threshold New signature threshold.
     * @return totalFee Sum of native fees across the safe's enabled destinations.
     */
    function quoteSetThreshold(address safe, uint8 threshold) external view returns (uint256 totalFee) {
        bytes memory opData = OwnershipBridgeMessageLib.encodeSetThreshold(threshold);
        totalFee = _quoteTotal(safe, OwnershipBridgeMessageLib.OpKind.SetThreshold, opData);
    }

    /**
     * @notice Quotes the total native LZ fee for a `recover` publish across destinations enabled for `safe`.
     * @param safe Source-chain safe; only its enabled destinations are iterated.
     * @param newOwner Incoming owner address.
     * @return totalFee Sum of native fees across the safe's enabled destinations.
     */
    function quoteRecover(address safe, address newOwner, uint256 incomingOwnerEffectiveAt) external view returns (uint256 totalFee) {
        bytes memory opData = OwnershipBridgeMessageLib.encodeRecover(newOwner, incomingOwnerEffectiveAt);
        totalFee = _quoteTotal(safe, OwnershipBridgeMessageLib.OpKind.Recover, opData);
    }

    /**
     * @notice Quotes the total native LZ fee for a `cancelRecovery` publish across destinations enabled for `safe`.
     * @param safe Source-chain safe; only its enabled destinations are iterated.
     * @return totalFee Sum of native fees across the safe's enabled destinations.
     */
    function quoteCancelRecovery(address safe) external view returns (uint256 totalFee) {
        bytes memory opData = OwnershipBridgeMessageLib.encodeCancelRecovery();
        totalFee = _quoteTotal(safe, OwnershipBridgeMessageLib.OpKind.CancelRecovery, opData);
    }

    // ------------------------------------------------------------------
    // Admin: destination management.
    // ------------------------------------------------------------------

    /**
     * @notice Adds, updates, or removes a destination chain.
     * @dev Admin (Ownable owner) only. When `enabled` is true and `destEid` is already
     *      configured, only the options are overwritten. When false, the destination is
     *      removed and its options cleared.
     * @param destEid LayerZero EID of the destination chain.
     * @param options Per-destination LZ options (executor gas, msg type, etc.). Ignored when removing.
     * @param enabled True to add or update; false to remove.
     * @custom:throws DestinationAlreadyInState If removing a destination that isn't present.
     */
    function configureDestination(uint32 destEid, bytes calldata options, bool enabled) external onlyOwner {
        OwnershipBridgeSenderStorage storage $ = _getOwnershipBridgeSenderStorage();

        if (enabled) {
            $.destOptions[destEid] = options;
            $.destinations.add(uint256(destEid));
            emit DestinationConfigured(destEid, options, true);
        } else {
            if (!$.destinations.remove(uint256(destEid))) revert DestinationAlreadyInState();
            delete $.destOptions[destEid];
            emit DestinationRemoved(destEid);
        }
    }

    /**
     * @notice Returns the list of currently configured destination EIDs.
     * @return Array of destination EIDs. Order matches `EnumerableSet` iteration (insertion
     *         order, modified by swap-and-pop on removal).
     */
    function getDestinations() external view returns (uint32[] memory) {
        EnumerableSet.UintSet storage set = _getOwnershipBridgeSenderStorage().destinations;
        uint256 len = set.length();
        uint32[] memory out = new uint32[](len);
        for (uint256 i = 0; i < len;) {
            out[i] = uint32(set.at(i));
            unchecked { ++i; }
        }
        return out;
    }

    /**
     * @notice Returns the per-destination LZ options configured for `destEid`.
     * @param destEid The destination LayerZero EID.
     * @return The configured options bytes (empty if not configured).
     */
    function getDestinationOptions(uint32 destEid) external view returns (bytes memory) {
        return _getOwnershipBridgeSenderStorage().destOptions[destEid];
    }

    // ------------------------------------------------------------------
    // Enable surface — toggles which destinations a safe's owner-changes broadcast to.
    // ------------------------------------------------------------------

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
    function enable(address safe, uint32 destEid) external {
        if (!_roleRegistry().hasRole(ETHER_FI_WALLET_ROLE, msg.sender)) revert OnlyEtherFiWallet();
        if (!etherFiDataProvider.isEtherFiSafe(safe)) revert NotEtherFiSafe();

        OwnershipBridgeSenderStorage storage $ = _getOwnershipBridgeSenderStorage();
        if (!$.destinations.contains(uint256(destEid))) revert DestinationNotConfigured(destEid);

        // `add` returns false on duplicate, preserving the existing idempotent semantics.
        if ($.enabledEids[safe].add(uint256(destEid))) {
            emit OwnershipBridgeEnabled(safe, destEid);
        }
    }

    /**
     * @notice Disables ownership bridging for a `(safe, destEid)` pair. Idempotent.
     * @dev Callable by `ETHER_FI_WALLET_ROLE` holders. Two uses:
     *      1) Explicit per-safe cleanup — a safe should no longer publish to this destination.
     *      2) Pruning stale entries — after the admin removes a destination globally via
     *         `configureDestination(..., false)`, that destination is automatically skipped
     *         on dispatch/quote, but this lets operators explicitly clear the bookkeeping.
     *
     *      Does NOT require `destEid` to still be in the global destinations set — the whole
     *      point is to be able to clean up stale enablements.
     * @param safe Safe whose enabled set is being trimmed.
     * @param destEid Destination LayerZero EID to disable.
     * @custom:throws OnlyEtherFiWallet If caller lacks `ETHER_FI_WALLET_ROLE`.
     */
    function disable(address safe, uint32 destEid) external {
        if (!_roleRegistry().hasRole(ETHER_FI_WALLET_ROLE, msg.sender)) revert OnlyEtherFiWallet();

        // `remove` returns false when the entry wasn't present, preserving idempotent semantics.
        if (_getOwnershipBridgeSenderStorage().enabledEids[safe].remove(uint256(destEid))) {
            emit OwnershipBridgeDisabled(safe, destEid);
        }
    }

    /**
     * @notice Returns whether ownership bridging has been enabled for a `(safe, destEid)` pair.
     * @param safe Safe address to query.
     * @param destEid Destination LayerZero EID to query.
     * @return True if enabled.
     */
    function isEnabled(address safe, uint32 destEid) external view returns (bool) {
        return _getOwnershipBridgeSenderStorage().enabledEids[safe].contains(uint256(destEid));
    }

    /**
     * @notice Returns the set of destination EIDs enabled for `safe`.
     * @param safe Safe address to query.
     * @return Array of destination EIDs the safe is enabled for. Order matches
     *         `EnumerableSet` iteration (insertion order, modified by swap-and-pop on removal).
     */
    function getEnabledDestinations(address safe) external view returns (uint32[] memory) {
        EnumerableSet.UintSet storage set = _getOwnershipBridgeSenderStorage().enabledEids[safe];
        uint256 len = set.length();
        uint32[] memory out = new uint32[](len);
        for (uint256 i = 0; i < len;) {
            out[i] = uint32(set.at(i));
            unchecked { ++i; }
        }
        return out;
    }

    /**
     * @notice Convenience view for the safe wiring: returns true iff a publish for `safe`
     *         would actually result in LZ sends.
     * @dev Folds in pause state, per-safe enabled-destination configuration, AND the global
     *      destinations set. A safe whose only enabled EID was later removed globally is
     *      NOT live — dispatch would silently skip it and produce zero sends.
     * @param safe Safe address to query.
     * @return True iff the safe has at least one enabled EID that is also globally
     *         configured, AND the sender is not paused.
     */
    function isPublishLive(address safe) external view returns (bool) {
        if (paused()) return false;
        return _liveEnabledEids(safe).length > 0;
    }

    // ------------------------------------------------------------------
    // Pause control via RoleRegistry.
    // ------------------------------------------------------------------

    /**
     * @notice Pauses the sender. Pausable accounts only (per RoleRegistry).
     * @dev While paused, every `publish*` reverts with `EnforcedPause`.
     */
    function pause() external {
        _roleRegistry().onlyPauser(msg.sender);
        _pause();
    }

    /**
     * @notice Unpauses the sender. Unpausable accounts only (per RoleRegistry).
     */
    function unpause() external {
        _roleRegistry().onlyUnpauser(msg.sender);
        _unpause();
    }

    /**
     * @dev Returns the active role registry via the data provider lookup.
     * @return The current `IRoleRegistry`.
     */
    function _roleRegistry() internal view returns (IRoleRegistry) {
        return IRoleRegistry(etherFiDataProvider.roleRegistry());
    }

    // ------------------------------------------------------------------
    // Internal: caller validation, dispatch loop, fee handling.
    // ------------------------------------------------------------------

    /**
     * @dev Gates a publish to the caller being a registered EtherFiSafe publishing about itself.
     * @param safe The safe address from the publish call.
     */
    modifier onlyEtherFiSafe(address safe) {
        if (msg.sender != safe) revert CallerNotSafe();
        if (!etherFiDataProvider.isEtherFiSafe(safe)) revert NotEtherFiSafe();
        _;
    }

    /**
     * @dev Short-circuits a publish when `safe` has no LIVE enabled destinations (the
     *      intersection of its enabled set with the global destinations set). Refunds the
     *      caller's `msg.value` and emits a skip event. Returns true so the caller can
     *      early-return.
     * @param safe Source-chain safe that attempted to publish.
     * @param kind Op kind that would have been published.
     * @return skipped True when the publish was short-circuited; the caller MUST return.
     */
    function _skipIfNotEnabled(address safe, OwnershipBridgeMessageLib.OpKind kind) internal returns (bool skipped) {
        if (_liveEnabledEids(safe).length != 0) return false;

        if (msg.value > 0) {
            (bool ok, ) = payable(msg.sender).call{ value: msg.value }("");
            if (!ok) revert RefundFailed();
        }
        emit OwnershipBridgeSkipped(safe, uint8(kind));
        return true;
    }

    /**
     * @dev Dispatches the envelope to every LIVE destination enabled for the safe. A safe's
     *      enabled set may contain stale EIDs after an admin globally removes a destination;
     *      this loop silently skips those instead of reverting, so a stale entry can never
     *      brick a safe's owner-mutating calls. Quotes per-destination, tracks `spent`
     *      against `msg.value`, sends each, and refunds the leftover.
     * @param safe Source safe whose state is changing; embedded in the envelope.
     * @param kind Operation discriminator.
     * @param opData Pre-encoded kind-specific payload.
     * @return guids LayerZero message GUIDs, one per LIVE destination, in iteration order.
     * @return destEids Destination LayerZero EIDs, parallel to `guids`.
     */
    function _dispatch(
        address safe,
        OwnershipBridgeMessageLib.OpKind kind,
        bytes memory opData
    ) internal returns (bytes32[] memory guids, uint32[] memory destEids) {
        OwnershipBridgeSenderStorage storage $ = _getOwnershipBridgeSenderStorage();
        uint32[] memory liveEids = _liveEnabledEids(safe);
        uint256 destCount = liveEids.length;

        bytes memory message = OwnershipBridgeMessageLib.encodeEnvelope(
            OwnershipBridgeMessageLib.Envelope({ kind: kind, safe: safe, opData: opData })
        );

        guids = new bytes32[](destCount);
        destEids = new uint32[](destCount);
        uint256 spent = 0;

        for (uint256 i = 0; i < destCount;) {
            uint32 destEid = liveEids[i];
            if (peers[destEid] == bytes32(0)) revert PeerNotConfigured(destEid);

            bytes memory opts = $.destOptions[destEid];
            MessagingFee memory fee = _quote(destEid, message, opts, false);
            uint256 nextSpent = spent + fee.nativeFee;
            if (nextSpent > msg.value) revert InsufficientFee(msg.value, nextSpent);
            spent = nextSpent;

            MessagingReceipt memory receipt = _lzSend(destEid, message, opts, MessagingFee(fee.nativeFee, 0), payable(msg.sender));
            guids[i] = receipt.guid;
            destEids[i] = destEid;

            unchecked { ++i; }
        }

        // Refund any leftover ETH to the caller (the safe). The safe is expected to forward
        // the refund to tx.origin in its wiring; that's a COR-732 concern.
        if (msg.value > spent) {
            (bool ok, ) = payable(msg.sender).call{ value: msg.value - spent }("");
            if (!ok) revert RefundFailed();
        }
    }

    /**
     * @dev Computes the total native LZ fee across LIVE destinations enabled for `safe`.
     *      Stale enabled EIDs (no longer in the global destinations set) are silently
     *      skipped — they contribute zero, just like they would on dispatch.
     * @param safe Source safe whose live enabled set is iterated.
     * @param kind Operation discriminator.
     * @param opData Pre-encoded payload.
     * @return totalFee Sum of per-destination native fees over live destinations.
     */
    function _quoteTotal(address safe, OwnershipBridgeMessageLib.OpKind kind, bytes memory opData) internal view returns (uint256 totalFee) {
        OwnershipBridgeSenderStorage storage $ = _getOwnershipBridgeSenderStorage();
        uint32[] memory liveEids = _liveEnabledEids(safe);
        uint256 destCount = liveEids.length;
        if (destCount == 0) return 0;

        bytes memory message = OwnershipBridgeMessageLib.encodeEnvelope(
            OwnershipBridgeMessageLib.Envelope({ kind: kind, safe: safe, opData: opData })
        );

        for (uint256 i = 0; i < destCount;) {
            uint32 destEid = liveEids[i];
            bytes memory opts = $.destOptions[destEid];
            MessagingFee memory fee = _quote(destEid, message, opts, false);
            totalFee += fee.nativeFee;
            unchecked { ++i; }
        }
    }

    /**
     * @dev Returns the intersection of `safe`'s enabled EIDs with the globally configured
     *      destinations set. Stale entries (admin removed the destination but the safe's
     *      enablement record persists) are filtered out so they're treated as no-ops by
     *      every downstream consumer (`isPublishLive`, `_quoteTotal`, `_dispatch`,
     *      `_skipIfNotEnabled`).
     * @param safe Safe whose live set to compute.
     * @return live Array of EIDs currently both enabled-for-safe and globally configured.
     */
    function _liveEnabledEids(address safe) internal view returns (uint32[] memory live) {
        OwnershipBridgeSenderStorage storage $ = _getOwnershipBridgeSenderStorage();
        EnumerableSet.UintSet storage enabled = $.enabledEids[safe];
        uint256 len = enabled.length();
        live = new uint32[](len);
        uint256 count = 0;
        for (uint256 i = 0; i < len; ) {
            uint32 eid = uint32(enabled.at(i));
            if ($.destinations.contains(uint256(eid))) {
                live[count] = eid;
                unchecked { ++count; }
            }
            unchecked { ++i; }
        }
        // Trim to actual live count.
        assembly { mstore(live, count) }
    }

    /**
     * @dev Overrides `OAppSender._payNative` so it does NOT require strict equality between
     *      `msg.value` and the per-send fee. We dispatch to multiple destinations in one
     *      call, sharing a single `msg.value`; the cumulative check + refund happens in
     *      `_dispatch`.
     * @param _nativeFee Per-send LZ native fee (already validated by `_dispatch`).
     * @return nativeFee The fee echoed back to `_lzSend` as the value forwarded to the endpoint.
     */
    function _payNative(uint256 _nativeFee) internal pure override returns (uint256 nativeFee) {
        return _nativeFee;
    }
}
