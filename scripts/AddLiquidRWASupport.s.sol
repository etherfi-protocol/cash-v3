// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";

import { ICashModule } from "../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";
import { MidasModule } from "../src/modules/midas/MidasModule.sol";
import { IAggregatorV3, PriceProvider } from "../src/oracle/PriceProvider.sol";
import { ChainConfig, Utils } from "./utils/Utils.sol";

/**
 * @title AddLiquidRWASupport
 * @notice Integrates the Liquid RWA (Midas) token into the Cash smart contracts on Optimism (COR-888).
 * @dev Mirrors the Liquid EUR rollout (SupportLiquidEURC.s.sol). Performs four changes:
 *      1. Register the liquidRWA oracle on the PriceProvider (7D staleness).
 *      2. Add liquidRWA as collateral on the DebtManager.
 *      3. Whitelist liquidRWA as a withdrawable asset on the CashModule.
 *      4. Add the liquidRWA Midas vault (deposit + redemption) to the MidasModule.
 *
 *      The token is USD-denominated, so no FX handling is required (isStableToken = false).
 *      Deposit assets (USDC/USDT) and the withdraw asset (USDC) are passed at call-time on the
 *      MidasModule's deposit/withdraw entrypoints, so they need no separate on-chain registration here.
 */
contract AddLiquidRWASupport is Utils {
    // --- Liquid RWA (Midas) token on Optimism, 18 decimals, USD-denominated ---
    address liquidRWA = 0x17bC8Ffd82b8a36e737Ca1141C025089589B915e;

    // --- Midas vaults ---
    address liquidRWADepositVault = 0x97b30c9D53A010009136b830f8A12f8d5624Bc43;
    address liquidRWARedemptionVault = 0x12Ae90dCe5C2a4Ee5141FBfc408ff1022D051F42;

    // --- Price oracle ---
    address liquidRWAPriceOracle = 0xd5aaE6ac1a9ed4BE5DcC1fc172EDeFFd5B6d8080;

    IDebtManager debtManager;
    PriceProvider priceProvider;
    ICashModule cashModule;
    MidasModule midasModule;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();
        priceProvider = PriceProvider(stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "PriceProvider")));
        debtManager = IDebtManager(stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "DebtManager")));
        cashModule = ICashModule(stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "CashModule")));
        midasModule = MidasModule(stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "MidasModule")));

        // --- Change 4: Add liquidRWA to the Midas module (mint + redeem) ---
        address[] memory midasTokens = new address[](1);
        midasTokens[0] = liquidRWA;

        address[] memory depositVaults = new address[](1);
        depositVaults[0] = liquidRWADepositVault;

        address[] memory redemptionVaults = new address[](1);
        redemptionVaults[0] = liquidRWARedemptionVault;

        midasModule.addMidasVaults(midasTokens, depositVaults, redemptionVaults);

        // --- Change 1: Register the liquidRWA oracle on the PriceProvider (7D staleness) ---
        address[] memory tokens = new address[](1);
        tokens[0] = liquidRWA;

        PriceProvider.Config memory liquidRWAConfig = PriceProvider.Config({
            oracle: liquidRWAPriceOracle,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(liquidRWAPriceOracle).decimals(),
            maxStaleness: 7 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: false, // USD-denominated RWA token; price accrues, do NOT clamp to $1
            isBaseTokenBtc: false
        });
        PriceProvider.Config[] memory priceConfigs = new PriceProvider.Config[](1);
        priceConfigs[0] = liquidRWAConfig;

        priceProvider.setTokenConfig(tokens, priceConfigs);

        // --- Change 2: Add liquidRWA as collateral on the DebtManager ---
        // liquidRWA is collateral only — it is NOT a borrow token.
        IDebtManager.CollateralTokenConfig memory collateralConfig = IDebtManager.CollateralTokenConfig({
            ltv: 70e18, // 70%
            liquidationThreshold: 80e18, // 80%
            liquidationBonus: 4e18 // 4%
        });

        debtManager.supportCollateralToken(address(liquidRWA), collateralConfig);

        // --- Change 3: Whitelist liquidRWA as a withdrawable asset on Cash ---
        address[] memory withdrawableAssets = new address[](1);
        withdrawableAssets[0] = address(liquidRWA);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        ICashModule(cashModule).configureWithdrawAssets(withdrawableAssets, shouldWhitelist);

        vm.stopBroadcast();
    }
}
