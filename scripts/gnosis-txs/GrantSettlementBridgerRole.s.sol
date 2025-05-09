// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";

import { SettlementDispatcher } from "../../src/settlement-dispatcher/SettlementDispatcher.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract GrantSettlementDispatcherBridgerRole is GnosisHelpers, Utils {
    address safe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    // https://app.turnkey.com/dashboard/wallets/detail?id=035255bd-4034-5020-9be9-22bde7178841
    address bridger = 0x23ddE38BA34e378D28c667bC26b44310c7CA0997; 
    address public usdc = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;

    function run() public { 
        string memory deployments = readDeploymentFile();

        string memory chainId = vm.toString(block.chainid);

        address payable settlementDispatcherReap = payable(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "SettlementDispatcherReap")
        ));
        address roleRegistry = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "RoleRegistry")
        );

        string memory txs = _getGnosisHeader(chainId, addressToHex(safe));

        string memory grantSettlementBridgerRole = iToHex(abi.encodeWithSelector(RoleRegistry.grantRole.selector, SettlementDispatcher(settlementDispatcherReap).SETTLEMENT_DISPATCHER_BRIDGER_ROLE(), bridger));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(roleRegistry), grantSettlementBridgerRole, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/GrantSettlementDispatcherBridgerRole.json";
        vm.writeFile(path, txs);
        
        executeGnosisTransactionBundle(path);
    }
}