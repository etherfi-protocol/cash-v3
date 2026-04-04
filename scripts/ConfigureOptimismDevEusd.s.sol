// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { IAggregatorV3, PriceProvider } from "../src/oracle/PriceProvider.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";
import { ICashModule } from "../src/interfaces/ICashModule.sol";
import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { ILayerZeroTeller, AccountantWithRateProviders } from "../src/interfaces/ILayerZeroTeller.sol";
import { Utils } from "./utils/Utils.sol";

contract ConfigureOptimismDevEusd is Utils {
    // eUSD
    address constant eUsd = 0x939778D83b46B456224A33Fb59630B11DEC56663;
    address constant eUsdTeller = 0xCc9A7620D0358a521A068B444846E3D5DebEa8fA;

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

        vm.stopBroadcast();
    }
}
