// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";

import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract SetCollateralConfig is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address public weth = 0x5300000000000000000000000000000000000004;
    address public weEth = 0x01f0a31698C4d065659b9bdC21B3610292a1c506;
    address public usdc = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    address public liquidEth = 0xf0bb20865277aBd641a307eCe5Ee04E79073416C;   
    address public liquidUsd = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address public liquidBtc = 0x5f46d540b6eD704C3c8789105F30E075AA900726;
    address public eUsd = 0x939778D83b46B456224A33Fb59630B11DEC56663;
    address public eBtc = 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;
    address public scr = 0xd29687c813D741E2F938F4aC377128810E217b1b;

    address debtManager;
    
    function run() public {
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();

        debtManager = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        );

        IDebtManager.CollateralTokenConfig memory wethConfig = IDebtManager.CollateralTokenConfig({
            ltv: 55e18,
            liquidationThreshold: 75e18,
            liquidationBonus: 3.5e18
        }); 
        IDebtManager.CollateralTokenConfig memory weEthConfig = IDebtManager.CollateralTokenConfig({
            ltv: 55e18,
            liquidationThreshold: 75e18,
            liquidationBonus: 3.5e18
        }); 
        IDebtManager.CollateralTokenConfig memory scrConfig = IDebtManager.CollateralTokenConfig({
            ltv: 20e18,
            liquidationThreshold: 50e18,
            liquidationBonus: 5e18
        }); 
        IDebtManager.CollateralTokenConfig memory liquidEthConfig = IDebtManager.CollateralTokenConfig({
            ltv: 50e18,
            liquidationThreshold: 70e18,
            liquidationBonus: 5e18
        }); 
        IDebtManager.CollateralTokenConfig memory liquidUsdConfig = IDebtManager.CollateralTokenConfig({
            ltv: 80e18,
            liquidationThreshold: 90e18,
            liquidationBonus: 2e18
        }); 
        IDebtManager.CollateralTokenConfig memory liquidBtcConfig = IDebtManager.CollateralTokenConfig({
            ltv: 50e18,
            liquidationThreshold: 70e18,
            liquidationBonus: 5e18
        }); 
        IDebtManager.CollateralTokenConfig memory eBtcConfig = IDebtManager.CollateralTokenConfig({
            ltv: 52e18,
            liquidationThreshold: 72e18,
            liquidationBonus: 5e18
        }); 
        IDebtManager.CollateralTokenConfig memory eUsdConfig = IDebtManager.CollateralTokenConfig({
            ltv: 80e18,
            liquidationThreshold: 90e18,
            liquidationBonus: 2e18
        }); 

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory setWethConfig = iToHex(abi.encodeWithSelector(IDebtManager.setCollateralTokenConfig.selector, weth, wethConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), setWethConfig, "0", false)));
        
        string memory setWeEthConfig = iToHex(abi.encodeWithSelector(IDebtManager.setCollateralTokenConfig.selector, weEth, weEthConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), setWeEthConfig, "0", false)));
        
        string memory setScrConfig = iToHex(abi.encodeWithSelector(IDebtManager.setCollateralTokenConfig.selector, scr, scrConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), setScrConfig, "0", false)));
        
        string memory setLiquidEthConfig = iToHex(abi.encodeWithSelector(IDebtManager.setCollateralTokenConfig.selector, liquidEth, liquidEthConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), setLiquidEthConfig, "0", false)));
        
        string memory setLiquidUsdConfig = iToHex(abi.encodeWithSelector(IDebtManager.setCollateralTokenConfig.selector, liquidUsd, liquidUsdConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), setLiquidUsdConfig, "0", false)));
        
        string memory setLiquidBtcConfig = iToHex(abi.encodeWithSelector(IDebtManager.setCollateralTokenConfig.selector, liquidBtc, liquidBtcConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), setLiquidBtcConfig, "0", false)));
        
        string memory setEUsdConfig = iToHex(abi.encodeWithSelector(IDebtManager.setCollateralTokenConfig.selector, eUsd, eUsdConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), setEUsdConfig, "0", false)));
        
        string memory setEBtcConfig = iToHex(abi.encodeWithSelector(IDebtManager.setCollateralTokenConfig.selector, eBtc, eBtcConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), setEBtcConfig, "0", true)));
        
        vm.createDir("./output", true);
        string memory path = "./output/SetCollateralConfig.json";
        vm.writeFile(path, txs);

        /// below here is just a test
        executeGnosisTransactionBundle(path);
    }
}