// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @notice One token's leg of a withdrawal.
 * @param token ERC20 to debit from the safe.
 * @param amount Exact amount to debit, denominated in the token the safe holds — i.e. vault
 *        shares when `unwrap` is set, not the underlying amount the recipient ends up with.
 * @param unwrap Whether to redeem `token` as an ERC-4626 vault so the recipient receives the
 *        underlying asset instead of the wrapper.
 */
struct Withdrawal {
    address token;
    uint256 amount;
    bool unwrap;
}

interface ITradingSafeWithdrawModule {
    /// @notice Emitted once per token after an exact `amount` of `token` is debited from the safe for `recipient`.
    /// @dev For an unwrapped withdrawal `token` is still the wrapper and `amount` the shares burned — this
    ///      event always describes what left the safe. The accompanying `Unwrapped` names what the recipient got.
    event Withdrawn(address indexed safe, address indexed token, address indexed recipient, uint256 amount);
    /// @notice Emitted when `shares` of `wrapper` were redeemed so that `recipient` receives `underlying` instead.
    event Unwrapped(address indexed safe, address indexed wrapper, address indexed recipient, address underlying, uint256 shares);

    /// @notice Reverts when `withdraw` is called with the zero token address.
    error InvalidToken();
    /// @notice Reverts when `withdraw` is called with the zero recipient address.
    error InvalidRecipient();
    /// @notice Reverts when `withdraw` is called with a zero amount.
    error InvalidAmount();
    /// @notice Reverts when the owner authorization has expired.
    error WithdrawExpired();
    /// @notice Reverts when the safe holds fewer than `amount` of a token.
    error InsufficientBalance();
    /// @notice Reverts when a token's balance did not decrease by exactly `amount`.
    error WithdrawTransferFailed();
    /// @notice Reverts when `withdrawals` is empty.
    error EmptyWithdrawal();
    /// @notice Reverts when the same token appears in more than one withdrawal.
    error DuplicateToken();
    /// @notice Reverts when unwrapping was requested for a token that is not an ERC-4626 vault.
    error NotUnwrappable();
    // InvalidSignature() comes from ModuleBase; redeclaring here would collide on inheritance.

    /**
     * @notice Withdraws exact amounts of one or more ERC20s from `safe` to `recipient`, immediately,
     *         in a single owner-quorum-signed batch.
     * @param safe TradingSafe to withdraw from. Must be deployed by the TradingSafeFactory.
     * @param withdrawals Per-token legs of the withdrawal. Must be non-empty and free of duplicate tokens.
     * @param recipient Destination for everything withdrawn.
     * @param deadline Unix timestamp after which the owner authorization is void.
     * @param signers Safe owner addresses that signed the authorization.
     * @param signatures Signatures from `signers` over the withdrawal digest.
     */
    function withdraw(address safe, Withdrawal[] calldata withdrawals, address recipient, uint256 deadline, address[] calldata signers, bytes[] calldata signatures) external;
}
