// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { Utils } from "./utils/Utils.sol";
import { RecoveryManager } from "../src/safe/RecoveryManager.sol";

contract SetMode is Utils {
    RecoveryManager safe = RecoveryManager(0x4d00Df4eeFDc0868f15ee861D4DC7AbdEc724400);
    address newOwner = 0x3F28E0f92F3E8b67348cfacc7013ACB6F8C27f27;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
        recoverySigners[1] = 0x4F5eB42edEce3285B97245f56b64598191b5A58E;
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = hex'';
        signatures[1] = hex'bfaab89832570e6e9515f92c936ae611076f543be7daac1fe4c01d9095832c5545e902e4ec5e34af7fe17549d3ec525b9c28cf0fd3b7f34a104a1ad72b45c23a1b';
        // 6b67698e3d78c21fffb9d53fbe2163ffef492c71002d570516e8d91e0ea31609740d1e43a4825a0d84e300c926b6de20bf714078992350135955b68009a07e1b1c
        // 14c0af31f957a7ea362f9b1cad1dfc35ddd055e03e510baaf59047c7757ed621107b1b2e39a013cbaf45257b5cc9bc94b46e0b9937feb89e083790631871a2071c


        safe.recoverSafe(newOwner, recoverySigners, signatures);
        vm.stopBroadcast();
    }
}
