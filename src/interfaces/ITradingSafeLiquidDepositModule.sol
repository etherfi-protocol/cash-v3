// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ITradingSafeLiquidDepositModule {
    /// @notice Emitted once per successful deposit after the freshly minted Liquid BTC has been
    ///         forwarded to the safe's TopUp address.
    /// @param safe The TradingSafe whose WBTC was deposited.
    /// @param topUp The destination TopUp address the Liquid BTC was sent to.
    /// @param wbtcAmount Exact WBTC debited from the safe.
    /// @param liquidBtcAmount Liquid BTC minted by the deposit and forwarded to `topUp`.
    event DepositedToTopUp(address indexed safe, address indexed topUp, uint256 wbtcAmount, uint256 liquidBtcAmount);

    /// @notice Reverts when `wbtcAmount` is zero.
    error InvalidAmount();
    /// @notice Reverts when `minLiquidBtc` is zero.
    error InvalidMinReturn();
    /// @notice Reverts when the constructor is given a zero WBTC / Liquid BTC / teller address.
    error InvalidConfiguration();
    /// @notice Reverts when the owner authorization has expired.
    error DepositExpired();
    /// @notice Reverts when the safe holds fewer than `wbtcAmount` WBTC.
    error InsufficientBalance();
    /// @notice Reverts when the Liquid BTC minted is below `minLiquidBtc`.
    error InsufficientReturnAmount();
    /// @notice Reverts when the teller does not currently allow WBTC deposits.
    error DepositAssetNotAllowed();
    /// @notice Reverts when the teller enforces a nonzero share-lock, which would trap the
    ///         freshly minted Liquid BTC in the safe and block the same-tx forward.
    error SharesLocked();
    /// @notice Reverts when the factory has no TopUp address recorded for the safe.
    error NoTopUpAddress();
    /// @notice Reverts when the WBTC debited from the safe is not exactly `wbtcAmount`.
    error DepositTransferFailed();
    /// @notice Reverts when the TopUp was not credited exactly the minted Liquid BTC.
    error TopUpCreditFailed();
    // InvalidSignature() comes from ModuleBase; redeclaring here would collide on inheritance.

    /**
     * @notice Deposits `wbtcAmount` of the safe's WBTC into Liquid BTC and forwards the newly
     *         minted Liquid BTC to the safe's factory-bound TopUp address, immediately, in a
     *         single owner-quorum-signed operation.
     * @param safe TradingSafe to deposit from. Must be deployed by the TradingSafeFactory.
     * @param wbtcAmount Exact WBTC amount to deposit.
     * @param minLiquidBtc Minimum acceptable Liquid BTC to mint (slippage bound).
     * @param deadline Unix timestamp after which the owner authorization is void.
     * @param signers Safe owner addresses that signed the authorization.
     * @param signatures Signatures from `signers` over the deposit digest.
     */
    function depositToTopUp(address safe, uint256 wbtcAmount, uint256 minLiquidBtc, uint256 deadline, address[] calldata signers, bytes[] calldata signatures) external;
}
