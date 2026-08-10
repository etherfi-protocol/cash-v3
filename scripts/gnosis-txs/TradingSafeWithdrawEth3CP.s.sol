// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { TradingSafeWithdrawModule } from "../../src/trading-safe/TradingSafeWithdrawModule.sol";
import { TradingAccountCreate3, TradingAccountProdConfig as C } from "../trading-account/TradingAccountProdConfig.sol";
import { Utils } from "../utils/Utils.sol";
import { TradingAccountGnosisHelpers } from "./TradingAccountGnosisHelpers.sol";

/**
 * @notice Generates the Ethereum 3CP JSON that turns on the `TradingSafeWithdrawModule`. One tx from
 *         the OperatingSafe (holds DATA_PROVIDER_ADMIN_ROLE):
 *
 *           EtherFiDataProvider.configureDefaultModules([TradingSafeWithdrawModule], [true])
 *
 *         `configureDefaultModules` whitelists AND marks the module default in one call, so it is
 *         enabled on every mainnet TradingSafe — existing safes included, since `isModuleEnabled`
 *         short-circuits on the data provider's default set rather than per-safe storage. That
 *         matches how Enso and Across are registered on this deployment, and is what makes the
 *         module a usable exit path without a per-safe setup transaction.
 *
 *         Ethereum only. OP TradingSafes carry a CashModule, so their exit is the delayed
 *         withdrawal that already exists there; this module deliberately has no delay because a
 *         mainnet TradingSafe has no debt, card hold, or CashModule accounting to protect.
 *
 * @dev The module address is the CREATE3 prediction, so this bundle can be produced and reviewed
 *      before `DeployTradingSafeWithdrawModuleProd` broadcasts. Where the module is not on chain
 *      yet the fork simulation deploys it locally at that same deterministic address first, so the
 *      simulated end state is the one the real bundle produces.
 *
 * Usage:
 *   source .env && forge script scripts/gnosis-txs/TradingSafeWithdrawEth3CP.s.sol --rpc-url $MAINNET_RPC
 */
contract TradingSafeWithdrawEth3CP is TradingAccountGnosisHelpers, Utils, TradingAccountCreate3 {
    function run() external {
        require(block.chainid == 1, "must run on Ethereum");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        address dataProvider = _predict(C.SALT_DATA_PROVIDER_PROXY);
        address module = _predict(C.SALT_TRADING_SAFE_WITHDRAW_MODULE);
        require(dataProvider.code.length > 0, "EtherFiDataProvider not deployed");
        require(!EtherFiDataProvider(dataProvider).isDefaultModule(module), "module already default");

        address[] memory modules = new address[](1);
        modules[0] = module;
        bool[] memory flags = new bool[](1);
        flags[0] = true;

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(C.OPERATING_SAFE));
        bytes memory data = abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, modules, flags);
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(dataProvider), iToHex(data), "0", true));

        vm.createDir("./output", true);
        string memory path = "./output/TradingSafeWithdraw3CP-eth-1.json";
        vm.writeFile(path, txs);
        console.log("Written: %s", path);

        _requireModuleDeployed(module, dataProvider);
        executeGnosisTransactionBundle(path);

        require(EtherFiDataProvider(dataProvider).isWhitelistedModule(module), "module not whitelisted");
        require(EtherFiDataProvider(dataProvider).isDefaultModule(module), "module not default");

        console.log("Simulation passed. TradingSafeWithdrawModule: %s", module);
    }

    /// @dev CREATE3 is permissionless and address-deterministic, so deploying the module inside the
    ///      fork reproduces exactly what the broadcast deploy will put at `module`.
    function _requireModuleDeployed(address module, address dataProvider) private {
        if (module.code.length == 0) {
            console.log("Module not deployed on chain; deploying in fork at the predicted address");
            _deployCreate3(abi.encodePacked(type(TradingSafeWithdrawModule).creationCode, abi.encode(dataProvider)), C.SALT_TRADING_SAFE_WITHDRAW_MODULE);
        }
        require(address(TradingSafeWithdrawModule(module).etherFiDataProvider()) == dataProvider, "module bound to wrong data provider");
    }
}
