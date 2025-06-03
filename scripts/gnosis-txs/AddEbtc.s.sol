// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";

import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { ILayerZeroTeller, AccountantWithRateProviders } from "../../src/interfaces/ILayerZeroTeller.sol";
import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { PriceProvider } from "../../src/oracle/PriceProvider.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract AddEbtc is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    IERC20 public ebtc = IERC20(0x657e8C867D8B37dCC18fA4Caead9C45EB088C642);
    ILayerZeroTeller public ebtcTeller = ILayerZeroTeller(0x6Ee3aaCcf9f2321E49063C4F8da775DdBd407268);
    
    EtherFiLiquidModule liquidModule;
    PriceProvider priceProvider;
    IDebtManager debtManager;
    string chainId;
    string deployments;

    function run() public {
        deployments = readDeploymentFile();

        chainId = vm.toString(block.chainid);

        vm.startBroadcast();

        liquidModule = EtherFiLiquidModule(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiLiquidModule")
        ));

        priceProvider = PriceProvider(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "PriceProvider")
        ));

        debtManager = IDebtManager(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        ));

        address[] memory tokens = new address[](1);
        tokens[0] = address(ebtc);

        address[] memory tellers = new address[](1);
        tellers[0] = address(ebtcTeller);

        AccountantWithRateProviders ebtcAccountant = ebtcTeller.accountant();

        PriceProvider.Config[] memory tokensConfig = new PriceProvider.Config[](1);
        tokensConfig[0] = PriceProvider.Config({
            oracle: address(ebtcAccountant),
            priceFunctionCalldata: abi.encodeWithSelector(AccountantWithRateProviders.getRate.selector),
            isChainlinkType: false,
            oraclePriceDecimals: ebtcAccountant.decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Uint256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: true
        });

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory addEBtcToPriceProvider = iToHex(abi.encodeWithSelector(PriceProvider.setTokenConfig.selector, tokens, tokensConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(priceProvider)), addEBtcToPriceProvider, "0", false)));

        IDebtManager.CollateralTokenConfig memory eBtcConfig = IDebtManager.CollateralTokenConfig({
            ltv: 50e18,
            liquidationThreshold: 80e18,
            liquidationBonus: 1e18
        });

        string memory setEBtcConfig = iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, address(ebtc), eBtcConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(debtManager)), setEBtcConfig, "0", false)));

        string memory addEBtcToLiquidModule = iToHex(abi.encodeWithSelector(EtherFiLiquidModule.addLiquidAssets.selector, tokens, tellers));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(liquidModule)), addEBtcToLiquidModule, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/AddEbtc.json";
        vm.writeFile(path, txs);

        vm.stopBroadcast();

        /// below here is just a test
        executeGnosisTransactionBundle(path);

        emit log_named_uint("ebtc price", priceProvider.price(address(ebtc)));
        debtManager.collateralTokenConfig(address(ebtc));
    }
}