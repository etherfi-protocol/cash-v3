// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { ICashModule } from "../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";
import { PriceProviderV2 } from "../src/oracle/PriceProviderV2.sol";
import { Utils } from "./utils/Utils.sol";

/// @title AddOpCollateralDev
/// @notice Adds the OP token as a collateral token on the dev deployment (Optimism) via a
///         direct EOA broadcast. Configures the Chainlink OP/USD oracle, supports OP as
///         collateral (20% LTV / 50% LT / 5% LB), and whitelists it as a withdrawable asset
///         on Cash.
///
/// @dev The deployed PriceProvider proxy runs the V2 implementation (generic `baseAsset`
///      field rather than the V1 boolean flags). OP/USD is USD-denominated, so baseAsset = 0.
///
/// Usage:
///   source .env && ENV=dev forge script scripts/AddOpCollateralDev.s.sol:AddOpCollateralDev --rpc-url $OPTIMISM_RPC --broadcast -vvvv
contract AddOpCollateralDev is Utils {
    // OP token on Optimism
    address constant OP_TOKEN = 0x4200000000000000000000000000000000000042;
    // Chainlink OP/USD oracle on Optimism (8 decimals, USD-denominated)
    address constant OP_USD_ORACLE = 0x0D276FC14719f9292D5C1eA2198673d1f4269246;
    uint8 constant ORACLE_DECIMALS = 8;
    uint24 constant MAX_STALENESS = 1 days;

    // 100e18 == 100%
    uint80 constant LTV = 20e18; // 20%
    uint80 constant LIQUIDATION_THRESHOLD = 50e18; // 50%
    uint96 constant LIQUIDATION_BONUS = 5e18; // 5%

    PriceProviderV2 priceProvider;
    IDebtManager debtManager;
    ICashModule cashModule;

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (10)");

        string memory deployments = readDeploymentFile();
        priceProvider = PriceProviderV2(stdJson.readAddress(deployments, ".addresses.PriceProvider"));
        debtManager = IDebtManager(stdJson.readAddress(deployments, ".addresses.DebtManager"));
        cashModule = ICashModule(stdJson.readAddress(deployments, ".addresses.CashModule"));

        console.log("PriceProvider:", address(priceProvider));
        console.log("DebtManager:", address(debtManager));
        console.log("CashModule:", address(cashModule));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        _configurePriceOracle();
        _configureCollateral();
        _configureCashWithdrawable();

        vm.stopBroadcast();

        // Sanity check
        console.log("OP price:", priceProvider.price(OP_TOKEN));
    }

    function _configurePriceOracle() internal {
        address[] memory tokens = new address[](1);
        tokens[0] = OP_TOKEN;

        PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](1);
        configs[0] = PriceProviderV2.Config({
            oracle: OP_USD_ORACLE,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: ORACLE_DECIMALS,
            maxStaleness: MAX_STALENESS,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });

        priceProvider.setTokenConfig(tokens, configs);
    }

    function _configureCollateral() internal {
        IDebtManager.CollateralTokenConfig memory collateralConfig = IDebtManager.CollateralTokenConfig({
            ltv: LTV,
            liquidationThreshold: LIQUIDATION_THRESHOLD,
            liquidationBonus: LIQUIDATION_BONUS
        });

        debtManager.supportCollateralToken(OP_TOKEN, collateralConfig);
    }

    function _configureCashWithdrawable() internal {
        address[] memory withdrawableAssets = new address[](1);
        withdrawableAssets[0] = OP_TOKEN;

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        cashModule.configureWithdrawAssets(withdrawableAssets, shouldWhitelist);
    }
}
