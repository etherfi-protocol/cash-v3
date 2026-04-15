// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { EtherFiSafe } from "../src/safe/EtherFiSafe.sol";
import { Utils } from "./utils/Utils.sol";

/**
 * @title DeployOneInchSafeImpl
 * @notice Deploys a new EtherFiSafe implementation with ERC-1271 support
 *
 *      ENV=mainnet forge script scripts/DeployOneInchSafeImpl.s.sol --rpc-url <optimism_rpc> --broadcast
 */
contract DeployOneInchSafeImpl is Utils {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        string memory deployments = readDeploymentFile();

        address dataProvider = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "EtherFiDataProvider"));

        vm.startBroadcast(deployerPrivateKey);

        EtherFiSafe safeImpl = new EtherFiSafe(dataProvider);

        console.log("New EtherFiSafe implementation deployed at:", address(safeImpl));
        console.log("Set NEW_SAFE_IMPL=%s for the gnosis upgrade script", address(safeImpl));

        vm.stopBroadcast();
    }
}
