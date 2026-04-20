// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BinSponsor } from "./ICashModule.sol";

/**
 * @title ReleaseReason
 * @notice Reason for releasing a hold without a corresponding on-chain spend
 */
enum ReleaseReason {
    /// @notice Network reversal — provider reversed the transaction before settlement
    REVERSAL,
    /// @notice Admin release — operator-initiated hold removal (e.g. force-capture recovery)
    ADMIN
}

/**
 * @title HoldRecord
 * @notice Per-transaction hold entry stored in PendingHoldsModule
 */
struct HoldRecord {
    /// @notice Hold amount in USD with 1e6 denomination (same as USDC)
    uint256 amountUsd;
    /// @notice Timestamp when the hold was created
    uint40 createdAt;
    /// @notice 4-byte provider code derived from BinSponsor (e.g. "RAIN", "REAP")
    bytes4 providerCode;
    /// @notice True when added via forceAddHold — exempt from automatic expiry jobs
    bool forced;
}

/**
 * @title IPendingHoldsModule
 * @author ether.fi
 * @notice Interface for the on-chain pending holds registry.
 *
 * @dev Holds are identified by a provider-namespaced key:
 *      key = keccak256(abi.encode(safe, providerCode, txId))
 *
 *      Lifecycle:
 *        addHold()      — at transaction:created (auth-ack), called by EtherFi wallet (backend)
 *        removeHold()   — at settlement, called by CashModuleCore internally after spend()
 *        releaseHold()  — reversals or operator-initiated releases, called by EtherFi wallet
 *        forceAddHold() — force-capture / recovery path, operator-only, bypasses balance check
 *        updateHold()   — incremental auth adjustment, called by EtherFi wallet (backend)
 *
 *      Spendable invariant enforced at hold-write time:
 *        totalPendingHolds(safe) + newAmount <= rawSpendable(safe)
 *
 *      Provider-namespaced keys prevent txId collisions between Rain / Reap / PIX.
 *      Use providerCodeFromBinSponsor() to convert BinSponsor enum values to bytes4.
 */
interface IPendingHoldsModule {

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /**
     * @notice Emitted when a hold is added for a safe
     * @param safe Safe address the hold is placed on
     * @param providerCode 4-byte provider code (e.g. "RAIN")
     * @param txId Provider transaction identifier
     * @param amountUsd Hold amount in USD (1e6)
     * @param createdAt Block timestamp when the hold was created
     * @param forced True when the hold was added via forceAddHold (bypasses balance check)
     */
    event HoldAdded(
        address indexed safe,
        bytes4 indexed providerCode,
        bytes32 indexed txId,
        uint256 amountUsd,
        uint256 createdAt,
        bool forced
    );

    /**
     * @notice Emitted when a hold is removed following a successful on-chain spend
     * @param safe Safe address
     * @param providerCode 4-byte provider code
     * @param txId Provider transaction identifier
     * @param amountUsd Hold amount released in USD (1e6)
     * @param settledAt Block timestamp of removal
     */
    event HoldRemoved(
        address indexed safe,
        bytes4 indexed providerCode,
        bytes32 indexed txId,
        uint256 amountUsd,
        uint256 settledAt
    );

    /**
     * @notice Emitted when a hold is released without a corresponding spend (reversal or admin)
     * @param safe Safe address
     * @param providerCode 4-byte provider code
     * @param txId Provider transaction identifier
     * @param amountUsd Hold amount released in USD (1e6)
     * @param reason Why the hold was released
     * @param releasedAt Block timestamp of release
     */
    event HoldReleased(
        address indexed safe,
        bytes4 indexed providerCode,
        bytes32 indexed txId,
        uint256 amountUsd,
        ReleaseReason reason,
        uint256 releasedAt
    );

    /**
     * @notice Emitted when a hold amount is updated (incremental auth)
     * @param safe Safe address
     * @param providerCode 4-byte provider code
     * @param txId Provider transaction identifier
     * @param oldAmountUsd Previous hold amount in USD (1e6)
     * @param newAmountUsd New hold amount in USD (1e6)
     * @param updatedAt Block timestamp of the update
     */
    event HoldUpdated(
        address indexed safe,
        bytes4 indexed providerCode,
        bytes32 indexed txId,
        uint256 oldAmountUsd,
        uint256 newAmountUsd,
        uint256 updatedAt
    );

    /**
     * @notice Emitted when the CashModuleCore address is updated
     * @param oldCashModuleCore Previous CashModuleCore address
     * @param newCashModuleCore New CashModuleCore address
     */
    event CashModuleCoreSet(address oldCashModuleCore, address newCashModuleCore);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when a hold lookup returns no record
    error HoldNotFound();

    /// @notice Thrown when attempting to add a hold that already exists for the same key
    error DuplicateHold();

    /// @notice Thrown when the caller is not the registered CashModuleCore
    error OnlyCashModuleCore();

    /// @notice Thrown when an amount argument is zero
    error InvalidAmount();

    /// @notice Thrown when address(0) is passed as cashModuleCore
    error ZeroCashModuleCore();

    // -------------------------------------------------------------------------
    // Write functions — EtherFi wallet (backend) only
    // -------------------------------------------------------------------------

    /**
     * @notice Adds a pending hold for a safe at auth-ack time
     * @dev Immediately consumes amountUsd from the safe's daily/monthly spending limits
     *      so the limit reflects the user's authorized spend from the moment of auth-ack.
     *      Reverts with ExceededDailySpendingLimit or ExceededMonthlySpendingLimit if the
     *      hold would breach the limit.
     *      Only callable by EtherFi wallet (backend service wallet).
     * @param safe Safe address
     * @param providerCode 4-byte provider code (use providerCodeFromBinSponsor to convert)
     * @param txId Provider transaction identifier
     * @param amountUsd Amount to hold in USD (1e6)
     */
    function addHold(address safe, bytes4 providerCode, bytes32 txId, uint256 amountUsd) external;

    /**
     * @notice Adds a hold without checking the spendable balance (operator recovery path)
     * @dev Marks the hold as forced=true. Forced holds are exempt from automatic expiry.
     *      Emits HoldAdded with forced=true.
     *      Only callable by EtherFi wallet.
     * @param safe Safe address
     * @param providerCode 4-byte provider code (use providerCodeFromBinSponsor to convert)
     * @param txId Provider transaction identifier
     * @param amountUsd Amount to hold in USD (1e6)
     */
    function forceAddHold(address safe, bytes4 providerCode, bytes32 txId, uint256 amountUsd) external;

    /**
     * @notice Updates an existing hold amount atomically (incremental auth adjustment)
     * @dev If newAmountUsd > oldAmountUsd, consumes the delta from the spending limit immediately.
     *      If newAmountUsd < oldAmountUsd, credits the delta back to the spending limit.
     *      Only callable by EtherFi wallet (backend service wallet).
     * @param safe Safe address
     * @param providerCode 4-byte provider code
     * @param txId Provider transaction identifier
     * @param newAmountUsd New hold amount in USD (1e6)
     */
    function updateHold(address safe, bytes4 providerCode, bytes32 txId, uint256 newAmountUsd) external;

    /**
     * @notice Releases a hold without a corresponding spend (network reversal or admin action)
     * @dev Does NOT call spend() — only decrements the hold accumulator.
     *      Only callable by EtherFi wallet.
     * @param safe Safe address
     * @param providerCode 4-byte provider code
     * @param txId Provider transaction identifier
     * @param reason Why the hold is being released
     */
    function releaseHold(address safe, bytes4 providerCode, bytes32 txId, ReleaseReason reason) external;

    // -------------------------------------------------------------------------
    // Write functions — CashModuleCore only
    // -------------------------------------------------------------------------

    /**
     * @notice Syncs (or creates) a hold to match the settlement amount at on-chain settlement time
     * @dev Called by CashModuleCore inside spend() to align the hold with the actual settlement.
     *      - If a hold exists: updates hold.amountUsd to settlementAmount, adjusts totalHolds.
     *        Does NOT call back to CashModuleCore for limit accounting — Core handles limits
     *        directly using the returned (existed, wasForced, oldAmount) values.
     *      - If no hold: creates a forced hold (Settlement is KING — limit bypass).
     *      Only callable by CashModuleCore.
     * @param safe Safe address
     * @param binSponsor Bin sponsor for the card transaction
     * @param txId Provider transaction identifier
     * @param settlementAmount Settlement amount in USD (1e6)
     * @return existed True if a hold existed for this (safe, binSponsor, txId) before this call
     * @return wasForced True if the existing hold was forced (only meaningful when existed=true)
     * @return oldAmount The hold amount before this call (only meaningful when existed=true)
     */
    function settlementSyncHold(
        address safe,
        BinSponsor binSponsor,
        bytes32 txId,
        uint256 settlementAmount
    ) external returns (bool existed, bool wasForced, uint256 oldAmount);

    /**
     * @notice Updates a hold's amount to reflect remaining un-settled debt after a partial spend
     * @dev Called by CashModuleCore inside spend() when the safe had insufficient balance to
     *      cover the full settlement amount. The hold is reduced to `remaining` and marked
     *      forced so subsequent special-function calls do not double-charge the spending limit.
     *      Does NOT adjust the spending limit — the limit was fully charged at settlementSyncHold.
     *      Only callable by CashModuleCore.
     * @param safe Safe address
     * @param binSponsor Bin sponsor for the card transaction
     * @param txId Provider transaction identifier
     * @param remaining Remaining un-spent amount in USD (1e6); must be > 0
     */
    function settlementSetRemainingHold(
        address safe,
        BinSponsor binSponsor,
        bytes32 txId,
        uint256 remaining
    ) external;

    /**
     * @notice Removes a hold after a successful on-chain spend at settlement
     * @dev Must be called by CashModuleCore after spend() executes.
     *      Decrements totalHolds by the stored hold.amountUsd (not by the settlement amount).
     *      Accepts BinSponsor (not bytes4) because CashModuleCore already has binSponsor in
     *      scope in spend() — avoiding a providerCode conversion in Core saves precious bytecode.
     *      Only callable by CashModuleCore.
     * @param safe Safe address
     * @param binSponsor Bin sponsor for the card transaction
     * @param txId Provider transaction identifier
     */
    function removeHold(address safe, BinSponsor binSponsor, bytes32 txId) external;

    // -------------------------------------------------------------------------
    // Write functions — controller role
    // -------------------------------------------------------------------------

    /**
     * @notice Updates the CashModuleCore address
     * @dev Only callable by CASH_MODULE_CONTROLLER_ROLE.
     * @param cashModuleCore New CashModuleCore address
     */
    function setCashModuleCore(address cashModuleCore) external;

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /**
     * @notice Returns the sum of all active hold amounts for a safe (USD, 1e6)
     * @param safe Safe address
     * @return Total pending hold amount in USD (1e6)
     */
    function totalPendingHolds(address safe) external view returns (uint256);

    /**
     * @notice Returns the hold record for a specific transaction
     * @dev Returns a zero-struct (amountUsd=0, createdAt=0) if the hold does not exist.
     * @param safe Safe address
     * @param providerCode 4-byte provider code
     * @param txId Provider transaction identifier
     * @return hold The HoldRecord struct
     */
    function getHold(address safe, bytes4 providerCode, bytes32 txId) external view returns (HoldRecord memory hold);

    /**
     * @notice Returns the 4-byte provider code for a given BinSponsor
     * @dev Pure utility — callers use this to convert BinSponsor to the bytes4 used in hold keys.
     * @param binSponsor The bin sponsor enum value
     * @return providerCode 4-byte provider code (e.g. bytes4("RAIN"))
     */
    function providerCodeFromBinSponsor(BinSponsor binSponsor) external pure returns (bytes4 providerCode);

    /**
     * @notice Returns the registered CashModuleCore address
     * @return Address of the CashModuleCore contract
     */
    function cashModuleCore() external view returns (address);
}
