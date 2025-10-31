// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import {TopUpFactory} from "../../src/top-up/TopUpFactory.sol";
import {Utils} from "../utils/Utils.sol";

/**
 * @title SetTokenConfigHyperEVM
 * @notice Sets token configurations for assets on HyperEVM
 * @dev Configures beHYPE (like weETH) and USDC (with CCTP like Base)
 */
contract SetTokenConfigHyperEVM is Utils {
    TopUpFactory topUpFactory;
    address cctpAdapter;
    address oftBridgeAdapter;
    address oftBridgeAdapterMainnet;
    
    // HyperEVM specific addresses
    address constant BEHYPE = 0xd8FC8F0b03eBA61F64D08B0bef69d80916E5DdA9;
    address constant USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant CCTP_TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address constant USDT = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    address constant WHYPE = 0x5555555555555555555555555555555555555555;
    
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        
        string memory deployments = readTopUpSourceDeployment();

        topUpFactory = TopUpFactory(
            payable(
                stdJson.readAddress(
                    deployments,
                    string.concat(".", "addresses", ".", "TopUpSourceFactory")
                )
            )
        );

        (address[] memory tokens, TopUpFactory.TokenConfig[] memory tokenConfig) = getTokenConfigs();

        topUpFactory.setTokenConfig(tokens, tokenConfig);

        topUpFactory.bridge{value: 44337530819375315}(USDT, 1000);
        // topUpFactory.bridge{value: 0.01 ether}(BEHYPE, 1000000000000000);
        // topUpFactory.bridge{value: 0.01 ether}(WHYPE, 1000000000000000);

        vm.stopBroadcast();
    }

    function getTokenConfigs() internal returns (address[] memory tokens, TopUpFactory.TokenConfig[] memory tokenConfig) {
        string memory deployments = readTopUpSourceDeployment();

         cctpAdapter = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CCTPAdapter")
        );

        oftBridgeAdapter = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiOFTBridgeAdapter")
        );

        topUpFactory = TopUpFactory(
            payable(
                stdJson.readAddress(
                    deployments,
                    string.concat(".", "addresses", ".", "TopUpSourceFactory")
                )
            )
        );

        oftBridgeAdapterMainnet = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiOFTBridgeAdapterMainnet")
        );

        tokens = new address[](1);
        tokenConfig = new TopUpFactory.TokenConfig[](1);

        // tokens[0] = USDC;
        // tokenConfig[0].recipientOnDestChain = address(topUpFactory);
        // tokenConfig[0].maxSlippageInBps = 0;
        // tokenConfig[0].bridgeAdapter = cctpAdapter;
        // tokenConfig[0].additionalData = abi.encode(CCTP_TOKEN_MESSENGER, uint256(0), uint32(2000));

        // tokens[0] = BEHYPE;
        // tokenConfig[0].recipientOnDestChain = 0x3a6A724595184dda4be69dB1Ce726F2Ac3D66B87; // top up dest address
        // tokenConfig[0].maxSlippageInBps = 50;
        // tokenConfig[0].bridgeAdapter = oftBridgeAdapter;
        // tokenConfig[0].additionalData = abi.encode(0x637De4A55cdD37700F9B54451B709b01040D48dF);


        tokens[0] = USDT;
        tokenConfig[0].recipientOnDestChain = address(topUpFactory);
        tokenConfig[0].maxSlippageInBps = 50;
        tokenConfig[0].bridgeAdapter = oftBridgeAdapterMainnet;
        tokenConfig[0].additionalData = abi.encode(0x904861a24F30EC96ea7CFC3bE9EA4B476d237e98);

        // tokens[1] = WHYPE;
        // tokenConfig[1].recipientOnDestChain = address(topUpFactory);
        // tokenConfig[1].maxSlippageInBps = 50;
        // tokenConfig[1].bridgeAdapter = oftBridgeAdapter;
        // tokenConfig[1].additionalData = abi.encode(0x2B7E48511ea616101834f09945c11F7d78D9136d);

        return (tokens, tokenConfig);
    }

}

