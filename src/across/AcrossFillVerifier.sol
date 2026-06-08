// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title AcrossFillVerifier
 * @author ether.fi
 * @notice Enforces on-chain that a destination Across fill actually delivers the user's
 *         expected output. Sandwiched inside the `actions[]` passed to Across's
 *         MulticallHandler: a `register` call before the swap snapshots the user's balance,
 *         an `assertFilled` call after asserts the realised delta meets the signed `minOut`.
 *         If `assertFilled` reverts, MulticallHandler reverts the whole fill and Across
 *         auto-refunds the source-chain deposit to the safe.
 */
contract AcrossFillVerifier {
    /// @dev High bit set on the snapshot slot to mark a `register` call ran. Picked so it
    ///      cannot collide with any plausible ERC20 balance — no supply approaches 2^255.
    uint256 private constant SENTINEL_BIT = 1 << 255;

    /// @notice Emitted by `register` so off-chain observers (BE order tracker, ops
    ///         dashboards) can see expected delivery terms for each fill.
    event Registered(address indexed user, address indexed token, uint256 minOut, uint256 snapshot);

    /// @notice Emitted by `assertFilled` on success, exposing the realised delivery delta.
    event Verified(address indexed user, address indexed token, uint256 delta);

    /// @notice Reverts when `assertFilled` runs without a prior matching `register` (or
    ///         after a previous successful `assertFilled` already consumed the registration).
    ///         Catches the BE-omits-the-sandwich grief vector.
    error NotRegistered();

    /// @notice Reverts when the realised balance delta on `user` is below `minOut`.
    error InsufficientFill(uint256 expected, uint256 actual);

    /**
     * @notice Snapshots the user's current `token` balance and the required `minOut` into
     *         transient storage for verification later in the same transaction.
     * @dev Idempotent within a tx for the same `(user, token)`: a later `register`
     *      overwrites the earlier snapshot — only the most recent values matter for
     *      `assertFilled`.
     * @param user Final recipient of the swap output (typically the user's safe).
     * @param token ERC20 the swap is expected to deliver.
     * @param minOut Minimum delta the user must receive.
     */
    function register(address user, address token, uint256 minOut) external {
        (bytes32 snapshotSlot, bytes32 minOutSlot) = _slots(user, token);
        uint256 snapshot = IERC20(token).balanceOf(user);
        uint256 packed = snapshot | SENTINEL_BIT;
        assembly ("memory-safe") {
            tstore(snapshotSlot, packed)
            tstore(minOutSlot, minOut)
        }
        emit Registered(user, token, minOut, snapshot);
    }

    /**
     * @notice Reverts unless `balanceOf(user, token) - snapshot >= minOut` for the snapshot
     *         + `minOut` written by a prior `register` in the same transaction. Consumes
     *         the registration on success so it cannot be re-used by a later
     *         `assertFilled` in the same tx.
     * @dev When called as the final action inside an Across `MulticallHandler` payload, a
     *      revert here causes the relayer's `fillV3Relay` tx to revert and Across to
     *      auto-refund the source-chain deposit.
     * @param user Final recipient to check.
     * @param token ERC20 to check.
     */
    function assertFilled(address user, address token) external {
        (bytes32 snapshotSlot, bytes32 minOutSlot) = _slots(user, token);
        uint256 packed;
        uint256 minOut;
        assembly ("memory-safe") {
            packed := tload(snapshotSlot)
            minOut := tload(minOutSlot)
        }
        if (packed & SENTINEL_BIT == 0) revert NotRegistered();

        uint256 snapshot = packed & ~SENTINEL_BIT;
        uint256 delta = IERC20(token).balanceOf(user) - snapshot;
        if (delta < minOut) revert InsufficientFill(minOut, delta);

        assembly ("memory-safe") {
            tstore(snapshotSlot, 0)
            tstore(minOutSlot, 0)
        }

        emit Verified(user, token, delta);
    }

    /// @dev Two transient slots per `(user, token)` derived from distinct hash domains so
    ///      collisions across `(user, token)` pairs are infeasible.
    function _slots(address user, address token) private pure returns (bytes32 snapshotSlot, bytes32 minOutSlot) {
        snapshotSlot = keccak256(abi.encode("AcrossFillVerifier.snapshot", user, token));
        minOutSlot = keccak256(abi.encode("AcrossFillVerifier.minOut", user, token));
    }
}
