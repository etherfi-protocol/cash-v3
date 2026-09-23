// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console2 } from "forge-std/console2.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { AcrossSwapModule } from "../../src/across/AcrossSwapModule.sol";
import { EnsoSwapModule } from "../../src/enso/EnsoSwapModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { Utils } from "../utils/Utils.sol";
import { TradingAccountCreate3, TradingAccountProdConfig as C } from "./TradingAccountProdConfig.sol";

/// @notice Permissionlessly predeploys the OP production swap modules via Nick's CREATE3 factory.
/// @dev Privileged module registration and CashModule configuration are deferred to the Gnosis script.
contract DeployTradingAccountOptimismProd is Utils, TradingAccountCreate3 {
    using stdJson for string;

    function run() external {
        require(block.chainid == 10, "must run on Optimism");
        require(C.NICKS_FACTORY.code.length > 0, "Nick's factory not deployed");

        string memory deployments = readDeploymentFile();
        address dataProvider = deployments.readAddress(".addresses.EtherFiDataProvider");
        address roleRegistry = deployments.readAddress(".addresses.RoleRegistry");

        vm.startBroadcast();

        address acrossImpl = _deployCreate3(abi.encodePacked(type(AcrossSwapModule).creationCode, abi.encode(dataProvider)), C.SALT_ACROSS_IMPL);
        address acrossProxy = _deployCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(acrossImpl, abi.encodeWithSelector(AcrossSwapModule.initialize.selector, roleRegistry, C.OP_SPOKE_POOL, C.MULTICALL_HANDLER))), C.SALT_ACROSS_PROXY);

        address ensoImpl = _deployCreate3(abi.encodePacked(type(EnsoSwapModule).creationCode, abi.encode(dataProvider)), C.SALT_ENSO_IMPL);
        address ensoProxy = _deployCreate3(abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(ensoImpl, abi.encodeWithSelector(EnsoSwapModule.initialize.selector, roleRegistry, C.ENSO_ROUTER))), C.SALT_ENSO_PROXY);

        vm.stopBroadcast();

        string memory key = "trading-account-prod-op";
        vm.serializeAddress(key, "AcrossSwapModuleImpl", acrossImpl);
        vm.serializeAddress(key, "AcrossSwapModule", acrossProxy);
        vm.serializeAddress(key, "EnsoSwapModuleImpl", ensoImpl);
        string memory json = vm.serializeAddress(key, "EnsoSwapModule", ensoProxy);
        string memory path = "./deployments/mainnet/10/trading-account.json";
        vm.writeJson(json, path);

        console2.log("AcrossSwapModule", acrossProxy);
        console2.log("EnsoSwapModule", ensoProxy);
        console2.log("Wrote", path);
    }
}
