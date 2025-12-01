// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Utils } from "./utils/Utils.sol";
import { RecoveryManager } from "../src/safe/RecoveryManager.sol";

// forge script scripts/RecoverSafe.s.sol:RecoverSafe --rpc-url $SCROLL_RPC --broadcast -vvvv
contract RecoverSafe is Utils {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        recover();

        vm.stopBroadcast();
    }

    function recover() internal {
        address safe = 0x1f50aFb7c4990e864F42790B4F74248e1EAa8961;
        address newOwner = 0x9E29D412adEe0A34f95B3876c4aF74988d80D11F;

        address[] memory recoverySigners = new address[](2);
        recoverySigners[0] = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
        recoverySigners[1] = 0x4F5eB42edEce3285B97245f56b64598191b5A58E;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = hex'';
        signatures[1] = hex'488e0b3c9d95df3ed494423708bd9cfcd94bc32ffe12fa983d8c97c97706c04317d98805ea153d813980f7d1e1576cb067a46fa4693c3a3e0d0eabf626dd70a41b';

        RecoveryManager(safe).recoverSafe(newOwner, recoverySigners, signatures);
    }
}
