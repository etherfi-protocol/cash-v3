// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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
    /**
     * @param _dataProvider Address of the `EtherFiDataProvider` on this chain.
     * @param _bridgeReceiver Address of the `OwnershipBridgeReceiver` permitted to call
     *        `applyBridge*` functions on instances of this safe.
     */
    constructor(address _dataProvider, address _bridgeReceiver) payable TradingOwnerBridgeReceiver(_dataProvider, _bridgeReceiver) {}
}
