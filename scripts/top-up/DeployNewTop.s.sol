// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {TopUp} from "../../src/top-up/TopUp.sol";
import {Utils} from "../utils/Utils.sol";

contract UpgradeTopUp is Utils {

    address public BASE_WETH = 0x4200000000000000000000000000000000000006;
    address public ETH_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        if (block.chainid == 1) {
            TopUp topUp = new TopUp(ETH_WETH);
        } else if (block.chainid == 8453) {
            TopUp topUp = new TopUp(BASE_WETH);
        } else {
            revert("Unsupported chain");
        }

        vm.stopBroadcast();
    }
}
