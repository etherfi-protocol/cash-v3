// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { TopUp } from "../../src/top-up/TopUp.sol";
import { BeaconFactory, TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract EthTopUpUpgrade is GnosisHelpers, Utils {
    address safe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address wethEthereum = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address wethBase = 0x4200000000000000000000000000000000000006;
    address wethArbitrum = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    address factory;

    function run() public {
        vm.startBroadcast();

        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readTopUpSourceDeployment();

        factory = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "TopUpSourceFactory")
        );

        address payable topUpImpl = payable(address(new TopUp(getWeth())));
        address payable topUpFactoryImpl = payable(address(new TopUpFactory()));

        string memory txs = _getGnosisHeader(chainId, addressToHex(safe));

        string memory upgradeTopUpFactory = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, topUpFactoryImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(factory), upgradeTopUpFactory, "0", false)));
        
        string memory setTopUpImpl = iToHex(abi.encodeWithSelector(BeaconFactory.upgradeBeaconImplementation.selector, topUpImpl));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(factory), setTopUpImpl, "0", true)));

        vm.createDir("./output", true);
        string memory path = string(abi.encodePacked("./output/EthTopUpUpgrade-", chainId,".json"));
        vm.writeFile(path, txs);

        vm.stopBroadcast();
    }

    function getWeth() internal view returns (address) {
        if (block.chainid == 1) return wethEthereum;
        else if (block.chainid == 8453) return wethBase;
        else if (block.chainid == 42161) return wethArbitrum;
        else revert ("bad chain ID");
    }
}