// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { ILayerZeroTeller } from "../../src/interfaces/ILayerZeroTeller.sol";
import { TradingSafeLiquidDepositModule } from "../../src/trading-safe/TradingSafeLiquidDepositModule.sol";
import { TradingAccountCreate3, TradingAccountProdConfig as C } from "./TradingAccountProdConfig.sol";

/**
 * @notice Permissionlessly deploys the Ethereum production `TradingSafeLiquidDepositModule` via Nick's
 *         CREATE3 factory, alongside the rest of the prod trading stack.
 * @dev Deploy only. The module does nothing until the Operating Safe registers it as a default
 *      module on the data provider — run `scripts/gnosis-txs/TradingSafeLiquidDepositEth3CP.s.sol`
 *      for that bundle. The constructor configures the WBTC → Liquid BTC teller; later routes are
 *      a separate admin call. Mainnet only: the shares land on the factory-bound TopUp and the
 *      existing sweep bridges them to Optimism.
 *
 * Usage:
 *   source .env && forge script scripts/trading-account/DeployTradingSafeLiquidDepositModuleProd.s.sol \
 *     --rpc-url $MAINNET_RPC --broadcast --verify
 */
contract DeployTradingSafeLiquidDepositModuleProd is Script, TradingAccountCreate3 {
    function run() external {
        require(block.chainid == 1, "must run on Ethereum");
        require(C.NICKS_FACTORY.code.length > 0, "Nick's factory not deployed");

        address dataProvider = _predict(C.SALT_DATA_PROVIDER_PROXY);
        require(dataProvider.code.length > 0, "EtherFiDataProvider not deployed");
        require(address(ILayerZeroTeller(C.LIQUID_BTC_TELLER).vault()) == C.LIQUID_BTC, "teller vault is not Liquid BTC");

        vm.startBroadcast();
        address module = _deployCreate3(_creationCode(dataProvider), C.SALT_TRADING_SAFE_LIQUID_DEPOSIT_MODULE);
        vm.stopBroadcast();

        // The data provider is an immutable in the module's code, and a module bound to the wrong one
        // would pass every registration check and then fail on the first deposit.
        TradingSafeLiquidDepositModule deployed = TradingSafeLiquidDepositModule(module);
        require(address(deployed.etherFiDataProvider()) == dataProvider, "data provider mismatch");
        require(address(deployed.liquidAssetToTeller(C.LIQUID_BTC)) == C.LIQUID_BTC_TELLER, "Liquid BTC route mismatch");

        string memory path = "./deployments/mainnet/1/trading-account.json";
        vm.writeJson(string.concat("\"", vm.toString(module), "\""), path, ".TradingSafeLiquidDepositModule");

        console2.log("TradingSafeLiquidDepositModule", module);
        console2.log("EtherFiDataProvider", dataProvider);
        console2.log("Wrote", path);
    }

    function _creationCode(address dataProvider) internal pure returns (bytes memory) {
        address[] memory liquidAssets = new address[](1);
        liquidAssets[0] = C.LIQUID_BTC;
        address[] memory tellers = new address[](1);
        tellers[0] = C.LIQUID_BTC_TELLER;
        return abi.encodePacked(type(TradingSafeLiquidDepositModule).creationCode, abi.encode(liquidAssets, tellers, dataProvider));
    }
}
