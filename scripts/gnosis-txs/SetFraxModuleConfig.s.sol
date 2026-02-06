// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { IAggregatorV3, PriceProvider } from "../../src/oracle/PriceProvider.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract SetFraxModuleConfig is GnosisHelpers, Utils {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address fraxusd = 0x397F939C3b91A74C321ea7129396492bA9Cdce82;
    address fraxUsdPriceOracle = 0x7be4f8b373853b74CDf48FE817bC2eB2272eBe45;

    function run() public {
        string memory deployments = readDeploymentFile();
        string memory chainId = vm.toString(block.chainid);

        address fraxModule = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "FraxModule"));

        address dataProvider = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "EtherFiDataProvider"));

        address priceProvider = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "PriceProvider"));

        address debtManager = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "DebtManager"));

        address cashModule = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "CashModule"));

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        // Configure data provider - default modules
        address[] memory modules = new address[](1);
        modules[0] = fraxModule;

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        string memory configureDefaultModules = iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, modules, shouldWhitelist));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(dataProvider), configureDefaultModules, "0", false)));

        // Configure price provider
        address[] memory tokens = new address[](1);
        tokens[0] = fraxusd;

        PriceProvider.Config memory fraxUsdConfig = PriceProvider.Config({
            oracle: fraxUsdPriceOracle,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(fraxUsdPriceOracle).decimals(),
            maxStaleness: 5 days, //confirmed with V & showtime
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: true, // Stable coin
            isBaseTokenBtc: false
        });
        PriceProvider.Config[] memory fraxUsdConfigs = new PriceProvider.Config[](1);
        fraxUsdConfigs[0] = fraxUsdConfig;

        string memory setTokenConfig = iToHex(abi.encodeWithSelector(PriceProvider.setTokenConfig.selector, tokens, fraxUsdConfigs));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(priceProvider), setTokenConfig, "0", false)));

        // Configure debt manager - collateral token
        IDebtManager.CollateralTokenConfig memory collateralConfig = IDebtManager.CollateralTokenConfig({
            ltv: 90e18, // confirmed
            liquidationThreshold: 95e18,
            liquidationBonus: 1e18
        });

        string memory supportCollateralToken = iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, address(fraxusd), collateralConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), supportCollateralToken, "0", false)));

        // Configure debt manager - borrow token
        uint64 borrowApy = 1; // ~0%
        uint128 minShares = type(uint128).max; // Since we dont want to use it in borrow mode

        string memory supportBorrowToken = iToHex(abi.encodeWithSelector(IDebtManager.supportBorrowToken.selector, address(fraxusd), borrowApy, minShares));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), supportBorrowToken, "0", false)));

        // Configure cash module - modules can request withdraw

        string memory configureModulesCanRequestWithdraw = iToHex(abi.encodeWithSelector(ICashModule.configureModulesCanRequestWithdraw.selector, modules, shouldWhitelist));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), configureModulesCanRequestWithdraw, "0", false)));

        // Configure cash module - withdrawable assets
        address[] memory withdrawableAssets = new address[](1);
        withdrawableAssets[0] = address(fraxusd);

        string memory configureWithdrawAssets = iToHex(abi.encodeWithSelector(ICashModule.configureWithdrawAssets.selector, withdrawableAssets, shouldWhitelist));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), configureWithdrawAssets, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/SetFraxModuleConfig.json";
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);
    }
}
