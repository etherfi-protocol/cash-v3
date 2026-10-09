// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console2 } from "forge-std/console2.sol";

import { AcrossSwapModule } from "../../src/across/AcrossSwapModule.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { EnsoSwapModule } from "../../src/enso/EnsoSwapModule.sol";
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { OpenOceanSwapModule } from "../../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { TradingAccountCreate3, TradingAccountProdConfig as C } from "./TradingAccountProdConfig.sol";

/**
 * @notice Permissionlessly deploys the trade recipient guard and trading withdraw path contracts via
 *         Nick's CREATE3 factory. Deploy only: the proxies are upgraded and the module delays are set
 *         by a separate 3CP.
 * @dev Optimism: CashModuleCore, CashModuleSetters, CashEventEmitter, AcrossSwapModule, EnsoSwapModule
 *      and a new OpenOceanSwapModule (not a proxy). Ethereum: AcrossSwapModule and EnsoSwapModule.
 *      Constructor dependencies are read off the live proxies. Enso and Across share a salt across
 *      chains, so both chains land the same implementation address despite different data providers.
 *
 * Run once per chain:
 *   source .env && forge script scripts/trading-account/DeployTradeWithdrawPathImplsProd.s.sol \
 *     --rpc-url $OPTIMISM_RPC --broadcast --verify
 *   source .env && forge script scripts/trading-account/DeployTradeWithdrawPathImplsProd.s.sol \
 *     --rpc-url $MAINNET_RPC --broadcast --verify
 */
contract DeployTradeWithdrawPathImplsProd is Script, TradingAccountCreate3 {
    using stdJson for string;

    bytes32 internal constant SALT_ACROSS_IMPL = keccak256("TradingAccount.Prod.v1.AcrossSwapModuleImplTradeWithdrawPath");
    bytes32 internal constant SALT_ENSO_IMPL = keccak256("TradingAccount.Prod.v1.EnsoSwapModuleImplTradeWithdrawPath");
    bytes32 internal constant SALT_CASH_MODULE_CORE_IMPL = keccak256("Cash.Prod.CashModuleCoreImplTradeWithdrawPath");
    bytes32 internal constant SALT_CASH_MODULE_SETTERS_IMPL = keccak256("Cash.Prod.CashModuleSettersImplTradeWithdrawPath");
    bytes32 internal constant SALT_CASH_EVENT_EMITTER_IMPL = keccak256("Cash.Prod.CashEventEmitterImplTradeWithdrawPath");
    bytes32 internal constant SALT_OPEN_OCEAN_MODULE = keccak256("Cash.Prod.OpenOceanSwapModuleTradeWithdrawPath");

    function run() external {
        require(block.chainid == 1 || block.chainid == 10, "unsupported chain");
        require(C.NICKS_FACTORY.code.length > 0, "Nick's factory not deployed");

        address tradingSafeFactory = _predict(C.SALT_TRADING_SAFE_FACTORY_PROXY);
        address acrossProxy = _predict(C.SALT_ACROSS_PROXY);
        address ensoProxy = _predict(C.SALT_ENSO_PROXY);
        require(acrossProxy.code.length > 0 && ensoProxy.code.length > 0, "swap module proxies not deployed");

        address dataProvider = address(EnsoSwapModule(ensoProxy).etherFiDataProvider());
        require(address(AcrossSwapModule(acrossProxy).etherFiDataProvider()) == dataProvider, "swap module data providers differ");
        if (block.chainid == 1) {
            require(EtherFiDataProvider(dataProvider).getEtherFiSafeFactory() == tradingSafeFactory, "Ethereum data provider is not on the TradingSafeFactory");
        }

        string memory key = "trade-withdraw-path";
        vm.startBroadcast();
        address acrossImpl = _deployCreate3(abi.encodePacked(type(AcrossSwapModule).creationCode, abi.encode(dataProvider, tradingSafeFactory)), SALT_ACROSS_IMPL);
        address ensoImpl = _deployCreate3(abi.encodePacked(type(EnsoSwapModule).creationCode, abi.encode(dataProvider, tradingSafeFactory)), SALT_ENSO_IMPL);
        vm.serializeAddress(key, "AcrossSwapModuleImpl", acrossImpl);
        string memory json = vm.serializeAddress(key, "EnsoSwapModuleImpl", ensoImpl);
        if (block.chainid == 10) json = _deployCashContracts(key, dataProvider);
        vm.stopBroadcast();

        require(address(AcrossSwapModule(acrossImpl).etherFiDataProvider()) == dataProvider, "Across data provider mismatch");
        require(address(EnsoSwapModule(ensoImpl).etherFiDataProvider()) == dataProvider, "Enso data provider mismatch");

        string memory path = string.concat("./deployments/mainnet/", vm.toString(block.chainid), "/trade-withdraw-path.json");
        vm.writeJson(json, path);
        console2.log("TradingSafeFactory", tradingSafeFactory);
        console2.log("Wrote", path);
    }

    function _deployCashContracts(string memory key, address dataProvider) internal returns (string memory json) {
        string memory deployments = vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet/10/deployments.json"));
        address cashModule = deployments.readAddress(".addresses.CashModule");
        address oldOpenOcean = deployments.readAddress(".addresses.OpenOceanSwapModule");
        require(deployments.readAddress(".addresses.EtherFiDataProvider") == dataProvider, "Optimism data provider mismatch");
        require(EtherFiDataProvider(dataProvider).getCashModule() == cashModule, "data provider cash module mismatch");
        address openOceanRouter = OpenOceanSwapModule(oldOpenOcean).swapRouter();

        address core = _deployCreate3(abi.encodePacked(type(CashModuleCore).creationCode, abi.encode(dataProvider)), SALT_CASH_MODULE_CORE_IMPL);
        address setters = _deployCreate3(abi.encodePacked(type(CashModuleSetters).creationCode, abi.encode(dataProvider)), SALT_CASH_MODULE_SETTERS_IMPL);
        address emitter = _deployCreate3(abi.encodePacked(type(CashEventEmitter).creationCode, abi.encode(cashModule)), SALT_CASH_EVENT_EMITTER_IMPL);
        address openOcean = _deployCreate3(abi.encodePacked(type(OpenOceanSwapModule).creationCode, abi.encode(openOceanRouter, dataProvider)), SALT_OPEN_OCEAN_MODULE);

        require(OpenOceanSwapModule(openOcean).swapRouter() == openOceanRouter, "OpenOcean router mismatch");

        vm.serializeAddress(key, "CashModuleCoreImpl", core);
        vm.serializeAddress(key, "CashModuleSettersImpl", setters);
        vm.serializeAddress(key, "CashEventEmitterImpl", emitter);
        json = vm.serializeAddress(key, "OpenOceanSwapModule", openOcean);
    }
}
