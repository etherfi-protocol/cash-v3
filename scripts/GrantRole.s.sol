// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Utils, ChainConfig} from "./utils/Utils.sol";
import {RoleRegistry} from "../src/role-registry/RoleRegistry.sol";
import {TopUpDest} from "../src/top-up/TopUpDest.sol";

contract GrantRole is Utils {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();

        RoleRegistry roleRegistry = RoleRegistry(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "RoleRegistry")
        ));

        TopUpDest topUpDest = TopUpDest(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "TopUpDest")
        ));

        roleRegistry.grantRole(topUpDest.TOP_UP_DEPOSITOR_ROLE(), deployer);
        roleRegistry.grantRole(topUpDest.TOP_UP_ROLE(), deployer);

        IERC20(0x01f0a31698C4d065659b9bdC21B3610292a1c506).approve(address(topUpDest), type(uint256).max);
        IERC20(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4).approve(address(topUpDest), type(uint256).max);
        IERC20(0xd29687c813D741E2F938F4aC377128810E217b1b).approve(address(topUpDest), type(uint256).max);

        topUpDest.deposit(0x01f0a31698C4d065659b9bdC21B3610292a1c506, 100 ether);
        topUpDest.deposit(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4, 10000e6);
        topUpDest.deposit(0xd29687c813D741E2F938F4aC377128810E217b1b, 10000e6);

        vm.stopBroadcast();
    }
}