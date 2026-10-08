// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IAssetRecoveryModule {
    event RecoverySent(
        address indexed safe,
        bytes32 indexed lzGuid,
        address indexed token,
        address recipient,
        uint32 destEid
    );

    error InvalidDestEid();
    error InvalidRecipient();
    error InvalidToken();
    error RefundFailed();
    error RecoveryExpired();
    // InvalidSignature() comes from ModuleBase; redeclaring here would collide on inheritance.

    function recover(
        address safe,
        address token,
        address recipient,
        bytes32 safeSalt,
        uint32 destEid,
        uint256 deadline,
        bytes calldata lzOptions,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external payable returns (bytes32 lzGuid);
}
