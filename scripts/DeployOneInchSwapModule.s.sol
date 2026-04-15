// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { OneInchSwapModule } from "../src/modules/oneinch-swap/OneInchSwapModule.sol";
import { Utils } from "./utils/Utils.sol";

/**
 * @title DeployOneInchSwapModule
 * @notice Deploys the OneInchSwapModule contract
 *
 *      ENV=mainnet forge script scripts/DeployOneInchSwapModule.s.sol --rpc-url <optimism_rpc> --broadcast
 */
contract DeployOneInchSwapModule is Utils {
    // 1inch v6 Aggregation Router — canonical address on all EVM chains
    address constant AGGREGATION_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        string memory deployments = readDeploymentFile();

        address dataProvider = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "EtherFiDataProvider"));

        vm.startBroadcast(deployerPrivateKey);

        OneInchSwapModule oneInchModule = new OneInchSwapModule(AGGREGATION_ROUTER, dataProvider);

        console.log("OneInchSwapModule deployed at:", address(oneInchModule));
        console.log("Set ONE_INCH_MODULE=%s for the gnosis config script", address(oneInchModule));

        vm.stopBroadcast();
    }
}
