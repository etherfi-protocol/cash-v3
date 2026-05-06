// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { MidasModule } from "../../src/modules/midas/MidasModule.sol";
import { IAggregatorV3, PriceProvider } from "../../src/oracle/PriceProvider.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/// @notice Generates a Gnosis Safe transaction bundle for the cashControllerSafe to configure
///         the existing `MidasModule` for liquidRESERVE on Optimism.
///
/// Bundle transactions (all executed by the Safe):
///   1. `EtherFiDataProvider.configureDefaultModules` — register MidasModule as default.
///   2. `RoleRegistry.grantRole(MIDAS_MODULE_ADMIN, safe)` — grant admin role.
///   3. `MidasModule.addMidasVaults` — set deposit/redemption vaults for liquidRESERVE.
///   4. `PriceProvider.setTokenConfig` — configure price oracle.
///   5. `DebtManager.supportCollateralToken` + `supportBorrowToken`.
///   6. `CashModule.configureWithdrawAssets`.
///
/// The script simulates the bundle on the live fork and asserts state after execution.
///
/// Usage:
///   ENV=mainnet forge script scripts/gnosis-txs/DeployMidasModuleLiquidReserveOP.s.sol:DeployMidasModuleLiquidReserveOPGnosis \
///     --rpc-url $OPTIMISM_RPC -vvvv
contract DeployMidasModuleLiquidReserveOPGnosis is GnosisHelpers, Utils, Test {
    address constant CASH_CONTROLLER_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address constant MIDAS_MODULE = 0x2D43400058cE6810916Fd312FB38a7DcdF9708aa;

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

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (10)");

        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();

        address dataProvider = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        address priceProvider = stdJson.readAddress(deployments, ".addresses.PriceProvider");
        address debtManager = stdJson.readAddress(deployments, ".addresses.DebtManager");
        address cashModule = stdJson.readAddress(deployments, ".addresses.CashModule");
        address roleRegistryAddr = stdJson.readAddress(deployments, ".addresses.RoleRegistry");

        string memory txs = _getGnosisHeader(chainId, addressToHex(CASH_CONTROLLER_SAFE));
        txs = string(abi.encodePacked(txs, _configureDefaultModulesTx(dataProvider)));
        txs = string(abi.encodePacked(txs, _grantMidasModuleAdminTx(roleRegistryAddr)));
        txs = string(abi.encodePacked(txs, _addMidasVaultsTx()));
        txs = string(abi.encodePacked(txs, _setTokenConfigTx(priceProvider)));
        txs = string(abi.encodePacked(txs, _supportCollateralTx(debtManager)));
        txs = string(abi.encodePacked(txs, _supportBorrowTx(debtManager)));
        txs = string(abi.encodePacked(txs, _configureWithdrawTx(cashModule)));

        vm.createDir("./output", true);
        string memory path = "./output/DeployMidasModuleLiquidReserveOP.json";
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);

        assert(EtherFiDataProvider(dataProvider).isDefaultModule(MIDAS_MODULE));
        assert(IDebtManager(debtManager).isCollateralToken(MIDAS_TOKEN));
        assert(RoleRegistry(roleRegistryAddr).hasRole(MIDAS_MODULE_ADMIN, CASH_CONTROLLER_SAFE));

        (address dv, address rv) = MidasModule(MIDAS_MODULE).vaults(MIDAS_TOKEN);
        assert(dv == DEPOSIT_VAULT);
        assert(rv == REDEMPTION_VAULT);
    }

    function _configureDefaultModulesTx(address dataProvider) internal pure returns (string memory) {
        address[] memory modules = new address[](1);
        modules[0] = MIDAS_MODULE;

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        bytes memory data = abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, modules, shouldWhitelist);
        return _getGnosisTransaction(addressToHex(dataProvider), iToHex(data), "0", false);
    }

    function _grantMidasModuleAdminTx(address roleRegistryAddr) internal pure returns (string memory) {
        bytes memory data = abi.encodeWithSelector(RoleRegistry.grantRole.selector, MIDAS_MODULE_ADMIN, CASH_CONTROLLER_SAFE);
        return _getGnosisTransaction(addressToHex(roleRegistryAddr), iToHex(data), "0", false);
    }

    function _addMidasVaultsTx() internal pure returns (string memory) {
        address[] memory midasTokens = new address[](1);
        midasTokens[0] = MIDAS_TOKEN;

        address[] memory depositVaults = new address[](1);
        depositVaults[0] = DEPOSIT_VAULT;

        address[] memory redemptionVaults = new address[](1);
        redemptionVaults[0] = REDEMPTION_VAULT;

        bytes memory data = abi.encodeWithSelector(MidasModule.addMidasVaults.selector, midasTokens, depositVaults, redemptionVaults);
        return _getGnosisTransaction(addressToHex(MIDAS_MODULE), iToHex(data), "0", false);
    }

    function _setTokenConfigTx(address priceProvider) internal view returns (string memory) {
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

        bytes memory data = abi.encodeWithSelector(PriceProvider.setTokenConfig.selector, tokens, configs);
        return _getGnosisTransaction(addressToHex(priceProvider), iToHex(data), "0", false);
    }

    function _supportCollateralTx(address debtManager) internal pure returns (string memory) {
        IDebtManager.CollateralTokenConfig memory collateralConfig = IDebtManager.CollateralTokenConfig({
            ltv: LTV,
            liquidationThreshold: LIQUIDATION_THRESHOLD,
            liquidationBonus: LIQUIDATION_BONUS
        });

        bytes memory data = abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, MIDAS_TOKEN, collateralConfig);
        return _getGnosisTransaction(addressToHex(debtManager), iToHex(data), "0", false);
    }

    function _supportBorrowTx(address debtManager) internal pure returns (string memory) {
        uint64 borrowApy = 1;
        uint128 minShares = type(uint128).max;

        bytes memory data = abi.encodeWithSelector(IDebtManager.supportBorrowToken.selector, MIDAS_TOKEN, borrowApy, minShares);
        return _getGnosisTransaction(addressToHex(debtManager), iToHex(data), "0", false);
    }

    function _configureWithdrawTx(address cashModule) internal pure returns (string memory) {
        address[] memory withdrawableAssets = new address[](1);
        withdrawableAssets[0] = MIDAS_TOKEN;

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        bytes memory data = abi.encodeWithSelector(ICashModule.configureWithdrawAssets.selector, withdrawableAssets, shouldWhitelist);
        return _getGnosisTransaction(addressToHex(cashModule), iToHex(data), "0", true);
    }
}
