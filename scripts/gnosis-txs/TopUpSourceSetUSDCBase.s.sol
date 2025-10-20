// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import  "forge-std/Vm.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { BeaconFactory } from "../../src/beacon-factory/BeaconFactory.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";
import {TopUpFactory} from "../../src/top-up/TopUpFactory.sol";
import {Utils} from "../utils/Utils.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import {Test} from "forge-std/Test.sol";

struct TokenConfig {
    string token;
    string bridge;
    address recipient;
    uint256 slippage;
    address cctpTokenMessenger;
    uint256 maxFee;
    uint32 minFinalityThreshold;
}

contract TopUpSourceSetUSDCBase is Utils, GnosisHelpers, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address newTopUpFactoryImp = 0x4c5644c0BCD100263d28c4eB735f9143eC83847F;
    address newTopUpImp = 0x8fF38032083C0E36C3CdC8c509758514Fe0a49E2;

    TopUpFactory topUpFactory;
    address cctpAdapter;
    // TopUpDest is our mainnet TopUpSourceFactory contract since CCTP bridges to mainnet
    address topUpDest;
    
    function run() public {

        string memory deployments = readTopUpSourceDeployment();
        string memory chainId = vm.toString(block.chainid);
        topUpFactory = TopUpFactory(
            payable(
                stdJson.readAddress(
                    deployments,
                    string.concat(".", "addresses", ".", "TopUpSourceFactory")
                )
            )
        );
        cctpAdapter = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CCTPAdapter")
        );

        // TopUpDest is our mainnet TopUpSourceFactory contract
        // CCTP bridges USDC to TopUpSourceFactory on Ethereum mainnet 
        topUpDest = address(topUpFactory);

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory fixturesFile = string.concat(vm.projectRoot(), string.concat("/deployments/", getEnv() ,"/fixtures/top-up-fixtures.json"));
        string memory fixtures = vm.readFile(fixturesFile);
        (address[] memory tokens, TopUpFactory.TokenConfig[] memory tokenConfig) = parseTokenConfigs(fixtures, chainId);
        string memory setTokenConfig = iToHex(abi.encodeWithSelector(TopUpFactory.setTokenConfig.selector, tokens, tokenConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(topUpFactory)), setTokenConfig, "0", false)));

        string memory upgradeTopUpFactory = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, newTopUpFactoryImp, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(topUpFactory)), upgradeTopUpFactory, "0", false)));

        string memory upgradeTopUp = iToHex(abi.encodeWithSelector(BeaconFactory.upgradeBeaconImplementation.selector, newTopUpImp, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(topUpFactory)), upgradeTopUp, "0", true)));

        vm.createDir("./output", true); 
        string memory path = string.concat("./output/TopUpUSDCSetConfig-", chainId, ".json");
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);

        deal(tokens[0], address(topUpFactory), 100e6);
        (, uint256 fee) = topUpFactory.getBridgeFee(tokens[0], 100e6);
        topUpFactory.bridge{value: fee}(tokens[0], 100e6);
    }   

    function parseTokenConfigs(string memory jsonString, string memory chainId) internal view returns (address[] memory tokens, TopUpFactory.TokenConfig[] memory tokenConfig) {
        tokens = new address[](1);
        tokenConfig = new TopUpFactory.TokenConfig[](1);

        string memory base = string.concat(".", chainId, ".tokenConfigs[");
        uint256 usdcIndex = 0;
        bool found = false;

        for (uint256 i = 0; i < 20; i++) {
            string memory tokenName = stdJson.readString(jsonString, string.concat(base, vm.toString(i), "].token"));
            if (keccak256(bytes(tokenName)) == keccak256(bytes("usdc"))) {
                usdcIndex = i;
                found = true;
                break;
            }
        }

        if (!found) revert("USDC token config not found");

        base = string.concat(base, vm.toString(usdcIndex), "]");

        tokens[0] = stdJson.readAddress(jsonString, string.concat(base, ".address"));
        
        address cctpTokenMessenger = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
        uint256 maxFee = 0;
        uint32 minFinalityThreshold = 2000;
        
        tokenConfig[0].recipientOnDestChain = topUpDest;
        tokenConfig[0].maxSlippageInBps = 0; // CCTP has no slippage as it's native USDC
        tokenConfig[0].bridgeAdapter = address(cctpAdapter);
        tokenConfig[0].additionalData = abi.encode(cctpTokenMessenger, maxFee, minFinalityThreshold);

        return (tokens, tokenConfig);
    }

}

