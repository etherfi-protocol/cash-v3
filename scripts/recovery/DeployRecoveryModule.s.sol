// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { RecoveryModule } from "../../src/modules/recovery/RecoveryModule.sol";
import { Utils } from "../utils/Utils.sol";
import { RecoveryDeployConfig, RecoveryDeployHelper } from "./RecoveryDeployConfig.sol";

/**
 * @notice Deploys the `RecoveryModule` on Optimism. Impl is deployed via Nick's
 *         CREATE3 factory with `SALT_RECOVERY_MODULE_IMPL` so the verifier script can
 *         independently recompute the address.
 *
 * Env:
 *   PRIVATE_KEY    — deployer key
 *   LZ_ENDPOINT    — LayerZero v2 endpoint on OP (see scripts/recovery/lz-config.json)
 *
 * Prints the `EtherFiDataProvider.configureModules([module], [true])` calldata
 * that the operating safe will 3CP-sign to whitelist the module.
 */
contract DeployRecoveryModule is Utils, RecoveryDeployHelper {
    function run() external {
        require(block.chainid == 10, "must be Optimism");
        require(RecoveryDeployConfig.NICKS_FACTORY.code.length > 0, "Nick's factory not on this chain");

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address lzEndpoint = vm.envAddress("LZ_ENDPOINT");

        string memory deployments = readDeploymentFile();
        address dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );
        require(dataProvider != address(0), "dataProvider not found in deployments.json");

        address predictedImpl = _predictImpl(RecoveryDeployConfig.SALT_RECOVERY_MODULE_IMPL);
        console.log("Predicted impl address: %s", predictedImpl);

        vm.startBroadcast(deployerPk);

        address impl = _deployCreate3(
            abi.encodePacked(
                type(RecoveryModule).creationCode,
                abi.encode(dataProvider, lzEndpoint)
            ),
            RecoveryDeployConfig.SALT_RECOVERY_MODULE_IMPL
        );
        require(impl == predictedImpl, "impl address mismatch");

        RecoveryModule module = RecoveryModule(address(new UUPSProxy(
            impl,
            abi.encodeWithSelector(RecoveryModule.initialize.selector, RecoveryDeployConfig.OPERATING_SAFE)
        )));

        vm.stopBroadcast();

        console.log("RecoveryModule impl : %s", impl);
        console.log("RecoveryModule proxy: %s", address(module));
        console.log("DataProvider        : %s", dataProvider);
        console.log("LZ endpoint         : %s", lzEndpoint);
        console.log("Delegate / owner    : %s", RecoveryDeployConfig.OPERATING_SAFE);

        address[] memory modules = new address[](1);
        modules[0] = address(module);
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        bytes memory whitelistCalldata = abi.encodeCall(
            EtherFiDataProvider.configureModules,
            (modules, shouldWhitelist)
        );
        console.log("");
        console.log("3CP calldata - operating safe signs on OP:");
        console.log("  target  : %s (EtherFiDataProvider)", dataProvider);
        console.log("  method  : configureModules([%s], [true])", address(module));
        console.log("  calldata:");
        console.logBytes(whitelistCalldata);
    }
}
