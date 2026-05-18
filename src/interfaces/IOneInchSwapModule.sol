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

    /// @notice Returns the pending Fusion swap for a Safe (zeros when none)
    function getPendingSwap(address safe) external view returns (PendingSwap memory);

    /// @notice True when the Safe has an in-flight swap that must block liquidations
    function swapInProgress(address safe) external view returns (bool);
}
