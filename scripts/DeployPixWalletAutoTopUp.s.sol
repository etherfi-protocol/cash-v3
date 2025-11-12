// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Utils } from "./utils/Utils.sol";
import { PixWalletAutoTopup, UUPSUpgradeable } from "../src/pix-auto-topup/PixWalletAutoTopup.sol";
import { UUPSProxy } from "../src/UUPSProxy.sol";

contract DeployPixWalletAutoTopup is Utils {
    address public pixWallet = 0xC6a422C4e3bE35d5191862259Ac0192e4B2aB104;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address owner = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        address pixWalletAutoTopupImpl = address(new PixWalletAutoTopup());
        address(new UUPSProxy(pixWalletAutoTopupImpl, abi.encodeWithSelector(PixWalletAutoTopup.initialize.selector, owner, pixWallet)));
        
        vm.stopBroadcast();
    }
}