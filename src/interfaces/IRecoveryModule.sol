// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IRecoveryModule {
    event RecoverySent(
        address indexed safe,
        bytes32 indexed lzGuid,
        address indexed token,
        uint256 amount,
        address recipient,
        uint32 destEid
    );

    error InvalidDestEid();
    error InvalidRecipient();
    error InvalidAmount();
    error InvalidToken();
    /// @notice Thrown when the contract fails to refund unused `msg.value` to the caller.
    error RefundFailed();
    // `InvalidSignature()` is inherited from `ModuleBase` and is exposed in the
    // compiled `RecoveryModule` ABI. Not declared here to avoid a
    // multiple-inheritance collision with `ModuleBase.InvalidSignature`.

    function recover(
        address safe,
        address token,
        uint256 amount,
        address recipient,
        uint32 destEid,
        bytes calldata lzOptions,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external payable returns (bytes32 lzGuid);

    function quote(
        address safe,
        address token,
        uint256 amount,
        address recipient,
        uint32 destEid,
        bytes calldata lzOptions
    ) external view returns (uint256 nativeFee);
}
