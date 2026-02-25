// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * Generic funds recovery script. Token address is read from TOKEN_ADDRESS env var.
 * Symbol is read from chain for the output filename; falls back to "TOKEN" if not available.
 *
 * Usage:
 *  source .env && TOKEN_ADDRESS={token address} forge script scripts/gnosis-txs/FundsRecoveryGeneric.s.sol:FundsRecoveryGeneric --rpc-url=$ARBITRUM_RPC
 */
contract FundsRecoveryGeneric is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    function run() public {
        address token = vm.envAddress("TOKEN_ADDRESS");
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readTopUpSourceDeployment();

        address topUpFactory = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "TopUpSourceFactory"));

        uint256 balance = IERC20(token).balanceOf(topUpFactory);

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory recoverFunds = iToHex(abi.encodeWithSelector(TopUpFactory.recoverFunds.selector, token, balance));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(topUpFactory)), recoverFunds, "0", true)));

        string memory symbol = _getTokenSymbol(token);

        vm.createDir("./output", true);
        string memory path = string.concat("./output/FundsRecovery-", chainId, "-", symbol, ".json");
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);
    }

    function _getTokenSymbol(address token) internal view returns (string memory) {
        try IERC20Metadata(token).symbol() returns (string memory s) {
            if (bytes(s).length > 0) return s;
        } catch { }
        return "TOKEN";
    }
}
