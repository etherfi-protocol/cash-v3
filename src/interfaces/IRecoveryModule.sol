// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IRecoveryModule {
    struct PendingRecovery {
        address token;
        uint256 amount;
        address recipient;
        uint32 destEid;
        uint64 unlockAt;
        bool executed;
        bool cancelled;
    }

    event RecoveryRequested(
        address indexed safe,
        bytes32 indexed id,
        address indexed token,
        uint256 amount,
        address recipient,
        uint32 destEid,
        uint64 unlockAt
    );
    event RecoveryExecuted(address indexed safe, bytes32 indexed id, bytes32 lzGuid);
    event RecoveryCancelled(address indexed safe, bytes32 indexed id);

    error RecoveryNotFound();
    error RecoveryAlreadyFinalized();
    error RecoveryStillLocked();
    error InvalidDestEid();
    error InvalidRecipient();
    error InvalidAmount();
    // `InvalidSignature()` is inherited from `ModuleBase` and is exposed in the
    // compiled `RecoveryModule` ABI. Not declared here to avoid a
    // multiple-inheritance collision with `ModuleBase.InvalidSignature`.

    function requestRecovery(
        address safe,
        address token,
        uint256 amount,
        address recipient,
        uint32 destEid,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external returns (bytes32 id);

    function executeRecovery(address safe, bytes32 id, bytes calldata lzOptions) external payable;

    function cancelRecovery(
        address safe,
        bytes32 id,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external;

    function quoteExecute(
        address safe,
        bytes32 id,
        bytes calldata lzOptions
    ) external view returns (uint256 nativeFee);

    function getRecovery(address safe, bytes32 id) external view returns (PendingRecovery memory);
    function TIMELOCK() external view returns (uint64);
}
