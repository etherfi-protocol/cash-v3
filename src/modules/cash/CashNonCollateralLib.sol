// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { IDebtManager } from "../../interfaces/IDebtManager.sol";
import { ILendGateway } from "../../interfaces/ILendGateway.sol";
import { EnumerableAddressWhitelistLib } from "../../libraries/EnumerableAddressWhitelistLib.sol";
import { CashModuleStorageContract } from "./CashModuleStorageContract.sol";

/**
 * @title CashNonCollateralLib
 * @notice The CashModule's non-collateral asset registry: supported assets that back no borrowing and are not
 *         card-spendable, so user withdrawals made up only of them skip the withdrawal delay.
 * @dev Deployed once and linked into CashModuleSetters, so this logic does not count against the
 *      implementation's EIP-170 runtime code-size limit. Every function runs via delegatecall in the
 *      CashModule's storage context.
 * @author ether.fi
 */
library CashNonCollateralLib {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    // Mirrors CashModule's error selector-for-selector, so reverts from the library are indistinguishable
    // from reverts thrown in the module itself.
    error InvalidNonCollateralAsset(address asset);

    /**
     * @notice Adds or removes assets from the non-collateral registry and emits NonCollateralAssetsConfigured
     * @dev An asset can only be registered while it sits in no lending set on either engine.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param assets Array of asset addresses to configure
     * @param shouldRegister Array of booleans suggesting whether to register the assets
     * @custom:throws InvalidNonCollateralAsset if a registered asset is gateway-registered or a DebtManager collateral or borrow token
     */
    function configure(CashModuleStorageContract.CashModuleStorage storage $, address[] calldata assets, bool[] calldata shouldRegister) external {
        EnumerableAddressWhitelistLib.configure($.nonCollateralAssets, assets, shouldRegister);

        uint256 len = assets.length;
        for (uint256 i = 0; i < len;) {
            if (shouldRegister[i] && _isLendingAsset($, assets[i])) revert InvalidNonCollateralAsset(assets[i]);
            unchecked {
                ++i;
            }
        }

        $.cashEventEmitter.emitNonCollateralAssetsConfigured(assets, shouldRegister);
    }

    /**
     * @notice The delay applied to a user withdrawal request
     * @dev The lending sets are re-read so an asset listed for lending after registration falls back to the delay.
     * @param $ The CashModule storage (passed by the delegatecalling module)
     * @param tokens Tokens in the request
     * @return Zero when every token is a registered non-collateral asset; otherwise the global withdrawal delay
     */
    function userWithdrawalDelay(CashModuleStorageContract.CashModuleStorage storage $, address[] calldata tokens) external view returns (uint64) {
        uint256 len = tokens.length;
        if (len == 0) return $.withdrawalDelay;
        for (uint256 i = 0; i < len;) {
            if (!$.nonCollateralAssets.contains(tokens[i]) || _isLendingAsset($, tokens[i])) return $.withdrawalDelay;
            unchecked {
                ++i;
            }
        }
        return 0;
    }

    /// @dev True if `asset` is in a lending set on either engine: a gateway reserve (covers collateral, borrow and
    ///      spend assets) or a DebtManager collateral or borrow token.
    function _isLendingAsset(CashModuleStorageContract.CashModuleStorage storage $, address asset) private view returns (bool) {
        ILendGateway gateway = $.gateway;
        if (address(gateway) != address(0) && gateway.isRegistered(asset)) return true;
        IDebtManager debtManager = $.debtManager;
        return debtManager.isCollateralToken(asset) || debtManager.isBorrowToken(asset);
    }
}
