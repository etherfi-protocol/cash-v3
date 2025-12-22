// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import {Utils} from "../utils/Utils.sol";
import {GnosisHelpers} from "../utils/GnosisHelpers.sol";
import {TopUpFactory} from "../../src/top-up/TopUpFactory.sol";

/**
 * @title DeployAndConfigureCCTPAdapterArbitrum
 * @notice Configures USDC with CCTP adapter in TopUpFactory on Arbitrum
 * @dev Generates Gnosis Safe transaction JSON for configuration
 */
contract DeployAndConfigureCCTPAdapterArbitrum is GnosisHelpers, Utils {

    address constant ARBITRUM_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CCTP_TOKEN_MESSENGER = 0x19330d10D9Cc8751218eaf51E8885D058642E08A;
    
    address constant cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    
    function run() public {
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
    }
}

