// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { LendRails } from "../stock-listing/StockLendConfig.sol";
import { StockMigration3CPBase } from "./StockMigration3CPBase.sol";
import { MigratedStock, StockMigration } from "./StockMigrationConfig.sol";

/**
 * @title FlipStockPricesCashOP3CP
 * @notice OPERATING SAFE bundle for the weekend, executed right after the Lend Owner Safe's flip: one
 *         PriceProviderV2.setTokenConfig that moves the three wrappers from the 1 unit placeholder to their
 *         own `convertToAssets(1e18)` rate composed on the <STOCK>/USD base entry, and the three mirrors to
 *         the 1 unit placeholder. One transaction, so DebtManager and CashLens never count both. The mirrors
 *         stay listed as DebtManager collateral so existing positions keep resolving; they count for nothing.
 *
 *         The 6-decimal placeholder exists because PriceProviderV2 reports 6 decimals and would floor an
 *         8-decimal 1 wei to zero and revert.
 *
 * Usage (after the Cash config bundle; the fork replays it when the wrappers are not yet priced):
 *   forge script scripts/stock-migration/FlipStockPricesCashOP3CP.s.sol --rpc-url $OPTIMISM_RPC -vvv
 */
contract FlipStockPricesCashOP3CP is StockMigration3CPBase {
    string constant OUTPUT = "./output/FlipStockPricesCashOP3CP-10.json";
    string constant CONFIG_BUNDLE = "./output/ConfigureStockWrappersCashOP3CP-10.json";
    string constant LISTING_BUNDLE = "./output/ListStockWrappersSummerLend3CP-10.json";

    function run() public {
        _requireOptimismProd();
        string memory deployments = readDeploymentFile();
        PriceProviderV2 pp = PriceProviderV2(stdJson.readAddress(deployments, ".addresses.PriceProvider"));
        IDebtManager debtManager = IDebtManager(stdJson.readAddress(deployments, ".addresses.DebtManager"));
        MigrationFeeds memory feeds = _deployMigrationFeeds(true);
        MigratedStock[] memory stocks = StockMigration.all();
        _ensureConfigured(pp, stocks);

        uint256[] memory mirrorPrices = new uint256[](stocks.length);
        for (uint256 i = 0; i < stocks.length; ++i) {
            MigratedStock memory s = stocks[i];
            require(pp.price(s.wrapper) == 1, string.concat(s.symbol, ": wrapper is not on the placeholder; already flipped?"));
            mirrorPrices[i] = pp.price(s.iToken);
            require(mirrorPrices[i] > 1, string.concat(s.symbol, ": mirror already retired on the Cash side"));
        }

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(LendRails.OPERATING_SAFE));
        txs = _append(txs, address(pp), _flipCall(stocks, feeds.oneUnit6), true);
        vm.createDir("./output", true);
        vm.writeFile(OUTPUT, txs);
        console.log("Written: %s", OUTPUT);

        executeGnosisTransactionBundle(OUTPUT);
        for (uint256 i = 0; i < stocks.length; ++i) {
            MigratedStock memory s = stocks[i];
            assertApproxEqRel(pp.price(s.wrapper), mirrorPrices[i], 0.001e18, "wrapper Cash price vs mirror before flip");
            assertEq(pp.price(s.iToken), 1, "mirror Cash price");
            assertTrue(debtManager.isCollateralToken(s.iToken), "mirror dropped from DebtManager");
            console.log(string.concat("  ", s.symbol, ": wrapper at ", vm.toString(pp.price(s.wrapper)), " (6 dec), mirror at 1"));
        }
        console.log("Simulation passed.");
    }

    /// @dev Wrappers: own redemption rate in 18 decimals composed on the stock's 8-decimal USD base entry
    ///      (the base entry carries the staleness). Mirrors: the constant 1 unit placeholder.
    function _flipCall(MigratedStock[] memory stocks, address oneUnit6) internal pure returns (bytes memory) {
        address[] memory tokens = new address[](stocks.length * 2);
        PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](stocks.length * 2);
        for (uint256 i = 0; i < stocks.length; ++i) {
            tokens[i] = stocks[i].wrapper;
            configs[i] = PriceProviderV2.Config({ oracle: stocks[i].wrapper, priceFunctionCalldata: abi.encodeCall(IERC4626.convertToAssets, (1e18)), isChainlinkType: false, oraclePriceDecimals: 18, maxStaleness: 0, dataType: PriceProviderV2.ReturnType.Uint256, isStableToken: false, baseAsset: stocks[i].stock });
            tokens[stocks.length + i] = stocks[i].iToken;
            configs[stocks.length + i] = PriceProviderV2.Config({ oracle: oneUnit6, priceFunctionCalldata: abi.encodeCall(IAaveV4PriceFeed.latestAnswer, ()), isChainlinkType: false, oraclePriceDecimals: 6, maxStaleness: 0, dataType: PriceProviderV2.ReturnType.Int256, isStableToken: false, baseAsset: address(0) });
        }
        return abi.encodeCall(PriceProviderV2.setTokenConfig, (tokens, configs));
    }

    function _ensureConfigured(PriceProviderV2 pp, MigratedStock[] memory stocks) internal {
        bool configured = true;
        for (uint256 i = 0; i < stocks.length; ++i) {
            configured = configured && pp.tokenConfig(stocks[i].wrapper).oracle != address(0);
        }
        if (configured) return;
        require(vm.exists(CONFIG_BUNDLE), "wrappers not priced on the Cash side; generate the config bundle first");
        if (_reserveIdOf(stocks[0].wrapper) == type(uint256).max) {
            require(vm.exists(LISTING_BUNDLE), "wrappers not listed; generate the listing bundle first");
            console.log("Wrappers not yet listed live; replaying the listing bundle on the fork");
            executeGnosisTransactionBundle(LISTING_BUNDLE);
        }
        console.log("Wrappers not yet configured live; replaying the Cash config bundle on the fork");
        executeGnosisTransactionBundle(CONFIG_BUNDLE);
    }
}
