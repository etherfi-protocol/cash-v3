// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { ScrollERC20BridgeAdapter } from "../../src/top-up/bridge/ScrollERC20BridgeAdapter.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract AddScrollERC20Bridge is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address usdcEthereum = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address topUpFactory;
    string chainId;
    string deployments;
    address scrollERC20BridgeAdapter;
    address topUpDestOnScroll = 0x3a6A724595184dda4be69dB1Ce726F2Ac3D66B87;
    address scrollGateway = 0xF8B1378579659D8F7EE5f3C929c2f3E332E41Fd6;
    uint256 gasLimit = 200_000;

    function run() public {
        deployments = readTopUpSourceDeployment();

        chainId = vm.toString(block.chainid);

        vm.startBroadcast();

        topUpFactory = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "TopUpSourceFactory")
        );

        scrollERC20BridgeAdapter = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "ScrollERC20BridgeAdapter")
        );

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        address[] memory tokens = new address[](1);
        TopUpFactory.TokenConfig[] memory tokenConfig = new TopUpFactory.TokenConfig[](1);

        tokens[0] = usdcEthereum;
        tokenConfig[0] = TopUpFactory.TokenConfig({
            bridgeAdapter: scrollERC20BridgeAdapter,
            maxSlippageInBps: 0,
            recipientOnDestChain: topUpDestOnScroll,
            additionalData: abi.encode(scrollGateway, gasLimit)
        });

        string memory setConfig = iToHex(abi.encodeWithSelector(TopUpFactory.setTokenConfig.selector, tokens, tokenConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(topUpFactory)), setConfig, "0", true)));

        vm.createDir("./output", true);
        string memory path = string.concat("./output/AddScrollERC20Bridge", ".json");
        vm.writeFile(path, txs);

        vm.stopBroadcast();

        /// below here is just a test
        executeGnosisTransactionBundle(path);
    }
}