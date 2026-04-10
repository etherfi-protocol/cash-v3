// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { IAggregatorV3, PriceProvider } from "../src/oracle/PriceProvider.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";
import { ICashModule } from "../src/interfaces/ICashModule.sol";
import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { EtherFiLiquidModuleWithReferrer } from "../src/modules/etherfi/EtherFiLiquidModuleWithReferrer.sol";
import { ILayerZeroTeller, AccountantWithRateProviders } from "../src/interfaces/ILayerZeroTeller.sol";
import { Utils } from "./utils/Utils.sol";

contract ConfigureOptimismDevEusd is Utils {
    // eUSD
    address constant eUsd = 0x939778D83b46B456224A33Fb59630B11DEC56663;
    address constant eUsdTeller = 0xCc9A7620D0358a521A068B444846E3D5DebEa8fA;

    // Liquid assets + tellers (same as Scroll)
    address constant liquidEth = 0xf0bb20865277aBd641a307eCe5Ee04E79073416C;
    address constant liquidEthTeller = 0x9AA79C84b79816ab920bBcE20f8f74557B514734;
    address constant liquidUsd = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address constant liquidUsdTeller = 0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387;
    address constant liquidBtc = 0x5f46d540b6eD704C3c8789105F30E075AA900726;
    address constant liquidBtcTeller = 0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353;
    address constant ebtc = 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;
    address constant ebtcTeller = 0x6Ee3aaCcf9f2321E49063C4F8da775DdBd407268;

    // Boring queues
    address constant liquidEthBoringQueue = 0x0D2dF071207E18Ca8638b4f04E98c53155eC2cE0;
    address constant liquidBtcBoringQueue = 0x77A2fd42F8769d8063F2E75061FC200014E41Edf;
    address constant liquidUsdBoringQueue = 0x38FC1BA73b7ED289955a07d9F11A85b6E388064A;
    address constant ebtcBoringQueue = 0x686696A3e59eE16e8A8533d84B62cfA504827135;

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (chain ID 10)");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();
        address priceProvider = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "PriceProvider"));
        address debtManager = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "DebtManager"));
        address dataProvider = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "EtherFiDataProvider"));
        address cashModule = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "CashModule"));
        address liquifierProxy = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "LiquidUSDLiquifierModule"));
        address liquidModule = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "EtherFiLiquidModule"));
        address liquidModuleWithReferrer = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "EtherFiLiquidModuleWithReferrer"));

        // --- 1. Add eUSD oracle (teller accountant pattern) ---
        console.log("1. Setting eUSD oracle...");
        AccountantWithRateProviders eUsdAccountant = ILayerZeroTeller(eUsdTeller).accountant();

        address[] memory tokens = new address[](1);
        tokens[0] = eUsd;

        PriceProvider.Config[] memory configs = new PriceProvider.Config[](1);
        configs[0] = PriceProvider.Config({
            oracle: address(eUsdAccountant),
            priceFunctionCalldata: abi.encodeWithSelector(AccountantWithRateProviders.getRate.selector),
            isChainlinkType: false,
            oraclePriceDecimals: eUsdAccountant.decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Uint256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });

        PriceProvider(priceProvider).setTokenConfig(tokens, configs);
        console.log("  eUSD oracle set");

        // --- 2. Add eUSD as collateral (same as Scroll: 80% LTV, 90% liq threshold, 2% bonus) ---
        console.log("2. Adding eUSD as collateral...");
        IDebtManager(debtManager).supportCollateralToken(eUsd, IDebtManager.CollateralTokenConfig({
            ltv: 80e18,
            liquidationThreshold: 90e18,
            liquidationBonus: 2e18
        }));
        console.log("  eUSD collateral supported");

        // --- 3. Whitelist LiquidUSDLiquifier as default module ---
        console.log("3. Whitelisting LiquidUSDLiquifier as default module...");
        address[] memory modules = new address[](1);
        modules[0] = liquifierProxy;

        bool[] memory enable = new bool[](1);
        enable[0] = true;

        EtherFiDataProvider(dataProvider).configureDefaultModules(modules, enable);
        console.log("  LiquidUSDLiquifier whitelisted:", liquifierProxy);

        // --- 4. Configure EtherFiLiquidModule to request withdrawals on CashModule ---
        console.log("4. Configuring EtherFiLiquidModule as withdraw requester...");
        address[] memory withdrawModules = new address[](1);
        withdrawModules[0] = liquidModule;

        bool[] memory canRequest = new bool[](1);
        canRequest[0] = true;

        ICashModule(cashModule).configureModulesCanRequestWithdraw(withdrawModules, canRequest);
        console.log("  EtherFiLiquidModule can request withdrawals:", liquidModule);

        // --- 5. Add liquid assets to EtherFiLiquidModuleWithReferrer ---
        console.log("5. Adding liquid assets to EtherFiLiquidModuleWithReferrer...");

        address[] memory liquidAssets = new address[](5);
        liquidAssets[0] = eUsd;
        liquidAssets[1] = liquidEth;
        liquidAssets[2] = liquidBtc;
        liquidAssets[3] = liquidUsd;
        liquidAssets[4] = ebtc;

        address[] memory liquidTellers = new address[](5);
        liquidTellers[0] = eUsdTeller;
        liquidTellers[1] = liquidEthTeller;
        liquidTellers[2] = liquidBtcTeller;
        liquidTellers[3] = liquidUsdTeller;
        liquidTellers[4] = ebtcTeller;

        EtherFiLiquidModuleWithReferrer(liquidModuleWithReferrer).addLiquidAssets(liquidAssets, liquidTellers);
        console.log("  Liquid assets added to EtherFiLiquidModuleWithReferrer");

        // --- 6. Set boring queues on EtherFiLiquidModuleWithReferrer ---
        console.log("6. Setting boring queues on EtherFiLiquidModuleWithReferrer...");
        EtherFiLiquidModuleWithReferrer(liquidModuleWithReferrer).setLiquidAssetWithdrawQueue(liquidEth, liquidEthBoringQueue);
        EtherFiLiquidModuleWithReferrer(liquidModuleWithReferrer).setLiquidAssetWithdrawQueue(liquidBtc, liquidBtcBoringQueue);
        EtherFiLiquidModuleWithReferrer(liquidModuleWithReferrer).setLiquidAssetWithdrawQueue(liquidUsd, liquidUsdBoringQueue);
        EtherFiLiquidModuleWithReferrer(liquidModuleWithReferrer).setLiquidAssetWithdrawQueue(ebtc, ebtcBoringQueue);
        console.log("  Boring queues set on EtherFiLiquidModuleWithReferrer");

        vm.stopBroadcast();
    }
}
