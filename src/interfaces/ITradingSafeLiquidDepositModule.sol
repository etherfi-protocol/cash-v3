// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ITradingSafeLiquidDepositModule {
    struct DepositRequest {
        address safe;
        address assetToDeposit;
        address liquidAsset;
        uint256 amountToDeposit;
        uint256 minReturn;
        uint256 deadline;
    }

    /// @notice Emitted after newly minted Liquid vault shares are forwarded to the safe's TopUp.
    /// @param safe TradingSafe whose input asset was deposited.
    /// @param topUp Factory-bound TopUp that received the shares.
    /// @param assetToDeposit ERC20 debited from the TradingSafe.
    /// @param liquidAsset Liquid vault share token minted and forwarded.
    /// @param amountToDeposit Exact input amount debited.
    /// @param liquidAssetAmount Exact shares minted and forwarded.
    event DepositedToTopUp(address indexed safe, address indexed topUp, address indexed assetToDeposit, address liquidAsset, uint256 amountToDeposit, uint256 liquidAssetAmount);

    /// @notice Emitted when a Liquid vault and its teller are configured.
    event LiquidAssetsAdded(address[] liquidAssets, address[] tellers);
    /// @notice Emitted when Liquid vault routes are removed.
    event LiquidAssetsRemoved(address[] liquidAssets);

    /// @notice Reverts when an amount is zero.
    error InvalidAmount();
    /// @notice Reverts when the minimum output is zero.
    error InvalidMinReturn();
    /// @notice Reverts for zero, mismatched, or otherwise invalid route configuration.
    error InvalidConfiguration();
    /// @notice Reverts when a requested Liquid vault has no configured teller.
    error UnsupportedLiquidAsset();
    /// @notice Reverts when parallel configuration arrays have different lengths.
    error ConfigArrayLengthMismatch();
    /// @notice Reverts when an empty route array is supplied.
    error EmptyArray();
    /// @notice Reverts when route administration is attempted without the required role.
    error Unauthorized();
    /// @notice Reverts when the owner authorization has expired.
    error DepositExpired();
    /// @notice Reverts when the safe holds less than the requested input amount.
    error InsufficientBalance();
    /// @notice Reverts when minted shares are below the signed minimum.
    error InsufficientReturnAmount();
    /// @notice Reverts when the selected teller does not accept the selected input asset.
    error DepositAssetNotAllowed();
    /// @notice Reverts when the teller enforces a nonzero share-lock, which would trap the
    ///         freshly minted shares in the safe and block the same-transaction forward.
    error SharesLocked();
    /// @notice Reverts when the factory has no TopUp address recorded for the safe.
    error NoTopUpAddress();
    /// @notice Reverts when the input debited from the safe is not exactly the signed amount.
    error DepositTransferFailed();
    /// @notice Reverts when the TopUp was not credited exactly the minted shares.
    error TopUpCreditFailed();
    // InvalidSignature() comes from ModuleBase; redeclaring here would collide on inheritance.

    /**
     * @notice Deposits an ERC20 accepted by a configured Liquid vault's teller and forwards only
     *         the newly minted shares to the safe's factory-bound TopUp.
     * @param request Signed route, amount, slippage, and deadline parameters.
     * @param signers Safe owner addresses that signed the authorization.
     * @param signatures Signatures from `signers` over the deposit digest.
     */
    function depositToTopUp(DepositRequest calldata request, address[] calldata signers, bytes[] calldata signatures) external;

    /// @notice Adds or replaces validated Liquid vault → teller routes.
    function addLiquidAssets(address[] calldata liquidAssets, address[] calldata tellers) external;

    /// @notice Removes configured Liquid vault routes.
    function removeLiquidAssets(address[] calldata liquidAssets) external;
}
