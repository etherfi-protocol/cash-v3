// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IOneInchSwapModule
 * @notice Minimal external interface for the OneInchSwapModule that other protocol contracts
 *         (EtherFiSafe.isValidSignature binding, DebtManagerCore.liquidate guard) depend on.
 */
interface IOneInchSwapModule {
    struct PendingSwap {
        address fromToken;
        address toToken;
        uint256 fromAmount;
        uint256 minToAmount;
        bytes32 orderHash;
    }

    /// @notice 1inch Aggregation Router address used by the module
    function aggregationRouter() external view returns (address);

    /// @notice 1inch Fusion `SimpleSettlement` extension address. Authorized caller of
    ///         `postInteraction` when the BE constructs a Settlement-routed Fusion order
    ///         (Settlement chains into us via FeeTaker's trailing-target pattern). For plain-LOP
    ///         orders, LOP calls `postInteraction` directly and `msg.sender == aggregationRouter`.
    function settlementContract() external view returns (address);

    /// @notice Returns the pending Fusion swap for a Safe (zeros when none)
    function getPendingSwap(address safe) external view returns (PendingSwap memory);

    /// @notice True when the Safe has an in-flight swap that must block liquidations
    function swapInProgress(address safe) external view returns (bool);
}
