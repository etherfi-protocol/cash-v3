// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console2 } from "forge-std/console2.sol";

import { TradingSafeLiquidDepositModule } from "../../src/trading-safe/TradingSafeLiquidDepositModule.sol";
import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { TradingAccountCreate3, TradingAccountProdConfig as C } from "./TradingAccountProdConfig.sol";

/**
 * @notice Checks the live production module against a local rebuild.
 * @dev Read-only. The route is constructor storage, not bytecode; the only immutable is the data provider.
 *
 * Usage:
 *   source .env && forge script scripts/trading-account/VerifyTradingSafeLiquidDepositModuleProd.s.sol \
 *     --rpc-url $MAINNET_RPC
 */
contract VerifyTradingSafeLiquidDepositModuleProd is Script, TradingAccountCreate3, ContractCodeChecker {
    using stdJson for string;

    address private constant LIQUID_BTC = 0x5f46d540b6eD704C3c8789105F30E075AA900726;
    address private constant LIQUID_BTC_TELLER = 0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353;

    function run() external {
        require(block.chainid == 1, "must run on Ethereum");

        address dataProvider = _predict(C.SALT_DATA_PROVIDER_PROXY);
        address module = _predict(C.SALT_TRADING_SAFE_LIQUID_DEPOSIT_MODULE);
        string memory manifest = vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet/1/trading-account.json"));

        require(module == manifest.readAddress(".TradingSafeLiquidDepositModule"), "manifest module is not the CREATE3 address");
        require(dataProvider == manifest.readAddress(".EtherFiDataProvider"), "manifest data provider mismatch");
        require(module.code.length > 0, "module not deployed");

        address[] memory liquidAssets = new address[](1);
        liquidAssets[0] = LIQUID_BTC;
        address[] memory tellers = new address[](1);
        tellers[0] = LIQUID_BTC_TELLER;
        requireExactCodeMatch("TradingSafeLiquidDepositModule", module, address(new TradingSafeLiquidDepositModule(liquidAssets, tellers, dataProvider)));

        TradingSafeLiquidDepositModule deployed = TradingSafeLiquidDepositModule(module);
        require(address(deployed.etherFiDataProvider()) == dataProvider, "data provider mismatch");
        require(address(deployed.liquidAssetToTeller(LIQUID_BTC)) == LIQUID_BTC_TELLER, "Liquid BTC route mismatch");

        console2.log("TradingSafeLiquidDepositModule verified:", module);
    }
}
