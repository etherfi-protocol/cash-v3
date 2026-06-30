// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ISafeAssetRecoveryModule {
    /// @notice Emitted after an unsupported token's full balance is swept out of the safe.
    event AssetRecovered(
        address indexed safe,
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

    error InvalidRecipient();
    error InvalidToken();
    error OnlySupportedTokensCannotBeRecovered();
    error NoBalanceToRecover();
    error RecoveryTransferFailed();
    error RecoveryExpired();
    // InvalidSignature() comes from ModuleBase; redeclaring here would collide on inheritance.

    function recover(
        address safe,
        address token,
        address recipient,
        uint256 deadline,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external;
}
