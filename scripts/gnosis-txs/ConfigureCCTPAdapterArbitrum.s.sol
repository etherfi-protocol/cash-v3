// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";

import {Utils} from "../utils/Utils.sol";
import {GnosisHelpers} from "../utils/GnosisHelpers.sol";
import {TopUpFactory} from "../../src/top-up/TopUpFactory.sol";

/**
 * @title DeployAndConfigureCCTPAdapterArbitrum
 * @notice Configures USDC with CCTP adapter in TopUpFactory on Arbitrum
 * @dev Generates Gnosis Safe transaction JSON for configuration
 */
contract DeployAndConfigureCCTPAdapterArbitrum is GnosisHelpers, Utils, Test {

    address constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant CCTP_TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    
    address constant cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    
    function run() public {

        vm.createSelectFork("https://arb1.arbitrum.io/rpc");
        
        string memory deployments = readTopUpSourceDeployment();
        
        address topUpFactoryAddress = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "TopUpSourceFactory")
        );

        address cctpAdapter = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CCTPAdapter")
        );

        address[] memory tokens = new address[](1);
        TopUpFactory.TokenConfig[] memory tokenConfig = new TopUpFactory.TokenConfig[](1);

        tokens[0] = ARBITRUM_USDC;
        tokenConfig[0].recipientOnDestChain = topUpFactoryAddress; 
        tokenConfig[0].maxSlippageInBps = 0; 
        tokenConfig[0].bridgeAdapter = cctpAdapter;
        tokenConfig[0].additionalData = abi.encode(CCTP_TOKEN_MESSENGER, uint256(0), uint32(2000));

        string memory chainId = vm.toString(block.chainid);
        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        bytes memory setTokenConfigData = abi.encodeWithSelector(
            TopUpFactory.setTokenConfig.selector,
            tokens,
            tokenConfig
        );
        string memory setTokenConfigHex = iToHex(setTokenConfigData);
        
        txs = string(abi.encodePacked(
            txs,
            _getGnosisTransaction(addressToHex(topUpFactoryAddress), setTokenConfigHex, "0", true)
        ));


        vm.writeFile("./output/ConfigureCCTPAdapterArbitrum.json", txs);

        executeGnosisTransactionBundle("./output/ConfigureCCTPAdapterArbitrum.json");

        TopUpFactory topUpFactory = TopUpFactory(payable(topUpFactoryAddress));
        uint256 amount = 1000e6; 
        deal(ARBITRUM_USDC, address(topUpFactory), amount);
        (, uint256 fee) = topUpFactory.getBridgeFee(ARBITRUM_USDC, amount);
        deal(address(vm.addr(1)), fee);
        vm.prank(address(vm.addr(1)));
        topUpFactory.bridge{value: fee}(ARBITRUM_USDC, amount);

    }
}

