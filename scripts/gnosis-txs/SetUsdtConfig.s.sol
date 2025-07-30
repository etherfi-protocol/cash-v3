// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { PriceProvider, IAggregatorV3 } from "../../src/oracle/PriceProvider.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract SetUsdtConfig is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address usdt = 0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df;

    // https://docs.chain.link/data-feeds/price-feeds/addresses?page=1&testnetPage=1&network=scroll&testnetSearch=E&search=USDT
    address usdtUsdOracle = 0xf376A91Ae078927eb3686D6010a6f1482424954E;
    
    address debtManager;
    address priceProvider;
    
    function run() public {
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();

        priceProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "PriceProvider")
        );

        debtManager = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        );

        PriceProvider.Config memory usdtUsdConfig = PriceProvider.Config({
            oracle: usdtUsdOracle,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(usdtUsdOracle).decimals(),
            maxStaleness: 10 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: true,
            isBaseTokenBtc: false
        });

        address[] memory tokens = new address[](1);
        tokens[0] = usdt;

        PriceProvider.Config[] memory priceProviderConfigs = new PriceProvider.Config[](1);
        priceProviderConfigs[0] = usdtUsdConfig;

        IDebtManager.CollateralTokenConfig memory usdtConfig = IDebtManager.CollateralTokenConfig({
            ltv: 90e18,
            liquidationThreshold: 95e18,
            liquidationBonus: 1e18
        }); 

        uint64 borrowApy = 1;

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory setusdtPriceProviderConfig = iToHex(abi.encodeWithSelector(PriceProvider.setTokenConfig.selector, tokens, priceProviderConfigs));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(priceProvider), setusdtPriceProviderConfig, "0", false)));
        
        string memory setUsdtConfig = iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, usdt, usdtConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), setUsdtConfig, "0", false)));

        string memory setUsdtBorrowConfig = iToHex(abi.encodeWithSelector(IDebtManager.supportBorrowToken.selector, usdt, borrowApy, type(uint128).max));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), setUsdtBorrowConfig, "0", true)));
        
        vm.createDir("./output", true);
        string memory path = "./output/SetUsdtConfig.json";
        vm.writeFile(path, txs);

        /// below here is just a test
        executeGnosisTransactionBundle(path);

        assert(IDebtManager(debtManager).isCollateralToken(usdt) == true);
        assert(IDebtManager(debtManager).isBorrowToken(usdt) == true);
    }
}
