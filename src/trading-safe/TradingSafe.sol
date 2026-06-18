// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { TradingOwnerBridgeReceiver } from "./TradingOwnerBridgeReceiver.sol";

/**
 * @title TradingSafe
 * @author ether.fi
 * @notice Mainnet trading-account safe. Same shape as `EtherFiSafe` — passkey + recovery
 *         model, module-enabled — with `applyBridge*` functions (in
 *         `TradingOwnerBridgeReceiver`) that mirror owner-mutating operations from the
 *         source-chain (OP) safe.
 */
contract TradingSafe is TradingOwnerBridgeReceiver {
    using SafeERC20 for IERC20;

    /// @notice Reverts when `redirectToTopUp` is called by an address other than this safe's
    ///         `TradingSafeFactory`.
    error OnlyTradingSafeFactory();

    /**
     * @param _dataProvider Address of the `EtherFiDataProvider` on this chain.
     * @param _bridgeReceiver Address of the `OwnershipBridgeReceiver` permitted to call
     *        `applyBridge*` functions on instances of this safe.
     */
    constructor(address _dataProvider, address _bridgeReceiver) payable TradingOwnerBridgeReceiver(_dataProvider, _bridgeReceiver) {}

    /**
     * @notice Transfers `amount` of `token` to this safe's `topUp` address. The mirror of
     *         `TopUp.redirectToTradingSafe`: moves topup-supported assets Safe → TopUp.
     * @dev Callable ONLY by this safe's `TradingSafeFactory`. The factory carries the
     *      backend role check, the topup-supported-asset guard, and resolves `topUp` from
     *      its own deploy-time records, then emits the single canonical event — so this
     *      contract is a stateless transfer-executor with no event of its own.
     * @param token ERC20 to redirect.
     * @param topUp Destination TopUp address (resolved and supplied by the factory).
     * @param amount Amount to transfer.
     * @custom:throws OnlyTradingSafeFactory If the caller is not this chain's TradingSafeFactory.
     */
    function redirectToTopUp(address token, address topUp, uint256 amount) external {
        if (msg.sender != dataProvider.getEtherFiSafeFactory()) revert OnlyTradingSafeFactory();
        IERC20(token).safeTransfer(topUp, amount);
    }
}
