// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ITradingSafeWithdrawModule {
    /// @notice Emitted once per token after an exact `amount` of `token` is withdrawn from the safe to `recipient`.
    event Withdrawn(address indexed safe, address indexed token, address indexed recipient, uint256 amount);

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
    /// @notice Reverts when `tokens` is empty.
    error EmptyWithdrawal();
    /// @notice Reverts when the same token appears more than once in `tokens`.
    error DuplicateToken();
    // InvalidSignature() and ArrayLengthMismatch() come from ModuleBase; redeclaring here would collide on inheritance.

    /**
     * @notice Withdraws exact `amounts` of `tokens` from `safe` to `recipient`, immediately, in a
     *         single owner-quorum-signed batch.
     * @param safe TradingSafe to withdraw from. Must be deployed by the TradingSafeFactory.
     * @param tokens ERC20s to withdraw. Must be non-empty and free of duplicates.
     * @param amounts Exact amount to debit from the safe per token; positionally paired with `tokens`.
     * @param recipient Destination for all withdrawn tokens.
     * @param deadline Unix timestamp after which the owner authorization is void.
     * @param signers Safe owner addresses that signed the authorization.
     * @param signatures Signatures from `signers` over the withdrawal digest.
     */
    function withdraw(address safe, address[] calldata tokens, uint256[] calldata amounts, address recipient, uint256 deadline, address[] calldata signers, bytes[] calldata signatures) external;
}
