// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IBoringOnChainQueue {
    /**
     * @param allowWithdraws Whether or not withdraws are allowed for this asset.
     * @param secondsToMaturity The time in seconds it takes for the asset to mature.
     * @param minimumSecondsToDeadline The minimum time in seconds a withdraw request must be valid for before it is expired
     * @param minDiscount The minimum discount allowed for a withdraw request.
     * @param maxDiscount The maximum discount allowed for a withdraw request.
     * @param minimumShares The minimum amount of shares that can be withdrawn.
     */
    struct WithdrawAsset {
        bool allowWithdraws;
        uint24 secondsToMaturity;
        uint24 minimumSecondsToDeadline;
        uint16 minDiscount;
        uint16 maxDiscount;
        uint96 minimumShares;
    }

    /**
     * @notice Gets the withdrawal config for the asset out
     * @param assetOut Address of asset out
     * @return WithdrawAsset struct
     */
    function withdrawAssets(address assetOut) external view returns (WithdrawAsset memory);

    /**
     * @notice Returns the boring vault address
     */
    function boringVault() external view returns (BoringVault);

    /**
     * @notice Request an on-chain withdraw.
     * @param assetOut The asset to withdraw.
     * @param amountOfShares The amount of shares to withdraw.
     * @param discount The discount to apply to the withdraw in bps.
     * @param secondsToDeadline The time in seconds the request is valid for.
     * @return requestId The request Id.
     */
    function requestOnChainWithdraw(address assetOut, uint128 amountOfShares, uint16 discount, uint24 secondsToDeadline) external returns (bytes32 requestId);
}

contract BoringVault {}