// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { MidasLiquifierModule } from "../../src/modules/etherfi/MidasLiquifierModule.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { MidasModule } from "../../src/modules/midas/MidasModule.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { AddSummerLendCollateral } from "./AddSummerLendCollateral.s.sol";

/**
 * @title SupportLiquidDeFiDev
 * @notice Lists liquidDeFi (Liquid Bold) on the DEV stack on Optimism: the dev counterpart of
 *         3CP-740 (cash side) and 3CP-743 (Aave listing), in one EOA broadcast because dev is
 *         admin-key driven. Dev reuses the prod token, the prod Midas vaults and the prod feeds.
 *
 *           1. MidasModule.addMidasVaults: deposit and redemption vault.
 *           2. MidasLiquifierModule.setPair(liquidDeFi -> USDC, redemption vault, 0 fee).
 *           3. PriceProviderV2.setTokenConfig: Midas liquidDeFi/USD feed, 8 decimals, 7-day staleness.
 *           4. CashModule.configureWithdrawAssets([liquidDeFi]).
 *           5. Aave v4 dev instance: collateral-only reserve on the prod "Capped liquidDeFi / USD"
 *              feed, collateral factor 75%, max liquidation bonus 7.5%. The parent's `_list` leaves
 *              caps uncapped on dev (prod lists with a supply cap of 0).
 *           6. LendGateway.setReserveId with the new reserve id.
 *           7. DebtManager collateral: LTV 64%, liquidation threshold 75%, bonus 7.5%.
 *
 *         Not spendable, as on prod: no supportBorrowToken and no setSpendAsset.
 *
 * Usage (simulate by dropping --broadcast; the broadcast wallet must be the dev admin, which holds
 * ADMIN_ROLE and ADMIN_TIMELOCK_ROLE on the dev RoleRegistry and is the Aave dev instance admin):
 *   ENV=dev FOUNDRY_PROFILE=aave-deploy forge script \
 *     scripts/aave-v4/SupportLiquidDeFiDev.s.sol:SupportLiquidDeFiDev \
 *     --rpc-url $OPTIMISM_RPC --broadcast -vvvv
 */
contract SupportLiquidDeFiDev is AddSummerLendCollateral {
    address constant LIQUID_DEFI = 0x4299b11815F25DB50fC56CD8a1C24cCCDD2AEECe;
    address constant DEPOSIT_VAULT = 0x877f5D9fE35A0A2aFDD4539b992c0edD33d476f4;
    address constant REDEMPTION_VAULT = 0x1BCb96E1D4CBf07334f9bDdF2f1F872ED00D504b;
    /// @dev Midas customFeed "liquidDeFi/USD", 8 decimals: the cash PriceProvider source on prod.
    address constant MIDAS_USD_FEED = 0xF354e713E9DF3CfBEbAD1221D779F6C4ca198a57;
    /// @dev Prod "Capped liquidDeFi / USD" Aave feed (cash-v3 #361), the reserve 29 price source in 3CP-743.
    address constant AAVE_USD_FEED = 0x71CDe3FA526ac8CaF6659bCB236730F0c7e7dA4a;
    address constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant DEV_MIDAS_MODULE = 0x3b4094d25633d6a79108B5F5178189979c27696F;
    address constant DEV_MIDAS_LIQUIFIER = 0xE1a0b9Ae34264064Ee8b12AE26a1347043D356aC;
    /// @dev Dev admin EOA: ADMIN_ROLE, ADMIN_TIMELOCK_ROLE and RoleRegistry owner on dev, and the Aave dev instance admin.
    address constant DEV_ADMIN = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;

    uint24 constant FEED_MAX_STALENESS = 7 days;
    uint16 constant COLLATERAL_FACTOR_BPS = 7500;
    uint32 constant MAX_LIQUIDATION_BONUS_BPS = 10_750; // collateral paid out per unit of debt: 100% + 7.5%

    // DebtManager scale: 100e18 == 100%
    uint80 constant DM_LTV = 64e18;
    uint80 constant DM_LIQUIDATION_THRESHOLD = 75e18;
    uint96 constant DM_LIQUIDATION_BONUS = 7.5e18;

    IDebtManager debtManager;
    PriceProviderV2 priceProvider;
    ICashModule cashModule;
    LendGateway gateway;
    MidasLiquifierModule liquifier;

    function run() public override {
        require(block.chainid == 10, "Must run on Optimism (10)");
        require(isEqualString(vm.envOr("FOUNDRY_PROFILE", string("default")), "aave-deploy"), "Run with FOUNDRY_PROFILE=aave-deploy");
        require(isEqualString(getEnv(), "dev"), "dev-only: the lend instance and cash addresses are the dev deployments");

        _loadInstance();
        _requireLivePrice(AAVE_USD_FEED, "Capped liquidDeFi / USD (prod feed)");
        _loadCash();

        // No PRIVATE_KEY: dry run as the dev admin (simulation only, nothing can be sent without the key).
        uint256 key = vm.envOr("PRIVATE_KEY", uint256(0));
        if (key == 0) vm.startBroadcast(DEV_ADMIN);
        else vm.startBroadcast(key);

        _cashLegs();
        uint256 reserveId = _lendLegs();

        vm.stopBroadcast();

        _recordReserveIds(vm.readFile(jsonPath));

        require(liquifier.pairs(LIQUID_DEFI).debtToken == USDC, "liquifier pair not USDC");
        require(priceProvider.price(LIQUID_DEFI) > 0, "cash price is 0");
        require(debtManager.isCollateralToken(LIQUID_DEFI), "not DebtManager collateral");
        require(!debtManager.isBorrowToken(LIQUID_DEFI), "must not be a borrow token");
        require(!gateway.isSpendAsset(LIQUID_DEFI), "must not be a spend asset");
        console.log("liquidDeFi dev reserveId:", reserveId);
        console.log("cash price (6 dec):", priceProvider.price(LIQUID_DEFI));
    }

    function _loadCash() internal {
        string memory deployments = readDeploymentFile();
        require(stdJson.readAddress(deployments, ".addresses.MidasModule") == DEV_MIDAS_MODULE, "dev MidasModule moved");
        require(stdJson.readAddress(deployments, ".addresses.MidasLiquifierModule") == DEV_MIDAS_LIQUIFIER, "dev MidasLiquifierModule moved");
        debtManager = IDebtManager(stdJson.readAddress(deployments, ".addresses.DebtManager"));
        priceProvider = PriceProviderV2(stdJson.readAddress(deployments, ".addresses.PriceProvider"));
        cashModule = ICashModule(stdJson.readAddress(deployments, ".addresses.CashModule"));
        string memory cashLendJson = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/cash-lend.json"));
        gateway = LendGateway(stdJson.readAddress(cashLendJson, ".lendGateway"));
        liquifier = MidasLiquifierModule(DEV_MIDAS_LIQUIFIER);
    }

    function _tokens() internal pure returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = LIQUID_DEFI;
    }

    /// @dev Legs 1-4: Midas vaults, liquifier pair, cash price feed, withdrawable.
    function _cashLegs() internal {
        address[] memory depositVaults = new address[](1);
        depositVaults[0] = DEPOSIT_VAULT;
        address[] memory redemptionVaults = new address[](1);
        redemptionVaults[0] = REDEMPTION_VAULT;
        MidasModule(DEV_MIDAS_MODULE).addMidasVaults(_tokens(), depositVaults, redemptionVaults);

        if (liquifier.pairs(LIQUID_DEFI).debtToken == address(0)) liquifier.setPair(LIQUID_DEFI, USDC, REDEMPTION_VAULT, 0, 0);

        // The price feed goes before the DebtManager leg, which prices the token.
        PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](1);
        configs[0] = PriceProviderV2.Config({ oracle: MIDAS_USD_FEED, priceFunctionCalldata: "", isChainlinkType: true, oraclePriceDecimals: 8, maxStaleness: FEED_MAX_STALENESS, dataType: PriceProviderV2.ReturnType.Int256, isStableToken: false, baseAsset: address(0) });
        priceProvider.setTokenConfig(_tokens(), configs);

        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;
        cashModule.configureWithdrawAssets(_tokens(), whitelist);
    }

    /// @dev Legs 5-7: Aave v4 dev reserve, LendGateway registry, DebtManager collateral.
    function _lendLegs() internal returns (uint256 reserveId) {
        _list(LIQUID_DEFI, AAVE_USD_FEED, COLLATERAL_FACTOR_BPS, MAX_LIQUIDATION_BONUS_BPS);
        reserveId = _reserveIdOf(LIQUID_DEFI);

        gateway.setReserveId(LIQUID_DEFI, reserveId);

        IDebtManager.CollateralTokenConfig memory config = IDebtManager.CollateralTokenConfig({ ltv: DM_LTV, liquidationThreshold: DM_LIQUIDATION_THRESHOLD, liquidationBonus: DM_LIQUIDATION_BONUS });
        if (debtManager.isCollateralToken(LIQUID_DEFI)) debtManager.setCollateralTokenConfig(LIQUID_DEFI, config);
        else debtManager.supportCollateralToken(LIQUID_DEFI, config);
    }
}
