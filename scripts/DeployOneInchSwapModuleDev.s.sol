// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {console} from "forge-std/console.sol";

import {EtherFiSafe} from "../src/safe/EtherFiSafe.sol";
import {EtherFiSafeFactory} from "../src/safe/EtherFiSafeFactory.sol";
import {EtherFiDataProvider} from "../src/data-provider/EtherFiDataProvider.sol";
import {OneInchSwapModule} from "../src/modules/oneinch-swap/OneInchSwapModule.sol";
import {Utils} from "./utils/Utils.sol";

/**
 * @title DeployOneInchSwapModuleDev
 * @notice All-in-one dev script: deploys new Safe impl, upgrades beacon, deploys module, configures module
 * @dev Runs everything via a single EOA. For dev environment only.
 *
 *      Usage:
 *          ENV=dev PRIVATE_KEY=0x... forge script scripts/DeployOneInchSwapModuleDev.s.sol --rpc-url <optimism_rpc> --broadcast
 */
contract DeployOneInchSwapModuleDev is Utils {
    // 1inch v6 Aggregation Router — canonical address on all EVM chains
    address constant AGGREGATION_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        string memory deployments = readDeploymentFile();

        address dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );

        address safeFactoryAddr = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiSafeFactory")
        );

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy new EtherFiSafe implementation with ERC-1271 support
        EtherFiSafe safeImpl = new EtherFiSafe(dataProvider);
        console.log("New EtherFiSafe impl:", address(safeImpl));

        // 2. Upgrade beacon to new implementation
        EtherFiSafeFactory safeFactory = EtherFiSafeFactory(safeFactoryAddr);
        safeFactory.upgradeBeaconImplementation(address(safeImpl));
        console.log("Beacon upgraded");

        // 3. Deploy OneInchSwapModule
        OneInchSwapModule oneInchModule = new OneInchSwapModule(AGGREGATION_ROUTER, dataProvider);
        console.log("OneInchSwapModule:", address(oneInchModule));

        // 4. Configure as default module on DataProvider
        address[] memory modules = new address[](1);
        modules[0] = address(oneInchModule);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        EtherFiDataProvider(dataProvider).configureDefaultModules(modules, shouldWhitelist);
        console.log("Module configured as default");

        vm.stopBroadcast();
    }
}
