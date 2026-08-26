// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { MidasModule } from "../../src/modules/midas/MidasModule.sol";
import { IAggregatorV3, PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/// @title AddLiquidRWASupportOP
/// @notice Generates a Gnosis Safe batch transaction (COR-888) to integrate the Liquid RWA (Midas)
///         token on Optimism. Proposes the same four on-chain changes as scripts/AddLiquidRWASupport.s.sol,
///         but as a batch the cash controller Safe can review and execute:
///           1. MidasModule.addMidasVaults    — register deposit + redemption vaults
///           2. PriceProviderV2.setTokenConfig — Chainlink oracle, 7D staleness, USD-denominated
///           3. DebtManager.supportCollateralToken — 70% LTV / 80% LT / 4% LB (collateral only, NOT a borrow token)
///           4. CashModule.configureWithdrawAssets — whitelist liquidRWA as withdrawable
///
/// Usage:
///   ENV=dev forge script scripts/gnosis-txs/AddLiquidRWASupportOP.s.sol --rpc-url optimism -vvv
///
/// Output: ./output/AddLiquidRWASupportOP.json (import into the Safe Transaction Builder).
contract AddLiquidRWASupportOP is Utils, GnosisHelpers, Test {
    // Cash controller Safe on Optimism (holds the admin roles for these calls).
    address constant cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    // Liquid RWA (Midas) token + infra on Optimism (18 decimals, USD-denominated).
    address constant LIQUID_RWA = 0x17bC8Ffd82b8a36e737Ca1141C025089589B915e;
    address constant DEPOSIT_VAULT = 0x97b30c9D53A010009136b830f8A12f8d5624Bc43;
    address constant REDEMPTION_VAULT = 0x12Ae90dCe5C2a4Ee5141FBfc408ff1022D051F42;
    address constant PRICE_ORACLE = 0xd5aaE6ac1a9ed4BE5DcC1fc172EDeFFd5B6d8080;

    // Collateral params confirmed by JV.
    uint80 constant LTV = 70e18; // 70%
    uint80 constant LT = 80e18; // 80%
    uint96 constant LB = 4e18; // 4%

    address priceProvider;
    address debtManager;
    address cashModule;
    address midasModule;

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (chain ID 10)");

        string memory deployments = readDeploymentFile();
        priceProvider = stdJson.readAddress(deployments, ".addresses.PriceProvider");
        debtManager = stdJson.readAddress(deployments, ".addresses.DebtManager");
        cashModule = stdJson.readAddress(deployments, ".addresses.CashModule");
        midasModule = stdJson.readAddress(deployments, ".addresses.MidasModule");

        string memory chainId = vm.toString(block.chainid);

        console.log("Safe:", cashControllerSafe);
        console.log("PriceProvider:", priceProvider);
        console.log("DebtManager:", debtManager);
        console.log("CashModule:", cashModule);
        console.log("MidasModule:", midasModule);

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        // ── 1. MidasModule.addMidasVaults ──
        {
            address[] memory midasTokens = new address[](1);
            midasTokens[0] = LIQUID_RWA;
            address[] memory depositVaults = new address[](1);
            depositVaults[0] = DEPOSIT_VAULT;
            address[] memory redemptionVaults = new address[](1);
            redemptionVaults[0] = REDEMPTION_VAULT;

            string memory data = iToHex(
                abi.encodeWithSelector(MidasModule.addMidasVaults.selector, midasTokens, depositVaults, redemptionVaults)
            );
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(midasModule), data, "0", false)));
        }

        // ── 2. PriceProviderV2.setTokenConfig (7D staleness, USD-denominated) ──
        {
            address[] memory tokens = new address[](1);
            tokens[0] = LIQUID_RWA;

            PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](1);
            configs[0] = PriceProviderV2.Config({
                oracle: PRICE_ORACLE,
                priceFunctionCalldata: "",
                isChainlinkType: true,
                oraclePriceDecimals: IAggregatorV3(PRICE_ORACLE).decimals(),
                maxStaleness: 7 days,
                dataType: PriceProviderV2.ReturnType.Int256,
                isStableToken: false, // price accrues; do NOT clamp to $1
                baseAsset: address(0) // USD-denominated; no base-asset conversion
            });

            string memory data = iToHex(abi.encodeWithSelector(PriceProviderV2.setTokenConfig.selector, tokens, configs));
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(priceProvider), data, "0", false)));
        }

        // ── 3. DebtManager.supportCollateralToken (collateral only — NOT a borrow token) ──
        {
            IDebtManager.CollateralTokenConfig memory collateralConfig =
                IDebtManager.CollateralTokenConfig({ ltv: LTV, liquidationThreshold: LT, liquidationBonus: LB });

            string memory data =
                iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, LIQUID_RWA, collateralConfig));
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), data, "0", false)));
        }

        // ── 4. CashModule.configureWithdrawAssets (whitelist liquidRWA) ──
        {
            address[] memory withdrawAssets = new address[](1);
            withdrawAssets[0] = LIQUID_RWA;
            bool[] memory shouldWhitelist = new bool[](1);
            shouldWhitelist[0] = true;

            string memory data = iToHex(
                abi.encodeWithSelector(ICashModule.configureWithdrawAssets.selector, withdrawAssets, shouldWhitelist)
            );
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), data, "0", true)));
        }

        vm.createDir("./output", true);
        string memory path = "./output/AddLiquidRWASupportOP.json";
        vm.writeFile(path, txs);
        console.log("Bundle written to:", path);

        // Simulate the bundle against the current fork (pranks the Safe).
        executeGnosisTransactionBundle(path);
        console.log("Simulation OK");

        _verify();
    }

    function _verify() internal view {
        // Oracle registered and returns a positive USD price.
        require(PriceProviderV2(priceProvider).price(LIQUID_RWA) > 0, "price not set");

        // Midas vault registered.
        (address dv, address rv) = MidasModule(midasModule).vaults(LIQUID_RWA);
        require(dv == DEPOSIT_VAULT && rv == REDEMPTION_VAULT, "midas vault mismatch");

        // Collateral configured.
        require(IDebtManager(debtManager).isCollateralToken(LIQUID_RWA), "not collateral");
        IDebtManager.CollateralTokenConfig memory cfg = IDebtManager(debtManager).collateralTokenConfig(LIQUID_RWA);
        require(cfg.ltv == LTV && cfg.liquidationThreshold == LT && cfg.liquidationBonus == LB, "collateral cfg mismatch");

        // Withdraw asset whitelisted.
        address[] memory whitelisted = ICashModule(cashModule).getWhitelistedWithdrawAssets();
        bool found;
        for (uint256 i = 0; i < whitelisted.length; i++) {
            if (whitelisted[i] == LIQUID_RWA) found = true;
        }
        require(found, "withdraw asset not whitelisted");

        console.log("Verification OK");
    }
}
