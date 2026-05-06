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

/// @notice Configures the dev `MidasModule` on Optimism for liquidRESERVE.
///         The dev MidasModule (`0x292B...`) is already registered as a default module.
///         This script completes the remaining config: addMidasVaults, price oracle,
///         collateral/borrow, and withdraw whitelist.
///
/// Usage:
///   ENV=dev PRIVATE_KEY=$DEV_KEY \
///   forge script scripts/ConfigureDevMidasLiquidReserveOP.s.sol:ConfigureDevMidasLiquidReserveOP \
///     --rpc-url $OPTIMISM_RPC --broadcast -vvvv
contract ConfigureDevMidasLiquidReserveOP is Utils {
    address constant DEV_MIDAS_MODULE = 0x292B353d262E00a215E096A97596b55F8AFb00Df;

    address constant MIDAS_TOKEN = 0xca5921DF65E2e1b0B98Ae91c0187BA80D4124898;
    address constant PRICE_ORACLE = 0x58dDf77A329CcbE2F4C2114C64ed9E12Ec8a1356;
    address constant DEPOSIT_VAULT = 0x1561eC30da97108Df46535CBd9bAD8C8d8611B3a;
    address constant REDEMPTION_VAULT = 0xC87b51735ea5Eeee59D3e12601dC931F77F2837a;

    bytes32 constant MIDAS_MODULE_ADMIN = 0x57bb90935cfaf88839f01bfa8de28ad30d80741c4cc93a5d12373ddbb95c68c0;

    uint80 constant LTV = 80e18;
    uint80 constant LIQUIDATION_THRESHOLD = 90e18;
    uint96 constant LIQUIDATION_BONUS = 1e18;
    bool constant IS_STABLE_TOKEN = false;
    uint24 constant MAX_STALENESS = 7 days;

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

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        _addMidasVaults();
        _configurePriceOracle();
        _configureCollateralAndBorrow();
        _configureCashWithdrawable();

        vm.stopBroadcast();
    }

    function _addMidasVaults() internal {
        address[] memory midasTokens = new address[](1);
        midasTokens[0] = MIDAS_TOKEN;

        address[] memory depositVaults = new address[](1);
        depositVaults[0] = DEPOSIT_VAULT;

        address[] memory redemptionVaults = new address[](1);
        redemptionVaults[0] = REDEMPTION_VAULT;

        MidasModule(DEV_MIDAS_MODULE).addMidasVaults(midasTokens, depositVaults, redemptionVaults);
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

        uint64 borrowApy = 1;
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
