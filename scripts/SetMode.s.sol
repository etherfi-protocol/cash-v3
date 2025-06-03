// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {Utils, ChainConfig} from "./utils/Utils.sol";
import {EtherFiSafeFactory} from "../src/safe/EtherFiSafeFactory.sol";
import {ICashModule, Mode} from "../src/interfaces/ICashModule.sol";
import {CashVerificationLib} from "../src/libraries/CashVerificationLib.sol";

contract SetMode is Utils {
    using MessageHashUtils for bytes32;
    
    address safe = 0x59481dd9407e5826c4950F4dBD4f99dE2C7e99F4;
    ICashModule cashModule;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        Mode mode = Mode.Credit;

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();

        cashModule = ICashModule(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModule")
        ));

        uint256 nonce = cashModule.getNonce(address(safe));

        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.SET_MODE_METHOD, block.chainid, address(safe), nonce, abi.encode(mode))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerPrivateKey, digestHash);

        bytes memory signature = abi.encodePacked(r, s, v);

        cashModule.setMode(address(safe), mode, deployer, signature);

        vm.stopBroadcast();
    }
}