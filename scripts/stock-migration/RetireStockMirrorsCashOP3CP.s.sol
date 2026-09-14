// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { LendRails } from "../stock-listing/StockLendConfig.sol";
import { StockMigration3CPBase } from "./StockMigration3CPBase.sol";
import { MigratedStock, StockMigration } from "./StockMigrationConfig.sol";

/**
 * @title RetireStockMirrorsCashOP3CP
 * @notice OPERATING SAFE bundle for the weekend, executed right after the Lend Owner Safe's flip: one
 *         PriceProviderV2.setTokenConfig pointing iwSPYx, iwQQQx and iwTBLLx at the constant 1 unit feed,
 *         so DebtManager and CashLens value the retired mirrors at 0.000001 USD. The mirrors stay listed as
 *         DebtManager collateral, so existing positions keep resolving; they just count for nothing.
 *
 *         The 6-decimal placeholder exists because PriceProviderV2 reports 6 decimals and would floor an
 *         8-decimal 1 wei to zero and revert.
 *
 * Usage:
 *   forge script scripts/stock-migration/RetireStockMirrorsCashOP3CP.s.sol --rpc-url $OPTIMISM_RPC -vvv
 */
contract RetireStockMirrorsCashOP3CP is StockMigration3CPBase {
    string constant OUTPUT = "./output/RetireStockMirrorsCashOP3CP-10.json";

    function run() public {
        _requireOptimismProd();
        string memory deployments = readDeploymentFile();
        PriceProviderV2 pp = PriceProviderV2(stdJson.readAddress(deployments, ".addresses.PriceProvider"));
        IDebtManager debtManager = IDebtManager(stdJson.readAddress(deployments, ".addresses.DebtManager"));
        MigrationFeeds memory feeds = _deployMigrationFeeds(true);

        MigratedStock[] memory stocks = StockMigration.all();
        for (uint256 i = 0; i < stocks.length; ++i) {
            require(pp.price(stocks[i].iToken) > 1, string.concat(stocks[i].symbol, ": mirror already retired on the Cash side"));
        }

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(LendRails.OPERATING_SAFE));
        txs = _append(txs, address(pp), _retireCall(stocks, feeds.oneUnit6), true);
        vm.createDir("./output", true);
        vm.writeFile(OUTPUT, txs);
        console.log("Written: %s", OUTPUT);

        executeGnosisTransactionBundle(OUTPUT);
        for (uint256 i = 0; i < stocks.length; ++i) {
            assertEq(pp.price(stocks[i].iToken), 1, "mirror Cash price");
            assertTrue(debtManager.isCollateralToken(stocks[i].iToken), "mirror dropped from DebtManager");
            console.log(string.concat("  ", stocks[i].symbol, ": mirror priced at 1 (6 dec)"));
        }
        console.log("Simulation passed.");
    }

    function _retireCall(MigratedStock[] memory stocks, address oneUnit6) internal pure returns (bytes memory) {
        address[] memory tokens = new address[](stocks.length);
        PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](stocks.length);
        for (uint256 i = 0; i < stocks.length; ++i) {
            tokens[i] = stocks[i].iToken;
            configs[i] = PriceProviderV2.Config({ oracle: oneUnit6, priceFunctionCalldata: abi.encodeCall(IAaveV4PriceFeed.latestAnswer, ()), isChainlinkType: false, oraclePriceDecimals: 6, maxStaleness: 0, dataType: PriceProviderV2.ReturnType.Int256, isStableToken: false, baseAsset: address(0) });
        }
        return abi.encodeCall(PriceProviderV2.setTokenConfig, (tokens, configs));
    }
}
