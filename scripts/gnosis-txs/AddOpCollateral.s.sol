// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/// @title AddOpCollateral
/// @notice Generates a Gnosis Safe batch transaction (for the Cash controller safe on
///         Optimism) that adds the OP token as a collateral token:
///         1. Configure the Chainlink OP/USD oracle on PriceProvider
///         2. Support OP as collateral on DebtManager (20% LTV / 50% LT / 5% LB)
///         3. Whitelist OP as a withdrawable asset on CashModule
///
/// Usage:
///   source .env && ENV=mainnet forge script scripts/gnosis-txs/AddOpCollateral.s.sol:AddOpCollateral --rpc-url optimism -vvv
contract AddOpCollateral is Utils, GnosisHelpers, Test {
    address constant cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

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

    address priceProvider;
    address debtManager;
    address cashModule;

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (chain ID 10)");

        string memory deployments = readDeploymentFile();
        priceProvider = stdJson.readAddress(deployments, ".addresses.PriceProvider");
        debtManager = stdJson.readAddress(deployments, ".addresses.DebtManager");
        cashModule = stdJson.readAddress(deployments, ".addresses.CashModule");
        string memory chainId = vm.toString(block.chainid);

        console.log("PriceProvider:", priceProvider);
        console.log("DebtManager:", debtManager);
        console.log("CashModule:", cashModule);
        console.log("Safe:", cashControllerSafe);

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        // ── 1. Price oracle config (Chainlink OP/USD) ──
        {
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

            string memory data = iToHex(abi.encodeWithSelector(PriceProviderV2.setTokenConfig.selector, tokens, configs));
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(priceProvider), data, "0", false)));
        }

        // ── 2. Support OP as collateral on DebtManager ──
        {
            IDebtManager.CollateralTokenConfig memory collateralConfig = IDebtManager.CollateralTokenConfig({
                ltv: LTV,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                liquidationBonus: LIQUIDATION_BONUS
            });

            string memory data = iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, OP_TOKEN, collateralConfig));
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), data, "0", false)));
        }

        // ── 3. Whitelist OP as a withdrawable asset on CashModule ──
        {
            address[] memory withdrawableAssets = new address[](1);
            withdrawableAssets[0] = OP_TOKEN;

            bool[] memory shouldWhitelist = new bool[](1);
            shouldWhitelist[0] = true;

            string memory data = iToHex(abi.encodeWithSelector(ICashModule.configureWithdrawAssets.selector, withdrawableAssets, shouldWhitelist));
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), data, "0", true)));
        }

        vm.createDir("./output", true);
        string memory path = "./output/AddOpCollateral.json";
        vm.writeFile(path, txs);
        console.log("Bundle written to:", path);

        // Simulate the bundle against a fork
        executeGnosisTransactionBundle(path);
        console.log("Simulation OK");

        _verify();
    }

    function _verify() internal view {
        uint256 p = PriceProviderV2(priceProvider).price(OP_TOKEN);
        require(p > 0, "Zero price for OP");
        console.log("  [OK] OP price =", p);

        IDebtManager.CollateralTokenConfig memory cfg = IDebtManager(debtManager).collateralTokenConfig(OP_TOKEN);
        require(cfg.ltv == LTV, "LTV mismatch");
        require(cfg.liquidationThreshold == LIQUIDATION_THRESHOLD, "LT mismatch");
        require(cfg.liquidationBonus == LIQUIDATION_BONUS, "LB mismatch");
        console.log("  [OK] OP collateral config set");
    }
}
