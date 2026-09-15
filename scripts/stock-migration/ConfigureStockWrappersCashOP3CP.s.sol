// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { ILendGatewayLike, LendRails } from "../stock-listing/StockLendConfig.sol";
import { StockMigration3CPBase } from "./StockMigration3CPBase.sol";
import { MigratedStock, StockMigration } from "./StockMigrationConfig.sol";

/**
 * @title ConfigureStockWrappersCashOP3CP
 * @notice OPERATING SAFE bundle that makes the three OP wrappers first-class Cash assets before the
 *         weekend, so the lend sweep can supply them and DebtManager can count them:
 *
 *           1. PriceProviderV2.setTokenConfig for wSPYx, wQQQx, wTBLLx at the constant 1 unit placeholder,
 *              the same idea as the 1 wei Aave listing: the wrapper exists as collateral but counts for
 *              0.000001 USD until the Cash-side flip, so a DebtManager safe never counts mirror and wrapper
 *              at once.
 *           2. DebtManager.supportCollateralToken for each wrapper, parameters copied live from the mirror.
 *           3. LendGateway.setReserveId for each wrapper, the reserve id the listing bundle assigns.
 *           4. CashModule.configureWithdrawAssets whitelisting the raw stocks for OP withdrawals.
 *
 *         Order is load-bearing inside the bundle: tx 2 reads the price tx 1 configures.
 *
 * Usage (after the listing bundle is generated; the fork replays it when the wrappers are not live):
 *   forge script scripts/stock-migration/ConfigureStockWrappersCashOP3CP.s.sol --rpc-url $OPTIMISM_RPC -vvv
 */
contract ConfigureStockWrappersCashOP3CP is StockMigration3CPBase {
    string constant OUTPUT = "./output/ConfigureStockWrappersCashOP3CP-10.json";
    string constant LISTING_BUNDLE = "./output/ListStockWrappersSummerLend3CP-10.json";

    PriceProviderV2 internal pp;
    IDebtManager internal debtManager;
    ILendGatewayLike internal gateway;
    ICashModule internal cashModule;

    function run() public {
        _requireOptimismProd();
        _loadContracts();
        MigrationFeeds memory feeds = _deployMigrationFeeds(true);

        MigratedStock[] memory stocks = StockMigration.all();
        uint256[] memory newIds = _newReserveIds(stocks);
        for (uint256 i = 0; i < stocks.length; ++i) {
            MigratedStock memory s = stocks[i];
            require(pp.isBaseAsset(s.stock), string.concat(s.symbol, ": no <STOCK>/USD base entry on PriceProviderV2"));
            require(pp.tokenConfig(s.wrapper).oracle == address(0), string.concat(s.symbol, ": wrapper already priced on the Cash side"));
            require(!debtManager.isCollateralToken(s.wrapper), string.concat(s.symbol, ": wrapper already a DebtManager collateral"));
            require(debtManager.isCollateralToken(s.iToken), string.concat(s.symbol, ": mirror is not a DebtManager collateral to copy from"));
        }

        _writeBundle(stocks, newIds, feeds.oneUnit6);
        console.log("Written: %s", OUTPUT);

        executeGnosisTransactionBundle(OUTPUT);
        for (uint256 i = 0; i < stocks.length; ++i) {
            _assertConfigured(stocks[i], newIds[i]);
        }
        console.log("Simulation passed.");
    }

    function _loadContracts() internal {
        string memory deployments = readDeploymentFile();
        pp = PriceProviderV2(stdJson.readAddress(deployments, ".addresses.PriceProvider"));
        debtManager = IDebtManager(stdJson.readAddress(deployments, ".addresses.DebtManager"));
        gateway = ILendGatewayLike(stdJson.readAddress(deployments, ".addresses.LendGateway"));
        cashModule = ICashModule(stdJson.readAddress(deployments, ".addresses.CashModule"));
    }

    function _writeBundle(MigratedStock[] memory stocks, uint256[] memory newIds, address oneUnit6) internal {
        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(LendRails.OPERATING_SAFE));
        txs = _append(txs, address(pp), _placeholderPriceCall(stocks, oneUnit6), false);
        for (uint256 i = 0; i < stocks.length; ++i) {
            txs = _append(txs, address(debtManager), abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, stocks[i].wrapper, debtManager.collateralTokenConfig(stocks[i].iToken)), false);
        }
        for (uint256 i = 0; i < stocks.length; ++i) {
            txs = _append(txs, address(gateway), abi.encodeCall(ILendGatewayLike.setReserveId, (stocks[i].wrapper, newIds[i])), false);
        }
        txs = _append(txs, address(cashModule), _withdrawAssetsCall(stocks), true);

        vm.createDir("./output", true);
        vm.writeFile(OUTPUT, txs);
    }

    /// @dev The 6-decimal placeholder: PriceProviderV2 reports 6 decimals and would floor an 8-decimal 1 wei
    ///      to zero and revert, hence a constant 1 unit read through latestAnswer().
    function _placeholderPriceCall(MigratedStock[] memory stocks, address oneUnit6) internal pure returns (bytes memory) {
        address[] memory tokens = new address[](stocks.length);
        PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](stocks.length);
        for (uint256 i = 0; i < stocks.length; ++i) {
            tokens[i] = stocks[i].wrapper;
            configs[i] = PriceProviderV2.Config({ oracle: oneUnit6, priceFunctionCalldata: abi.encodeCall(IAaveV4PriceFeed.latestAnswer, ()), isChainlinkType: false, oraclePriceDecimals: 6, maxStaleness: 0, dataType: PriceProviderV2.ReturnType.Int256, isStableToken: false, baseAsset: address(0) });
        }
        return abi.encodeCall(PriceProviderV2.setTokenConfig, (tokens, configs));
    }

    function _withdrawAssetsCall(MigratedStock[] memory stocks) internal pure returns (bytes memory) {
        address[] memory assets = new address[](stocks.length);
        bool[] memory flags = new bool[](stocks.length);
        for (uint256 i = 0; i < stocks.length; ++i) {
            assets[i] = stocks[i].stock;
            flags[i] = true;
        }
        return abi.encodeCall(ICashModule.configureWithdrawAssets, (assets, flags));
    }

    function _assertConfigured(MigratedStock memory s, uint256 newId) internal view {
        assertEq(pp.price(s.wrapper), 1, "wrapper Cash price is not the placeholder");

        IDebtManager.CollateralTokenConfig memory got = debtManager.collateralTokenConfig(s.wrapper);
        IDebtManager.CollateralTokenConfig memory want = debtManager.collateralTokenConfig(s.iToken);
        assertTrue(debtManager.isCollateralToken(s.wrapper), "not a DebtManager collateral");
        assertEq(uint256(got.ltv), uint256(want.ltv), "ltv");
        assertEq(uint256(got.liquidationThreshold), uint256(want.liquidationThreshold), "liquidationThreshold");
        assertEq(uint256(got.liquidationBonus), uint256(want.liquidationBonus), "liquidationBonus");

        assertEq(gateway.reserveIdOf(s.wrapper), newId, "gateway reserve id");
        assertTrue(_isWithdrawAsset(s.stock), "raw stock not a withdraw asset");
        console.log(string.concat("  ", s.symbol, ": wrapper at the 1 unit placeholder, DebtManager collateral, gateway reserve ", vm.toString(newId)));
    }

    function _isWithdrawAsset(address token) internal view returns (bool) {
        address[] memory assets = cashModule.getWhitelistedWithdrawAssets();
        for (uint256 i = 0; i < assets.length; ++i) {
            if (assets[i] == token) return true;
        }
        return false;
    }

    function _newReserveIds(MigratedStock[] memory stocks) internal returns (uint256[] memory) {
        uint256[] memory ids = new uint256[](stocks.length);
        bool listed = true;
        for (uint256 i = 0; i < stocks.length; ++i) {
            ids[i] = _reserveIdOf(stocks[i].wrapper);
            listed = listed && ids[i] != type(uint256).max;
        }
        if (listed) return ids;

        require(vm.exists(LISTING_BUNDLE), "wrappers not listed; generate the listing bundle first");
        console.log("Wrappers not yet listed live; replaying the listing bundle on the fork");
        executeGnosisTransactionBundle(LISTING_BUNDLE);
        for (uint256 i = 0; i < stocks.length; ++i) {
            ids[i] = _reserveIdOf(stocks[i].wrapper);
            require(ids[i] != type(uint256).max, "listing bundle did not list the wrapper");
        }
        return ids;
    }
}
