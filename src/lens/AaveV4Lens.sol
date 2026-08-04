// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IAaveV4Hub } from "../interfaces/IAaveV4Hub.sol";
import { IAaveV4Oracle } from "../interfaces/IAaveV4Oracle.sol";
import { IAaveV4Spoke } from "../interfaces/IAaveV4Spoke.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title AaveV4Lens
 * @notice Read-only aggregator over an Aave v4 spoke: one call returns everything the cash
 *         backend needs for markets / user borrow data. The spoke is a call argument (the
 *         oracle is discovered via `spoke.ORACLE()`, the hub per reserve), so the same lens serves
 *         any Aave v4 instance on this chain — test and official — without redeployment.
 * @dev UUPS-upgradeable behind the standard ether.fi UpgradeableProxy (RoleRegistry-gated
 *      upgrades) so the read surface can evolve with aave-v4 without the backend chasing a new
 *      address. Holds no state of its own.
 * @author ether.fi
 */
contract AaveV4Lens is UpgradeableProxy {
    /// @notice Per-reserve market data. Field order is load-bearing (mirrored by the backend ABI).
    struct ReserveData {
        uint256 reserveId;
        address underlying;
        uint8 decimals;
        string symbol;
        bool paused;
        bool frozen;
        bool borrowable;
        uint16 collateralFactorBps;
        uint256 suppliedAssets;
        uint256 totalDebt;
        uint256 drawnRateRay;
        uint16 liquidityFeeBps;
        uint256 price;
    }

    /// @notice Per-reserve user position data. Field order is load-bearing (mirrored by the backend ABI).
    struct UserReserveData {
        uint256 reserveId;
        address underlying;
        uint256 suppliedAssets;
        uint256 totalDebt;
        bool usingAsCollateral;
        bool borrowed;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
    }

    /// @notice Aggregates market-wide data for every listed reserve of `spoke`.
    function getMarketData(IAaveV4Spoke spoke) external view returns (ReserveData[] memory data) {
        uint256 count = spoke.getReserveCount();

        uint256[] memory ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = i;
        }
        uint256[] memory prices = IAaveV4Oracle(spoke.ORACLE()).getReservesPrices(ids);

        data = new ReserveData[](count);
        for (uint256 i; i < count; ++i) {
            IAaveV4Spoke.Reserve memory reserve = spoke.getReserve(i);
            IAaveV4Spoke.ReserveConfig memory config = spoke.getReserveConfig(i);
            IAaveV4Spoke.DynamicReserveConfig memory dynamicConfig = spoke.getDynamicReserveConfig(i, reserve.dynamicConfigKey);
            IAaveV4Hub hub = IAaveV4Hub(reserve.hub);

            data[i] = ReserveData({
                reserveId: i,
                underlying: reserve.underlying,
                decimals: reserve.decimals,
                symbol: IERC20Metadata(reserve.underlying).symbol(),
                paused: config.paused,
                frozen: config.frozen,
                borrowable: config.borrowable,
                collateralFactorBps: dynamicConfig.collateralFactor,
                suppliedAssets: spoke.getReserveSuppliedAssets(i),
                totalDebt: spoke.getReserveTotalDebt(i),
                drawnRateRay: hub.getAssetDrawnRate(reserve.assetId),
                liquidityFeeBps: hub.getAssetConfig(reserve.assetId).liquidityFee,
                price: prices[i]
            });
        }
    }

    /// @notice Aggregates `user`'s account data and per-reserve position on `spoke`.
    function getUserData(
        IAaveV4Spoke spoke,
        address user
    ) external view returns (IAaveV4Spoke.UserAccountData memory account, UserReserveData[] memory reserves) {
        account = spoke.getUserAccountData(user);

        uint256 count = spoke.getReserveCount();
        reserves = new UserReserveData[](count);
        for (uint256 i; i < count; ++i) {
            IAaveV4Spoke.Reserve memory reserve = spoke.getReserve(i);
            (bool usingAsCollateral, bool borrowed) = spoke.getUserReserveStatus(i, user);
            reserves[i] = UserReserveData({
                reserveId: i,
                underlying: reserve.underlying,
                suppliedAssets: spoke.getUserSuppliedAssets(i, user),
                totalDebt: spoke.getUserTotalDebt(i, user),
                usingAsCollateral: usingAsCollateral,
                borrowed: borrowed
            });
        }
    }
}
