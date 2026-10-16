// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { AcrossSwapModule } from "../../src/across/AcrossSwapModule.sol";
import { EnsoSwapModule } from "../../src/enso/EnsoSwapModule.sol";
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { OpenOceanSwapModule } from "../../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";

/**
 * @notice Verifies that every trade-withdraw-path production deployment byte-matches current source
 *         with the constructor bindings used by DeployTradeWithdrawPathImplsProd.
 *
 * Usage:
 *   source .env && forge script scripts/trading-account/VerifyTradeWithdrawPathProdBytecode.s.sol \
 *     --rpc-url $OPTIMISM_RPC -vv
 *   source .env && forge script scripts/trading-account/VerifyTradeWithdrawPathProdBytecode.s.sol \
 *     --rpc-url $MAINNET_RPC -vv
 */
contract VerifyTradeWithdrawPathProdBytecode is Script, ContractCodeChecker {
    function run() public {
        require(block.chainid == 1 || block.chainid == 10, "unsupported chain");

        string memory root = vm.projectRoot();
        string memory chainId = vm.toString(block.chainid);
        string memory manifest = vm.readFile(string.concat(root, "/deployments/mainnet/", chainId, "/trade-withdraw-path.json"));
        string memory trading = vm.readFile(string.concat(root, "/deployments/mainnet/", chainId, "/trading-account.json"));

        address across = stdJson.readAddress(manifest, ".AcrossSwapModuleImpl");
        address enso = stdJson.readAddress(manifest, ".EnsoSwapModuleImpl");
        address dataProvider = address(AcrossSwapModule(across).etherFiDataProvider());
        address tradingSafeFactory = stdJson.readAddress(trading, ".TradingSafeFactory");

        require(address(EnsoSwapModule(enso).etherFiDataProvider()) == dataProvider, "swap module data providers differ");
        if (block.chainid == 1) {
            require(dataProvider == stdJson.readAddress(trading, ".EtherFiDataProvider"), "unexpected Ethereum data provider");
        }

        requireCodeMatchAllowingAddressEmbeds("AcrossSwapModuleImpl", across, address(new AcrossSwapModule(dataProvider, tradingSafeFactory)));
        requireCodeMatchAllowingAddressEmbeds("EnsoSwapModuleImpl", enso, address(new EnsoSwapModule(dataProvider, tradingSafeFactory)));

        if (block.chainid == 10) _checkOptimism(manifest, dataProvider);

        console.log("All trade-withdraw-path bytecode checks passed");
    }

    function _checkOptimism(string memory manifest, address dataProvider) internal {
        string memory deployments = vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet/10/deployments.json"));
        address expectedDataProvider = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        address cashModule = stdJson.readAddress(deployments, ".addresses.CashModule");
        address oldOpenOcean = stdJson.readAddress(deployments, ".addresses.OpenOceanSwapModule");
        require(dataProvider == expectedDataProvider, "unexpected Optimism data provider");

        address core = stdJson.readAddress(manifest, ".CashModuleCoreImpl");
        address setters = stdJson.readAddress(manifest, ".CashModuleSettersImpl");
        address emitter = stdJson.readAddress(manifest, ".CashEventEmitterImpl");
        address openOcean = stdJson.readAddress(manifest, ".OpenOceanSwapModule");

        requireCodeMatchAllowingAddressEmbeds("CashModuleCoreImpl", core, address(new CashModuleCore(dataProvider)));
        requireCodeMatchAllowingAddressEmbeds("CashModuleSettersImpl", setters, address(new CashModuleSetters(dataProvider)));
        requireCodeMatchAllowingAddressEmbeds("CashEventEmitterImpl", emitter, address(new CashEventEmitter(cashModule)));
        requireExactCodeMatch("OpenOceanSwapModule", openOcean, address(new OpenOceanSwapModule(OpenOceanSwapModule(oldOpenOcean).swapRouter(), dataProvider)));
    }
}
