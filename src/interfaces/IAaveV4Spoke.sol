// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IAaveV4Spoke
 * @notice The slice of the Aave v4 Spoke that the Gateway calls.
 * @author ether.fi
 */
interface IAaveV4Spoke {
    /// @notice EIP-712 intent to approve/revoke position managers for `onBehalfOf` in one signed message
    struct SetUserPositionManagers {
        address onBehalfOf;
        PositionManagerUpdate[] updates;
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice A single approve/revoke entry within a SetUserPositionManagers intent
    struct PositionManagerUpdate {
        address positionManager;
        bool approve;
    }

    /// @notice Reserve-level data. ABI-mirrored: `hub` is `IHubBase` upstream, `flags` is `ReserveFlags` (uint8).
    struct Reserve {
        address underlying;
        address hub;
        uint16 assetId;
        uint8 decimals;
        uint24 collateralRisk;
        uint8 flags;
        uint32 dynamicConfigKey;
    }

    /// @notice Dynamic reserve config. `collateralFactor` is the LTV in BPS (10_000 = 100%).
    struct DynamicReserveConfig {
        uint16 collateralFactor;
        uint32 maxLiquidationBonus;
        uint16 liquidationFee;
    }

    /// @notice A user's aggregate position. `healthFactor`/`avgCollateralFactor` are WAD; value fields are Aave Value units.
    struct UserAccountData {
        uint256 riskPremium;
        uint256 avgCollateralFactor;
        uint256 healthFactor;
        uint256 totalCollateralValue;
        uint256 totalDebtValueRay;
        uint256 activeCollateralCount;
        uint256 borrowCount;
    }

    // ---------------------------------------------------------------------
    // Position operations (caller must be `onBehalfOf` or an approved manager)
    // ---------------------------------------------------------------------

    /// @notice Supplies `amount` of the reserve's underlying to `onBehalfOf`. Pulls the asset from the caller.
    /// @return sharesSupplied The amount of supply shares minted
    /// @return assetsSupplied The amount of underlying supplied
    function supply(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256 sharesSupplied, uint256 assetsSupplied);

    /// @notice Withdraws `amount` of the reserve's underlying from `onBehalfOf` to the caller. `type(uint256).max` withdraws all.
    /// @return sharesWithdrawn The amount of supply shares burned
    /// @return assetsWithdrawn The amount of underlying withdrawn
    function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256 sharesWithdrawn, uint256 assetsWithdrawn);

    /// @notice Borrows `amount` of the reserve's underlying against `onBehalfOf`'s position, sending it to the caller.
    /// @return sharesBorrowed The amount of debt shares minted
    /// @return assetsBorrowed The amount of underlying borrowed
    function borrow(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256 sharesBorrowed, uint256 assetsBorrowed);

    /// @notice Repays `amount` of `onBehalfOf`'s debt in the reserve. Pulls the asset from the caller. `type(uint256).max` repays all.
    /// @return sharesRepaid The amount of debt shares burned
    /// @return assetsRepaid The amount of underlying repaid
    function repay(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256 sharesRepaid, uint256 assetsRepaid);

    /// @notice Toggles whether `onBehalfOf`'s supply in the reserve counts as collateral.
    function setUsingAsCollateral(uint256 reserveId, bool usingAsCollateral, address onBehalfOf) external;

    // ---------------------------------------------------------------------
    // Position-manager registration & approval
    // ---------------------------------------------------------------------

    /// @notice Governance-only: globally activates/deactivates a position manager on the Spoke.
    function updatePositionManager(address positionManager, bool active) external;

    /// @notice Called by a user (the position holder) to approve/revoke a position manager for itself.
    function setUserPositionManager(address positionManager, bool approve) external;

    /// @notice Approves/revokes position managers for `params.onBehalfOf` via an EIP-712 signature over `params`.
    function setUserPositionManagersWithSig(SetUserPositionManagers calldata params, bytes calldata signature) external;

    // ---------------------------------------------------------------------
    // Reads
    // ---------------------------------------------------------------------

    /// @notice True if `positionManager` has been activated by governance.
    function isPositionManagerActive(address positionManager) external view returns (bool);

    /// @notice True if `positionManager` is active AND approved by `user`.
    function isPositionManager(address user, address positionManager) external view returns (bool);

    /// @notice The user's aggregate account data (see struct). `healthFactor` is WAD.
    function getUserAccountData(address user) external view returns (UserAccountData memory);

    /// @notice Underlying assets `user` has supplied to the reserve, in asset units.
    function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256);

    /// @notice Whether the reserve is enabled as collateral by `user`, and whether it is borrowed by `user`.
    function getUserReserveStatus(uint256 reserveId, address user) external view returns (bool enabledAsCollateral, bool borrowed);

    /// @notice Total debt (drawn + premium) of `user` in the reserve, in asset units.
    function getUserTotalDebt(uint256 reserveId, address user) external view returns (uint256);

    /// @notice Total underlying supplied to the reserve, in asset units.
    function getReserveSuppliedAssets(uint256 reserveId) external view returns (uint256);

    /// @notice Total debt (drawn + premium) of the reserve, in asset units.
    function getReserveTotalDebt(uint256 reserveId) external view returns (uint256);

    /// @notice The reserve's stored data, including `underlying`, `decimals`, and current `dynamicConfigKey`.
    function getReserve(uint256 reserveId) external view returns (Reserve memory);

    /// @notice The dynamic config (incl. `collateralFactor` in BPS) at `dynamicConfigKey`.
    function getDynamicReserveConfig(uint256 reserveId, uint32 dynamicConfigKey) external view returns (DynamicReserveConfig memory);

    /// @notice The type hash for the SetUserPositionManagers EIP-712 intent.
    function SET_USER_POSITION_MANAGERS_TYPEHASH() external view returns (bytes32);

    /// @notice The AaveOracle address used by this Spoke.
    function ORACLE() external view returns (address);
}
