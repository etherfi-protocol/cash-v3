// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";

import { Utils } from "./utils/Utils.sol";
import { CCTPModule } from "../src/modules/cctp/CCTPModule.sol";

/**
 * @notice Deploys CCTPModule to OP. Post-deploy wiring (grant role, configureModules on
 *         dataProvider + cashModule, setAllowedRoutes) is done via governance, matching
 *         DeployStargateModule's split.
 */
contract DeployCCTPModule is Utils {
    CCTPModule cctpModule;

    // OP mainnet: Circle-native USDC + CCTP V2 TokenMessengerV2
    address constant USDC            = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;

    function run() public {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        string memory deployments = readDeploymentFile();
        address dataProvider = stdJson.readAddress(
            deployments,
            string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider"))
        );

        address[] memory assets = new address[](1);
        assets[0] = USDC;

        CCTPModule.AssetConfig[] memory cfgs = new CCTPModule.AssetConfig[](1);
        cfgs[0] = CCTPModule.AssetConfig({
            tokenMessenger: TOKEN_MESSENGER,
            maxFeeBps:      200,  // Fast-transfer relay-fee ceiling; 0 = Fast requests revert-free but fee-less (bump via governance to enable Fast)
            providerFeeBps: 50   // set by governance later
        });

        cctpModule = new CCTPModule(assets, cfgs, dataProvider);

        vm.stopBroadcast();
    }
}
