// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";
import { MidasModule } from "../src/modules/midas/MidasModule.sol";
import { IAggregatorV3, PriceProvider } from "../src/oracle/PriceProvider.sol";
import { Utils } from "./utils/Utils.sol";

contract DeployWeEURMidasModuleDev is Utils {
    bytes32 public constant SALT_MIDAS_MODULE = keccak256("DeployOptimismDevModules.MidasModule");

    address constant WEEUR_TOKEN = 0xcC476B1a49bcDf5192561e87b6Fb8ea78aa28C13;
    address constant DEPOSIT_VAULT = 0xF1b45eE795C8e1B858e191654C95A1B33c573632;
    address constant REDEMPTION_VAULT = 0xDC87653FCc5c16407Cd2e199d5Db48BaB71e7861;
    address constant PRICE_ORACLE = 0x01b910C1aa51cdC4a2a84d76CB255C4974Bf8A19;

    function run() public {
        require(block.chainid == 10, "This script must be run on Optimism (chain ID 10)");
        require(isEqualString(getEnv(), "dev"), "This script must be run with ENV=dev");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();
        address dataProvider = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        PriceProvider priceProvider = PriceProvider(stdJson.readAddress(deployments, ".addresses.PriceProvider"));
        IDebtManager debtManager = IDebtManager(stdJson.readAddress(deployments, ".addresses.DebtManager"));
        ICashModule cashModule = ICashModule(stdJson.readAddress(deployments, ".addresses.CashModule"));

        // 1. Deploy MidasModule via CREATE3
        // address[] memory midasTokens = new address[](1);
        // midasTokens[0] = WEEUR_TOKEN;

        // address[] memory depositVaults = new address[](1);
        // depositVaults[0] = DEPOSIT_VAULT;

        // address[] memory redemptionVaults = new address[](1);
        // redemptionVaults[0] = REDEMPTION_VAULT;

        // address midasModule = deployWithCreate3(
        //     abi.encodePacked(type(MidasModule).creationCode, abi.encode(dataProvider, midasTokens, depositVaults, redemptionVaults)),
        //     SALT_MIDAS_MODULE
        // );
        // console.log("MidasModule:", midasModule);

        // // 2. Whitelist as default module in DataProvider
        // address[] memory defaultModules = new address[](1);
        // defaultModules[0] = midasModule;

        // bool[] memory shouldWhitelist = new bool[](1);
        // shouldWhitelist[0] = true;

        // EtherFiDataProvider(dataProvider).configureDefaultModules(defaultModules, shouldWhitelist);

        // // 3. Configure price oracle
        // address[] memory tokens = new address[](1);
        // tokens[0] = WEEUR_TOKEN;

        // PriceProvider.Config[] memory configs = new PriceProvider.Config[](1);
        // configs[0] = PriceProvider.Config({
        //     oracle: PRICE_ORACLE,
        //     priceFunctionCalldata: "",
        //     isChainlinkType: true,
        //     oraclePriceDecimals: IAggregatorV3(PRICE_ORACLE).decimals(),
        //     maxStaleness: 30 days,
        //     dataType: PriceProvider.ReturnType.Int256,
        //     isBaseTokenEth: false,
        //     isStableToken: true,
        //     isBaseTokenBtc: false
        // });

        // priceProvider.setTokenConfig(tokens, configs);

        // 4. Configure collateral in DebtManager
        IDebtManager.CollateralTokenConfig memory collateralConfig = IDebtManager.CollateralTokenConfig({
            ltv: 75e18,
            liquidationThreshold: 90e18,
            liquidationBonus: 2e18
        });

        debtManager.supportCollateralToken(WEEUR_TOKEN, collateralConfig);

        // // 5. Allow withdrawal via CashModule
        // address[] memory withdrawableAssets = new address[](1);
        // withdrawableAssets[0] = WEEUR_TOKEN;

        // cashModule.configureWithdrawAssets(withdrawableAssets, shouldWhitelist);

        vm.stopBroadcast();
    }
}
