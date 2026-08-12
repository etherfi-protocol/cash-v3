// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { TradingSafeWithdrawModule } from "../../src/trading-safe/TradingSafeWithdrawModule.sol";
import { TradingAccountCreate3, TradingAccountProdConfig as C } from "./TradingAccountProdConfig.sol";

/**
 * @notice Permissionlessly deploys the Ethereum production `TradingSafeWithdrawModule` via Nick's
 *         CREATE3 factory, alongside the rest of the prod trading stack.
 * @dev Deploy only. The module does nothing until the Operating Safe registers it as a default
 *      module on the data provider — run `scripts/gnosis-txs/TradingSafeWithdrawEth3CP.s.sol` for
 *      that bundle. Mainnet only: OP TradingSafes exit through the CashModule's delayed withdrawal.
 *
 * Usage:
 *   source .env && forge script scripts/trading-account/DeployTradingSafeWithdrawModuleProd.s.sol \
 *     --rpc-url $MAINNET_RPC --broadcast --verify
 */
contract DeployTradingSafeWithdrawModuleProd is Script, TradingAccountCreate3 {
    function run() external {
        require(block.chainid == 1, "must run on Ethereum");
        require(C.NICKS_FACTORY.code.length > 0, "Nick's factory not deployed");

        address dataProvider = _predict(C.SALT_DATA_PROVIDER_PROXY);
        require(dataProvider.code.length > 0, "EtherFiDataProvider not deployed");

        vm.startBroadcast();
        address module = _deployCreate3(abi.encodePacked(type(TradingSafeWithdrawModule).creationCode, abi.encode(dataProvider)), C.SALT_TRADING_SAFE_WITHDRAW_MODULE);
        vm.stopBroadcast();

        // The data provider is an immutable in the module's code, and a module bound to the wrong one
        // would pass every registration check and then fail on the first withdrawal.
        require(address(TradingSafeWithdrawModule(module).etherFiDataProvider()) == dataProvider, "data provider mismatch");

        string memory path = "./deployments/mainnet/1/trading-account.json";
        vm.writeJson(string.concat("\"", vm.toString(module), "\""), path, ".TradingSafeWithdrawModule");

        console2.log("TradingSafeWithdrawModule", module);
        console2.log("EtherFiDataProvider", dataProvider);
        console2.log("Wrote", path);
    }
}
