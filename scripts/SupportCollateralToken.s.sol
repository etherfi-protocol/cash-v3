// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { ILayerZeroTeller } from "../src/interfaces/ILayerZeroTeller.sol";
import { Utils } from "./utils/Utils.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";

contract SupportCollateralToken is Utils {
    IERC20 public liquidEth = IERC20(0xf0bb20865277aBd641a307eCe5Ee04E79073416C);
    ILayerZeroTeller public liquidEthTeller = ILayerZeroTeller(0x9AA79C84b79816ab920bBcE20f8f74557B514734);
    
    IERC20 public liquidUsd = IERC20(0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C);
    ILayerZeroTeller public liquidUsdTeller = ILayerZeroTeller(0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387);
    
    IERC20 public liquidBtc = IERC20(0x5f46d540b6eD704C3c8789105F30E075AA900726);
    ILayerZeroTeller public liquidBtcTeller = ILayerZeroTeller(0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353);

    IERC20 public eUsd = IERC20(0x939778D83b46B456224A33Fb59630B11DEC56663);
    ILayerZeroTeller public eUsdTeller = ILayerZeroTeller(0xCc9A7620D0358a521A068B444846E3D5DebEa8fA);

    IERC20 public ebtc = IERC20(0x657e8C867D8B37dCC18fA4Caead9C45EB088C642);
    ILayerZeroTeller public ebtcTeller = ILayerZeroTeller(0x6Ee3aaCcf9f2321E49063C4F8da775DdBd407268);

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);
        
        string memory deployments = readDeploymentFile();

        IDebtManager debtManager = IDebtManager(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        ));

        IDebtManager.CollateralTokenConfig memory liquidEthConfig = IDebtManager.CollateralTokenConfig({
            ltv: 50e18,
            liquidationThreshold: 80e18,
            liquidationBonus: 1e18
        }); 
        IDebtManager.CollateralTokenConfig memory liquidBtcConfig = IDebtManager.CollateralTokenConfig({
            ltv: 50e18,
            liquidationThreshold: 80e18,
            liquidationBonus: 1e18
        }); 
        IDebtManager.CollateralTokenConfig memory liquidUsdConfig = IDebtManager.CollateralTokenConfig({
            ltv: 80e18,
            liquidationThreshold: 90e18,
            liquidationBonus: 1e18
        }); 
        IDebtManager.CollateralTokenConfig memory eUsdConfig = IDebtManager.CollateralTokenConfig({
            ltv: 80e18,
            liquidationThreshold: 90e18,
            liquidationBonus: 1e18
        }); 
        IDebtManager.CollateralTokenConfig memory eBtcConfig = IDebtManager.CollateralTokenConfig({
            ltv: 50e18,
            liquidationThreshold: 80e18,
            liquidationBonus: 1e18
        }); 

        debtManager.supportCollateralToken(address(liquidEth), liquidEthConfig);
        debtManager.supportCollateralToken(address(liquidBtc), liquidBtcConfig);
        debtManager.supportCollateralToken(address(liquidUsd), liquidUsdConfig);
        debtManager.supportCollateralToken(address(eUsd), eUsdConfig);
        debtManager.supportCollateralToken(address(ebtc), eBtcConfig);

        vm.stopBroadcast();
    }
}
