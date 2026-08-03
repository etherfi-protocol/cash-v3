// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ITradingSafeWithdrawModule {
    /// @notice Emitted after an exact `amount` of `token` is withdrawn from the safe to `recipient`.
    event Withdrawn(address indexed safe, address indexed token, address indexed recipient, uint256 amount);

    /// @notice Reverts when `withdraw` is called with the zero token address.
    error InvalidToken();
    /// @notice Reverts when `withdraw` is called with the zero recipient address.
    error InvalidRecipient();
    /// @notice Reverts when `withdraw` is called with a zero amount.
    error InvalidAmount();
    /// @notice Reverts when the owner authorization has expired.
    error WithdrawExpired();
    /// @notice Reverts when the safe holds fewer than `amount` tokens.
    error InsufficientBalance();
    /// @notice Reverts when the safe's balance did not decrease by exactly `amount`.
    error WithdrawTransferFailed();
    // InvalidSignature() comes from ModuleBase; redeclaring here would collide on inheritance.

    /**
     * @notice Withdraws an exact `amount` of `token` from `safe` to `recipient`, immediately.
     * @param safe TradingSafe to withdraw from. Must be deployed by the TradingSafeFactory.
     * @param token ERC20 to withdraw.
     * @param recipient Destination for the withdrawn tokens.
     * @param amount Exact amount to debit from the safe.
     * @param deadline Unix timestamp after which the owner authorization is void.
     * @param signers Safe owner addresses that signed the authorization.
     * @param signatures Signatures from `signers` over the withdrawal digest.
     */
    function withdraw(address safe, address token, address recipient, uint256 amount, uint256 deadline, address[] calldata signers, bytes[] calldata signatures) external;
}
