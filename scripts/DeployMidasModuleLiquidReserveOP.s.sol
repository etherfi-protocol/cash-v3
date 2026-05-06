// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";

import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";
import { MidasModule } from "../src/modules/midas/MidasModule.sol";
import { IAggregatorV3, PriceProvider } from "../src/oracle/PriceProvider.sol";
import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";
import { Utils } from "./utils/Utils.sol";

/// @notice Configures the existing `MidasModule` on Optimism (chainId 10) for the liquidRESERVE
///         Midas product. The MidasModule is already deployed at `MIDAS_MODULE`.
///
/// Steps executed (all require the broadcaster to hold the relevant admin roles, or to be the
/// `cashControllerSafe`):
///   1. Register MidasModule as a default module on `EtherFiDataProvider`.
///   2. Grant `MIDAS_MODULE_ADMIN` role to `cashControllerSafe` on `RoleRegistry`.
///   3. Call `addMidasVaults` on MidasModule with the liquidRESERVE deposit/redemption vaults.
///   4. Set the price oracle for liquidRESERVE on `PriceProvider`.
///   5. Support liquidRESERVE as collateral and borrow token on `DebtManager`.
///   6. Whitelist liquidRESERVE as a withdrawable asset on `CashModule`.
///
/// Usage:
///   ENV=mainnet forge script scripts/DeployMidasModuleLiquidReserveOP.s.sol:DeployMidasModuleLiquidReserveOP \
///     --rpc-url $OPTIMISM_RPC --broadcast -vvvv
contract DeployMidasModuleLiquidReserveOP is Utils {
    address constant MIDAS_MODULE = 0x2D43400058cE6810916Fd312FB38a7DcdF9708aa;
    address constant CASH_CONTROLLER_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address constant MIDAS_TOKEN = 0xca5921DF65E2e1b0B98Ae91c0187BA80D4124898;
    address constant PRICE_ORACLE = 0x58dDf77A329CcbE2F4C2114C64ed9E12Ec8a1356;
    address constant DEPOSIT_VAULT = 0xcA1C871f8ae2571Cb126A46861fc06cB9E645152;
    address constant REDEMPTION_VAULT = 0x904EA8d7FcaB7351758fAC82bDbc738E2010BC25;

    bytes32 constant MIDAS_MODULE_ADMIN = 0x57bb90935cfaf88839f01bfa8de28ad30d80741c4cc93a5d12373ddbb95c68c0;

    uint80 constant LTV = 80e18;
    uint80 constant LIQUIDATION_THRESHOLD = 90e18;
    uint96 constant LIQUIDATION_BONUS = 1e18;
    bool constant IS_STABLE_TOKEN = false;
    uint24 constant MAX_STALENESS = 6 days;

    IDebtManager debtManager;
    PriceProvider priceProvider;
    ICashModule cashModule;
    EtherFiDataProvider dataProvider;
    RoleRegistry roleRegistry;

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (10)");

        string memory deployments = readDeploymentFile();
        dataProvider = EtherFiDataProvider(stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider"));
        priceProvider = PriceProvider(stdJson.readAddress(deployments, ".addresses.PriceProvider"));
        debtManager = IDebtManager(stdJson.readAddress(deployments, ".addresses.DebtManager"));
        cashModule = ICashModule(stdJson.readAddress(deployments, ".addresses.CashModule"));
        roleRegistry = RoleRegistry(stdJson.readAddress(deployments, ".addresses.RoleRegistry"));

        address ownerBefore = roleRegistry.owner();

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        _registerDefaultModule();
        _grantMidasModuleAdmin();
        _addMidasVaults();
        _configurePriceOracle();
        _configureCollateralAndBorrow();
        _configureCashWithdrawable();

        vm.stopBroadcast();

        require(roleRegistry.owner() == ownerBefore, "CRITICAL: RoleRegistry owner changed!");
    }

    function _registerDefaultModule() internal {
        address[] memory modules = new address[](1);
        modules[0] = MIDAS_MODULE;

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        dataProvider.configureDefaultModules(modules, shouldWhitelist);
    }

    function _grantMidasModuleAdmin() internal {
        roleRegistry.grantRole(MIDAS_MODULE_ADMIN, CASH_CONTROLLER_SAFE);
    }

    function _addMidasVaults() internal {
        address[] memory midasTokens = new address[](1);
        midasTokens[0] = MIDAS_TOKEN;

        address[] memory depositVaults = new address[](1);
        depositVaults[0] = DEPOSIT_VAULT;

        address[] memory redemptionVaults = new address[](1);
        redemptionVaults[0] = REDEMPTION_VAULT;

        MidasModule(MIDAS_MODULE).addMidasVaults(midasTokens, depositVaults, redemptionVaults);
    }

    function _configurePriceOracle() internal {
        address[] memory tokens = new address[](1);
        tokens[0] = MIDAS_TOKEN;

        PriceProvider.Config[] memory configs = new PriceProvider.Config[](1);
        configs[0] = PriceProvider.Config({
            oracle: PRICE_ORACLE,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(PRICE_ORACLE).decimals(),
            maxStaleness: MAX_STALENESS,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: IS_STABLE_TOKEN,
            isBaseTokenBtc: false
        });

        priceProvider.setTokenConfig(tokens, configs);
    }

    function _configureCollateralAndBorrow() internal {
        IDebtManager.CollateralTokenConfig memory collateralConfig = IDebtManager.CollateralTokenConfig({
            ltv: LTV,
            liquidationThreshold: LIQUIDATION_THRESHOLD,
            liquidationBonus: LIQUIDATION_BONUS
        });

        uint64 borrowApy = 1; // ~0%
        uint128 minShares = type(uint128).max;

        debtManager.supportCollateralToken(MIDAS_TOKEN, collateralConfig);
        debtManager.supportBorrowToken(MIDAS_TOKEN, borrowApy, minShares);
    }

    function _configureCashWithdrawable() internal {
        address[] memory withdrawableAssets = new address[](1);
        withdrawableAssets[0] = MIDAS_TOKEN;

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        cashModule.configureWithdrawAssets(withdrawableAssets, shouldWhitelist);
    }
}
