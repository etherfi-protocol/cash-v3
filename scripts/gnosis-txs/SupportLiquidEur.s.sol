// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { MidasModule } from "../../src/modules/midas/MidasModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { SettlementDispatcherV2 } from "../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/// @title SupportLiquidEurGnosis
/// @notice Adds LiquidEUR end-to-end on OP Mainnet. Reads the already-deployed
///         MidasModule from deployments.json and bundles every admin call into a single
///         Gnosis tx executed by the CashController Safe (= RoleRegistry.owner()).
///
///         Bundle (in order):
///           1. DebtManager.supportCollateralToken (LTV=70%, liqThreshold=90%, liqBonus=2%)
///           2. DebtManager.supportBorrowToken    (apyPerSec=1, minShares=type(uint128).max)
///           3. CashModule.configureWithdrawAssets        ([LiquidEUR] => true)
///           4. EtherFiDataProvider.configureDefaultModules ([MidasModule] => true)
///           5. RoleRegistry.grantRole                    (MIDAS_MODULE_ADMIN => AAC4 safe)
///           6. MidasModule.addMidasVaults                (liquidEUR -> deposit + redemption vaults)
///           7. SettlementDispatcher{Reap,Rain,Pix,CardOrder}.setMidasRedemptionVault(liquidEUR, vault)
///
///         Step 5 must precede step 6 because addMidasVaults requires MIDAS_MODULE_ADMIN,
///         which is held by the bundle executor (CashController Safe / AAC4).
///
/// Prerequisites:
///         - PriceProviderV2 upgrade has landed and liquidEUR is configured (DebtManager.supportCollateralToken
///           reads priceProvider.price(token) and reverts on zero).
///         - MidasModule already deployed and recorded under .addresses.MidasModule.
///
/// Usage:
///   source .env && forge script scripts/gnosis-txs/SupportLiquidEur.s.sol --rpc-url optimism --broadcast -vvvv --verify
contract SupportLiquidEurGnosis is GnosisHelpers, Utils {
    address constant CASH_CONTROLLER_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    // ─── Token + Midas vaults ──────────────────────────────────────
    address constant LIQUID_EUR                  = 0xcC476B1a49bcDf5192561e87b6Fb8ea78aa28C13; // LiquidEUR
    address constant LIQUID_EUR_DEPOSIT_VAULT    = 0xF1b45eE795C8e1B858e191654C95A1B33c573632; // depositVault
    address constant LIQUID_EUR_REDEMPTION_VAULT = 0xDC87653FCc5c16407Cd2e199d5Db48BaB71e7861; // redemptionVaultSwapper

    bytes32 constant MIDAS_MODULE_ADMIN = keccak256("MIDAS_MODULE_ADMIN");

    // ─── Risk parameters (ticket) ──────────────────────────────────
    uint80 constant LTV                   = 70e18; // 70%
    uint80 constant LIQUIDATION_THRESHOLD = 90e18; // 90%
    uint96 constant LIQUIDATION_BONUS     = 2e18;  // 2%

    uint64  constant BORROW_APY_PER_SECOND = 1;
    uint128 constant MIN_BORROW_SHARES     = type(uint128).max;

    function run() public {
        string memory deployments = readDeploymentFile();
        string memory chainId     = vm.toString(block.chainid);

        address dataProvider = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        address roleRegistry = stdJson.readAddress(deployments, ".addresses.RoleRegistry");
        address debtManager  = stdJson.readAddress(deployments, ".addresses.DebtManager");
        address cashModule   = stdJson.readAddress(deployments, ".addresses.CashModule");
        address reap         = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherReap");
        address rain         = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherRain");
        address pix          = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherPix");
        address cardOrder    = stdJson.readAddress(deployments, ".addresses.SettlementDispatcherCardOrder");
        address midasModule  = stdJson.readAddress(deployments, ".addresses.MidasModule");

        // ── 1. Build Gnosis tx bundle ──
        string memory txs = _getGnosisHeader(chainId, addressToHex(CASH_CONTROLLER_SAFE));

        // 1.1 — supportCollateralToken
        {
            IDebtManager.CollateralTokenConfig memory collateralConfig = IDebtManager.CollateralTokenConfig({
                ltv:                  LTV,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                liquidationBonus:     LIQUIDATION_BONUS
            });
            string memory data = iToHex(abi.encodeWithSelector(
                IDebtManager.supportCollateralToken.selector, LIQUID_EUR, collateralConfig
            ));
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), data, "0", false)));
        }

        // 1.2 — supportBorrowToken
        {
            string memory data = iToHex(abi.encodeWithSelector(
                IDebtManager.supportBorrowToken.selector, LIQUID_EUR, BORROW_APY_PER_SECOND, MIN_BORROW_SHARES
            ));
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), data, "0", false)));
        }

        // 1.3 — configureWithdrawAssets
        {
            address[] memory withdrawAssets = new address[](1);
            withdrawAssets[0] = LIQUID_EUR;
            bool[] memory whitelist = new bool[](1);
            whitelist[0] = true;
            string memory data = iToHex(abi.encodeWithSelector(
                ICashModule.configureWithdrawAssets.selector, withdrawAssets, whitelist
            ));
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), data, "0", false)));
        }

        // 1.4 — configureDefaultModules (whitelist MidasModule)
        {
            address[] memory modules = new address[](1);
            modules[0] = address(midasModule);
            bool[] memory shouldWhitelist = new bool[](1);
            shouldWhitelist[0] = true;
            string memory data = iToHex(abi.encodeWithSelector(
                EtherFiDataProvider.configureDefaultModules.selector, modules, shouldWhitelist
            ));
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(dataProvider), data, "0", false)));
        }

        // 1.5 — grantRole(MIDAS_MODULE_ADMIN, CASH_CONTROLLER_SAFE)
        {
            string memory data = iToHex(abi.encodeWithSelector(
                RoleRegistry.grantRole.selector, MIDAS_MODULE_ADMIN, CASH_CONTROLLER_SAFE
            ));
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(roleRegistry), data, "0", false)));
        }

        // 1.6 - set Midas module config for liquidEUR
        {
            address[] memory midasVaults = new address[](1);
            midasVaults[0] = LIQUID_EUR;
            address[] memory depositVaults = new address[](1);
            depositVaults[0] = LIQUID_EUR_DEPOSIT_VAULT;
            address[] memory redemptionVaults = new address[](1);
            redemptionVaults[0] = LIQUID_EUR_REDEMPTION_VAULT;

            string memory data = iToHex(abi.encodeWithSelector(
                MidasModule.addMidasVaults.selector, midasVaults, depositVaults, redemptionVaults
            ));
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(midasModule), data, "0", false)));
        }

        // 1.7 — setMidasRedemptionVault on each dispatcher
        bytes memory setVaultData = abi.encodeWithSelector(
            SettlementDispatcherV2.setMidasRedemptionVault.selector, LIQUID_EUR, LIQUID_EUR_REDEMPTION_VAULT
        );
        string memory setVaultDataHex = iToHex(setVaultData);
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(reap),      setVaultDataHex, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(rain),      setVaultDataHex, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(pix),       setVaultDataHex, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cardOrder), setVaultDataHex, "0", true))); // last

        string memory path = "./output/UpgradeToPriceProviderV2.json";
        executeGnosisTransactionBundle(path);

        vm.createDir("./output", true);
        path = "./output/SupportLiquidEur.json";
        vm.writeFile(path, txs);
        console.log("Wrote Gnosis bundle to:", path);

        // ── 2. Simulate the bundle on the current fork ──
        executeGnosisTransactionBundle(path);

        // ── 3. Post-execution verification ──
        console.log("");
        console.log("=== Verification ===");

        IDebtManager.CollateralTokenConfig memory cfg = IDebtManager(debtManager).collateralTokenConfig(LIQUID_EUR);
        require(cfg.ltv == LTV, "LTV mismatch");
        require(cfg.liquidationThreshold == LIQUIDATION_THRESHOLD, "liqThreshold mismatch");
        require(cfg.liquidationBonus == LIQUIDATION_BONUS, "liqBonus mismatch");
        require(IDebtManager(debtManager).borrowApyPerSecond(LIQUID_EUR) == BORROW_APY_PER_SECOND, "borrowApy mismatch");
        console.log("  [OK] DebtManager collateral + borrow config");

        (address depositV, address redemptionV) = MidasModule(midasModule).vaults(LIQUID_EUR);
        require(depositV == LIQUID_EUR_DEPOSIT_VAULT, "Midas depositVault mismatch");
        require(redemptionV == LIQUID_EUR_REDEMPTION_VAULT, "Midas redemptionVault mismatch");
        console.log("  [OK] MidasModule vaults registered");

        require(EtherFiDataProvider(dataProvider).isDefaultModule(midasModule), "MidasModule not default");
        console.log("  [OK] MidasModule whitelisted as default module");

        require(
            RoleRegistry(roleRegistry).hasRole(MIDAS_MODULE_ADMIN, CASH_CONTROLLER_SAFE),
            "MIDAS_MODULE_ADMIN not granted to safe"
        );
        console.log("  [OK] MIDAS_MODULE_ADMIN granted to AAC4 safe");

        require(SettlementDispatcherV2(payable(reap)).getMidasRedemptionVault(LIQUID_EUR)      == LIQUID_EUR_REDEMPTION_VAULT, "Reap vault mismatch");
        require(SettlementDispatcherV2(payable(rain)).getMidasRedemptionVault(LIQUID_EUR)      == LIQUID_EUR_REDEMPTION_VAULT, "Rain vault mismatch");
        require(SettlementDispatcherV2(payable(pix)).getMidasRedemptionVault(LIQUID_EUR)       == LIQUID_EUR_REDEMPTION_VAULT, "Pix vault mismatch");
        require(SettlementDispatcherV2(payable(cardOrder)).getMidasRedemptionVault(LIQUID_EUR) == LIQUID_EUR_REDEMPTION_VAULT, "CardOrder vault mismatch");
        console.log("  [OK] Midas redemption vault set on all 4 dispatchers");

        // Owner-unchanged guard
        require(RoleRegistry(roleRegistry).owner() == CASH_CONTROLLER_SAFE, "CRITICAL: RoleRegistry owner changed");
        console.log("  [OK] RoleRegistry owner unchanged");

        console.log("");
        console.log("=== ALL CHECKS PASSED ===");
    }
}
