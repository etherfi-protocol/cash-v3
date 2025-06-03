// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { EtherFiLiquidModule } from "../src/modules/etherfi/EtherFiLiquidModule.sol";
import { Utils } from "./utils/Utils.sol";

contract InvestLiquid is Utils {
    using MessageHashUtils for bytes32;

    IERC20 public usdc = IERC20(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);   
    IERC20 public liquidUsd = IERC20(0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C);

    address public safe = 0xb638bD15b8bf30d77b20f6002947555c85F97067;

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        string memory deployments = readDeploymentFile();

        address deployerAddress = vm.addr(privateKey);

        vm.startBroadcast(privateKey);

        EtherFiLiquidModule liquidModule = EtherFiLiquidModule(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiLiquidModule")
        ));

        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.DEPOSIT_SIG(), 
            block.chainid, 
            address(liquidModule), 
            liquidModule.getNonce(safe), 
            safe, 
            abi.encode(address(usdc), address(liquidUsd), 1e6, 1e5)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v); 

        liquidModule.deposit(address(safe), address(usdc), address(liquidUsd), 1e6, 1e5, deployerAddress, signature);
        vm.stopBroadcast();
    }
}