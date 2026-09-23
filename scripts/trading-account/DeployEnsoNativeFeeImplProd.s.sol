// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { EnsoSwapModule } from "../../src/enso/EnsoSwapModule.sol";
import { TradingAccountCreate3, TradingAccountProdConfig as C } from "./TradingAccountProdConfig.sol";

/**
 * @notice Permissionlessly deploys the native-fee `EnsoSwapModule` implementation via Nick's CREATE3
 *         factory on Ethereum or Optimism. Deploy only — the Operating Safe swaps the proxy over
 *         with `scripts/gnosis-txs/UpgradeEnsoNativeFee3CP.s.sol`.
 * @dev The data provider is an immutable in the implementation's code and differs per chain
 *      (Ethereum's trading stack has no CashModule, Optimism's cash deployment does), so it is read
 *      off the live proxy rather than configured here — an implementation built against the wrong
 *      one would brick the proxy on upgrade. The CREATE3 address depends only on the salt, so both
 *      chains land the same address despite the differing constructor argument, as they already do
 *      for the current implementation.
 *
 * Run once per chain:
 *   source .env && forge script scripts/trading-account/DeployEnsoNativeFeeImplProd.s.sol \
 *     --rpc-url $MAINNET_RPC --broadcast --verify
 *   source .env && forge script scripts/trading-account/DeployEnsoNativeFeeImplProd.s.sol \
 *     --rpc-url $OPTIMISM_RPC --broadcast --verify
 */
contract DeployEnsoNativeFeeImplProd is Script, TradingAccountCreate3 {
    function run() external {
        require(block.chainid == 1 || block.chainid == 10, "unsupported chain");
        require(C.NICKS_FACTORY.code.length > 0, "Nick's factory not deployed");

        address proxy = _predict(C.SALT_ENSO_PROXY);
        require(proxy.code.length > 0, "EnsoSwapModule proxy not deployed");
        address dataProvider = address(EnsoSwapModule(proxy).etherFiDataProvider());

        vm.startBroadcast();
        address impl = _deployCreate3(abi.encodePacked(type(EnsoSwapModule).creationCode, abi.encode(dataProvider)), C.SALT_ENSO_IMPL_NATIVE_FEE);
        vm.stopBroadcast();

        require(address(EnsoSwapModule(impl).etherFiDataProvider()) == dataProvider, "data provider mismatch");

        string memory path = string.concat("./deployments/mainnet/", vm.toString(block.chainid), "/trading-account.json");
        vm.writeJson(string.concat("\"", vm.toString(impl), "\""), path, ".EnsoSwapModuleImpl");

        console2.log("chainId", block.chainid);
        console2.log("EnsoSwapModule proxy", proxy);
        console2.log("new implementation", impl);
        console2.log("Wrote", path);
    }
}
