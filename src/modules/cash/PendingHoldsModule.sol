// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BinSponsor } from "../../interfaces/ICashModule.sol";
import { HoldRecord, IPendingHoldsModule, ReleaseReason } from "../../interfaces/IPendingHoldsModule.sol";
import { ModuleBase } from "../ModuleBase.sol";
import { UpgradeableProxy } from "../../utils/UpgradeableProxy.sol";

/**
 * @title PendingHoldsModule
 * @author ether.fi
 * @notice On-chain registry of pending card transaction holds for EtherFi Safes.
 *
 * @dev Architecture:
 *   - Pure registry: stores holds, sums them per safe, emits rich indexed events.
 *   - Zero spend() logic: CashModuleCore owns settlement; it calls removeHold() after spend().
 *   - Spendable invariant: spendable(safe) = rawSpendable(safe) - totalPendingHolds(safe)
 *   - Hold keys are provider-namespaced: keccak256(abi.encode(safe, providerCode, txId))
 *     This prevents txId collisions across Rain / Reap / PIX namespaces.
 *
 * @dev Hold lifecycle:
 *   transaction:created  → addHold(safe, providerCode, txId, amountUsd)  [EtherFi wallet]
 *   settlement           → removeHold(safe, providerCode, txId)          [CashModuleCore only]
 *   network reversal     → releaseHold(..., REVERSAL)                    [EtherFi wallet]
 *   operator recovery    → releaseHold(..., ADMIN)                       [EtherFi wallet]
 *   force-capture        → forceAddHold(...)                             [EtherFi wallet]
 *   incremental auth     → updateHold(safe, providerCode, txId, newAmt)  [EtherFi wallet]
 *
 * @dev Two-removal-path invariant (R19):
 *   removeHold()  — post-spend path, called only by CashModuleCore
 *   releaseHold() — non-spend path (reversals / admin), called only by EtherFi wallet
 *   These are structurally separate: no hold can be removed without one of these explicit calls.
 */
contract PendingHoldsModule is UpgradeableProxy, ModuleBase, IPendingHoldsModule {

    // -------------------------------------------------------------------------
    // ERC-7201 namespaced storage
    // -------------------------------------------------------------------------

    /**
     * @dev Storage structure for PendingHoldsModule.
     * @custom:storage-location erc7201:etherfi.storage.PendingHoldsModuleStorage
     */
    struct PendingHoldsModuleStorage {
        /// @notice Per-hold records keyed by keccak256(abi.encode(safe, providerCode, txId))
        mapping(bytes32 holdKey => HoldRecord record) holds;
        /// @notice Running sum of active hold amounts per safe in USD (1e6)
        mapping(address safe => uint256 totalHolds) totalHolds;
        /// @notice Address of CashModuleCore — the only contract that can call removeHold()
        address cashModuleCore;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.PendingHoldsModuleStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PendingHoldsModuleStorageLocation =
        0x0042c358db30ed9f9b20b913b4f4622ef177b2464108d9b113967b28b46ada00;

    // -------------------------------------------------------------------------
    // Role constants
    // -------------------------------------------------------------------------

    /// @notice Role identifier for EtherFi wallet (backend service wallet)
    bytes32 public constant ETHER_FI_WALLET_ROLE = keccak256("ETHER_FI_WALLET_ROLE");

    /// @notice Role identifier for Cash Module controller (admin configuration)
    bytes32 public constant CASH_MODULE_CONTROLLER_ROLE = keccak256("CASH_MODULE_CONTROLLER_ROLE");

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address _etherFiDataProvider) ModuleBase(_etherFiDataProvider) {
        _disableInitializers();
    }

    // -------------------------------------------------------------------------
    // Initializer
    // -------------------------------------------------------------------------

    /**
     * @notice Initializes the PendingHoldsModule proxy
     * @param _roleRegistry Address of the role registry
     * @param _cashModuleCore Address of CashModuleCore (used for onlyCashModuleCore gating)
     */
    function initialize(address _roleRegistry, address _cashModuleCore) external initializer {
        if (_cashModuleCore == address(0)) revert ZeroCashModuleCore();
        __UpgradeableProxy_init(_roleRegistry);
        _getPendingHoldsModuleStorage().cashModuleCore = _cashModuleCore;
        emit CashModuleCoreSet(address(0), _cashModuleCore);
    }

    // -------------------------------------------------------------------------
    // Storage accessor
    // -------------------------------------------------------------------------

    function _getPendingHoldsModuleStorage() internal pure returns (PendingHoldsModuleStorage storage $) {
        assembly {
            $.slot := PendingHoldsModuleStorageLocation
        }
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /**
     * @dev Restricts access to the registered CashModuleCore contract only.
     *      Used by removeHold() — the only path Core can remove a hold.
     */
    modifier onlyCashModuleCore() {
        if (_getPendingHoldsModuleStorage().cashModuleCore != msg.sender) revert OnlyCashModuleCore();
        _;
    }

    /**
     * @dev Restricts access to accounts holding the EtherFi wallet role.
     *      Used by addHold(), forceAddHold(), updateHold(), releaseHold().
     */
    modifier onlyEtherFiWallet() {
        if (!roleRegistry().hasRole(ETHER_FI_WALLET_ROLE, msg.sender)) revert Unauthorized();
        _;
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /**
     * @dev Computes the provider-namespaced hold key for a (safe, providerCode, txId) tuple.
     *      Namespacing prevents txId collisions between different bin providers (Rain/Reap/PIX).
     */
    function _holdKey(address safe, bytes4 providerCode, bytes32 txId) internal pure returns (bytes32) {
        return keccak256(abi.encode(safe, providerCode, txId));
    }

    // -------------------------------------------------------------------------
    // Write functions — EtherFi wallet only
    // -------------------------------------------------------------------------

    /// @inheritdoc IPendingHoldsModule
    function addHold(address safe, bytes4 providerCode, bytes32 txId, uint256 amountUsd)
        external
        whenNotPaused
        nonReentrant
        onlyEtherFiWallet
    {
        if (amountUsd == 0) revert InvalidAmount();

        bytes32 key = _holdKey(safe, providerCode, txId);
        PendingHoldsModuleStorage storage $ = _getPendingHoldsModuleStorage();

        if ($.holds[key].createdAt != 0) revert DuplicateHold();

        // Consume from the spending limit at auth-ack time so the limit immediately reflects
        // the user's authorized spend. Reverts with ExceededDailySpendingLimit or
        // ExceededMonthlySpendingLimit if the hold would breach the limit.
        ICashModuleForHolds($.cashModuleCore).consumeSpendingLimit(safe, amountUsd);

        $.holds[key] = HoldRecord({
            amountUsd: amountUsd,
            createdAt: uint40(block.timestamp),
            providerCode: providerCode,
            forced: false
        });
        $.totalHolds[safe] += amountUsd;

        emit HoldAdded(safe, providerCode, txId, amountUsd, block.timestamp, false);
    }

    /// @inheritdoc IPendingHoldsModule
    function forceAddHold(address safe, bytes4 providerCode, bytes32 txId, uint256 amountUsd)
        external
        whenNotPaused
        nonReentrant
        onlyEtherFiWallet
    {
        if (amountUsd == 0) revert InvalidAmount();

        bytes32 key = _holdKey(safe, providerCode, txId);
        PendingHoldsModuleStorage storage $ = _getPendingHoldsModuleStorage();

        if ($.holds[key].createdAt != 0) revert DuplicateHold();

        // No balance check for forced holds (operator recovery path)
        $.holds[key] = HoldRecord({
            amountUsd: amountUsd,
            createdAt: uint40(block.timestamp),
            providerCode: providerCode,
            forced: true
        });
        $.totalHolds[safe] += amountUsd;

        emit HoldAdded(safe, providerCode, txId, amountUsd, block.timestamp, true);
    }

    /// @inheritdoc IPendingHoldsModule
    function updateHold(address safe, bytes4 providerCode, bytes32 txId, uint256 newAmountUsd)
        external
        whenNotPaused
        nonReentrant
        onlyEtherFiWallet
    {
        if (newAmountUsd == 0) revert InvalidAmount();

        bytes32 key = _holdKey(safe, providerCode, txId);
        PendingHoldsModuleStorage storage $ = _getPendingHoldsModuleStorage();

        HoldRecord storage record = $.holds[key];
        if (record.createdAt == 0) revert HoldNotFound();

        uint256 oldAmountUsd = record.amountUsd;

        if (newAmountUsd > oldAmountUsd) {
            // Increasing hold — consume delta from the spending limit immediately.
            // Non-forced holds were originally charged at addHold; charge only the delta.
            // Forced holds bypassed the limit at creation; charge the full delta now.
            uint256 delta = newAmountUsd - oldAmountUsd;
            if (!record.forced) ICashModuleForHolds($.cashModuleCore).consumeSpendingLimit(safe, delta);
            $.totalHolds[safe] = $.totalHolds[safe] - oldAmountUsd + newAmountUsd;
        } else {
            // Decreasing hold — credit delta back to the spending limit for non-forced holds.
            // Apply the same defensive floor as releaseHold/removeHold to guard against any
            // totalHolds drift (e.g., caused by a prior forceAddHold + forceSpend sequence).
            uint256 delta = oldAmountUsd - newAmountUsd;
            if (!record.forced) ICashModuleForHolds($.cashModuleCore).releaseSpendingLimit(safe, delta);
            uint256 current = $.totalHolds[safe];
            $.totalHolds[safe] = (oldAmountUsd <= current ? current - oldAmountUsd : 0) + newAmountUsd;
        }

        record.amountUsd = newAmountUsd;

        emit HoldUpdated(safe, providerCode, txId, oldAmountUsd, newAmountUsd, block.timestamp);
    }

    /// @inheritdoc IPendingHoldsModule
    function releaseHold(address safe, bytes4 providerCode, bytes32 txId, ReleaseReason reason)
        external
        whenNotPaused
        nonReentrant
        onlyEtherFiWallet
    {
        bytes32 key = _holdKey(safe, providerCode, txId);
        PendingHoldsModuleStorage storage $ = _getPendingHoldsModuleStorage();

        HoldRecord storage record = $.holds[key];
        if (record.createdAt == 0) revert HoldNotFound();

        uint256 holdAmount = record.amountUsd;
        bool wasForced = record.forced;
        uint256 current = $.totalHolds[safe];
        $.totalHolds[safe] = holdAmount <= current ? current - holdAmount : 0;

        delete $.holds[key];

        // Credit back the spending limit for non-forced holds (forced holds never consumed it).
        if (!wasForced) ICashModuleForHolds($.cashModuleCore).releaseSpendingLimit(safe, holdAmount);

        emit HoldReleased(safe, providerCode, txId, holdAmount, reason, block.timestamp);
    }

    // -------------------------------------------------------------------------
    // Write functions — CashModuleCore only
    // -------------------------------------------------------------------------

    /// @inheritdoc IPendingHoldsModule
    function settlementSyncHold(
        address safe,
        BinSponsor binSponsor,
        bytes32 txId,
        uint256 settlementAmount
    ) external nonReentrant onlyCashModuleCore returns (bool existed, bool wasForced, uint256 oldAmount) {
        if (settlementAmount == 0) revert InvalidAmount();

        bytes4 providerCode = providerCodeFromBinSponsor(binSponsor);
        bytes32 key = _holdKey(safe, providerCode, txId);
        PendingHoldsModuleStorage storage $ = _getPendingHoldsModuleStorage();
        HoldRecord storage record = $.holds[key];

        if (record.createdAt != 0) {
            // Hold exists — sync to settlement amount. Limit accounting is handled by Core
            // using the returned (existed, wasForced, oldAmount) values; no callback needed.
            oldAmount = record.amountUsd;
            wasForced = record.forced;
            existed = true;

            if (settlementAmount != oldAmount) {
                if (settlementAmount > oldAmount) {
                    $.totalHolds[safe] = $.totalHolds[safe] - oldAmount + settlementAmount;
                } else {
                    uint256 current = $.totalHolds[safe];
                    $.totalHolds[safe] = (oldAmount <= current ? current - oldAmount : 0) + settlementAmount;
                }
                record.amountUsd = settlementAmount;
                emit HoldUpdated(safe, providerCode, txId, oldAmount, settlementAmount, block.timestamp);
            }
            // existed/wasForced/oldAmount already set above; Solidity returns them.
        } else {
            // No hold — create a forced hold. Settlement is KING: bypass spending limit.
            $.holds[key] = HoldRecord({
                amountUsd: settlementAmount,
                createdAt: uint40(block.timestamp),
                providerCode: providerCode,
                forced: true
            });
            $.totalHolds[safe] += settlementAmount;
            emit HoldAdded(safe, providerCode, txId, settlementAmount, block.timestamp, true);
            // existed=false, wasForced=false, oldAmount=0 (Solidity zero-initialises returns)
        }
    }

    /// @inheritdoc IPendingHoldsModule
    function settlementSetRemainingHold(
        address safe,
        BinSponsor binSponsor,
        bytes32 txId,
        uint256 remaining
    ) external nonReentrant onlyCashModuleCore {
        bytes4 providerCode = providerCodeFromBinSponsor(binSponsor);
        bytes32 key = _holdKey(safe, providerCode, txId);
        PendingHoldsModuleStorage storage $ = _getPendingHoldsModuleStorage();

        HoldRecord storage record = $.holds[key];
        if (record.createdAt == 0) revert HoldNotFound();

        uint256 oldAmount = record.amountUsd;
        uint256 current = $.totalHolds[safe];
        $.totalHolds[safe] = (oldAmount <= current ? current - oldAmount : 0) + remaining;
        record.amountUsd = remaining;
        // Mark forced so the special-function path does not double-charge the spending limit.
        // The limit was already fully charged for the settlement amount at settlementSyncHold.
        record.forced = true;

        emit HoldUpdated(safe, providerCode, txId, oldAmount, remaining, block.timestamp);
    }

    /// @inheritdoc IPendingHoldsModule
    function removeHold(address safe, BinSponsor binSponsor, bytes32 txId)
        external
        nonReentrant
        onlyCashModuleCore
    {
        bytes4 providerCode = providerCodeFromBinSponsor(binSponsor);
        bytes32 key = _holdKey(safe, providerCode, txId);
        PendingHoldsModuleStorage storage $ = _getPendingHoldsModuleStorage();

        HoldRecord storage record = $.holds[key];
        if (record.createdAt == 0) revert HoldNotFound();

        uint256 holdAmount = record.amountUsd;
        uint256 current = $.totalHolds[safe];
        $.totalHolds[safe] = holdAmount <= current ? current - holdAmount : 0;

        delete $.holds[key];

        emit HoldRemoved(safe, providerCode, txId, holdAmount, block.timestamp);
    }

    // -------------------------------------------------------------------------
    // Write functions — controller role
    // -------------------------------------------------------------------------

    /// @inheritdoc IPendingHoldsModule
    function setCashModuleCore(address _cashModuleCore) external {
        if (!roleRegistry().hasRole(CASH_MODULE_CONTROLLER_ROLE, msg.sender)) revert Unauthorized();
        if (_cashModuleCore == address(0)) revert ZeroCashModuleCore();

        PendingHoldsModuleStorage storage $ = _getPendingHoldsModuleStorage();
        address old = $.cashModuleCore;
        $.cashModuleCore = _cashModuleCore;

        emit CashModuleCoreSet(old, _cashModuleCore);
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @inheritdoc IPendingHoldsModule
    function totalPendingHolds(address safe) external view returns (uint256) {
        return _getPendingHoldsModuleStorage().totalHolds[safe];
    }

    /// @inheritdoc IPendingHoldsModule
    function getHold(address safe, bytes4 providerCode, bytes32 txId)
        external
        view
        returns (HoldRecord memory hold)
    {
        bytes32 key = _holdKey(safe, providerCode, txId);
        return _getPendingHoldsModuleStorage().holds[key];
    }

    /// @inheritdoc IPendingHoldsModule
    function cashModuleCore() external view returns (address) {
        return _getPendingHoldsModuleStorage().cashModuleCore;
    }

    /// @inheritdoc IPendingHoldsModule
    function providerCodeFromBinSponsor(BinSponsor binSponsor) public pure returns (bytes4) {
        if (binSponsor == BinSponsor.Reap)      return bytes4("REAP");
        if (binSponsor == BinSponsor.Rain)      return bytes4("RAIN");
        if (binSponsor == BinSponsor.PIX)       return bytes4("PIX_");
        if (binSponsor == BinSponsor.CardOrder) return bytes4("CORD");
        revert InvalidInput();
    }
}

// -------------------------------------------------------------------------
// Minimal callback interface: PendingHoldsModule → CashModuleCore
// -------------------------------------------------------------------------

/**
 * @dev Minimal slice of CashModule that PendingHoldsModule calls back on for
 *      limit consumption and release at hold creation/release time.
 *
 *      consumeSpendingLimit() and releaseSpendingLimit() live in CashModuleSetters and are
 *      routed transparently via CashModuleCore's fallback() delegatecall.
 *      Defined here to avoid a circular import.
 */
interface ICashModuleForHolds {
    /**
     * @notice Validates and increments the safe's daily/monthly limits by amountUsd.
     *         Reverts with ExceededDailySpendingLimit or ExceededMonthlySpendingLimit
     *         if the amount would breach the limit.
     */
    function consumeSpendingLimit(address safe, uint256 amountUsd) external;

    /**
     * @notice Credits amountUsd back to the safe's daily/monthly limits.
     *         Applies a floor at 0 to handle day/month-boundary crossings safely.
     */
    function releaseSpendingLimit(address safe, uint256 amountUsd) external;
}
