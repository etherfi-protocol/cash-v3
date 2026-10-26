// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { stdJson } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { StockMigrationModule } from "../../src/migration/StockMigrationModule.sol";
import { StockWrapModule } from "../../src/modules/stock-wrap/StockWrapModule.sol";
import { StockBridgeWithdrawModule } from "../../src/stock-withdraw/StockBridgeWithdrawModule.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { XStocksOPDeployer } from "./XStocksOPDeployer.sol";
import { XStock, XStocksOPProd as C } from "./XStocksOPProdConfig.sol";

/**
 * @title DeployXStocksOP
 * @notice Deploys everything the xStocks launch bundles on Optimism prod point at, through the EtherFiDeployer:
 *         the three wrapper price feeds, the migration, wrap and bridge-withdraw modules (implementation and
 *         proxy each) and the TopUpDest implementation that adds wrapStock. No config happens here; every
 *         setter is owner or admin gated and goes through XStocksOPLaunch3CP.
 * @dev Idempotent: a salt that already holds code is returned, not redeployed. Feed addresses land in
 *      summer-lend-feeds.json, the rest in deployments.json.
 *
 * Usage:
 *   source .env && forge script scripts/xstocks-op/DeployXStocksOP.s.sol --rpc-url $OPTIMISM_RPC --account dev-admin --broadcast --verify -vvv
 */
contract DeployXStocksOP is XStocksOPDeployer {
    using stdJson for string;

    function run() public {
        require(block.chainid == C.OP_CHAIN_ID, "Optimism only");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");
        string memory deployments = readDeploymentFile();
        address dataProvider = deployments.readAddress(".addresses.EtherFiDataProvider");
        address roleRegistry = deployments.readAddress(".addresses.RoleRegistry");
        string memory feedsPath = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/summer-lend-feeds.json");
        string memory feeds = vm.readFile(feedsPath);
        XStock[] memory stocks = C.stocks();
        for (uint256 i; i < stocks.length; ++i) {
            require(IERC4626(stocks[i].wrapper).asset() == stocks[i].raw, string.concat(stocks[i].symbol, ": wrapper asset mismatch"));
        }

        vm.startBroadcast();
        OPDeployment memory d = _deployOP(false, dataProvider, roleRegistry, feeds);
        vm.stopBroadcast();

        for (uint256 i; i < stocks.length; ++i) {
            require(IAaveV4PriceFeed(d.wrapperFeeds[i]).latestAnswer() > 0, string.concat(stocks[i].symbol, ": wrapper feed does not price"));
            console.log(string.concat(stocks[i].feedDesc, " feed:"), d.wrapperFeeds[i]);
        }
        require(address(StockMigrationModule(d.migration).roleRegistry()) == roleRegistry, "migration role registry mismatch");
        require(address(StockWrapModule(d.wrap).roleRegistry()) == roleRegistry, "wrap role registry mismatch");
        (address bridge, uint64 selector) = StockBridgeWithdrawModule(d.bridgeWithdraw).getBridge();
        require(bridge == C.BACKED_BRIDGE && selector == C.ETHEREUM_SELECTOR, "bridge module config mismatch");
        require(address(TopUpDest(payable(d.topUpDestImpl)).etherFiDataProvider()) == dataProvider, "TopUpDest impl data provider mismatch");

        console.log("StockMigrationModule:", d.migration, "impl:", d.migrationImpl);
        console.log("StockWrapModule:", d.wrap, "impl:", d.wrapImpl);
        console.log("StockBridgeWithdrawModule:", d.bridgeWithdraw, "impl:", d.bridgeWithdrawImpl);
        console.log("TopUpDest impl:", d.topUpDestImpl);

        string memory path = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/deployments.json");
        _write(path, C.KEY_MIGRATION, d.migration);
        _write(path, string.concat(C.KEY_MIGRATION, "Impl"), d.migrationImpl);
        _write(path, C.KEY_WRAP, d.wrap);
        _write(path, string.concat(C.KEY_WRAP, "Impl"), d.wrapImpl);
        _write(path, C.KEY_BRIDGE_WITHDRAW, d.bridgeWithdraw);
        _write(path, string.concat(C.KEY_BRIDGE_WITHDRAW, "Impl"), d.bridgeWithdrawImpl);
        _write(path, C.KEY_TOP_UP_DEST_IMPL, d.topUpDestImpl);
        _recordFeeds(feedsPath, feeds, stocks, d.wrapperFeeds);
    }

    function _write(string memory path, string memory key, address value) internal {
        vm.writeJson(string.concat('"', vm.toString(value), '"'), path, string.concat(".addresses.", key));
    }

    /// @dev Rewrites the feed manifest with every existing entry plus the three wrapper feeds
    function _recordFeeds(string memory path, string memory existing, XStock[] memory stocks, address[] memory wrapperFeeds) internal {
        string memory details;
        string[] memory keys = vm.parseJsonKeys(existing, ".details");
        for (uint256 i; i < keys.length; ++i) {
            address oracle = vm.parseJsonAddress(existing, string.concat(".details.", keys[i], ".oracle"));
            details = vm.serializeString("feed-details", keys[i], vm.serializeAddress(string.concat("feed-", keys[i]), "oracle", oracle));
        }
        for (uint256 i; i < stocks.length; ++i) {
            details = vm.serializeString("feed-details", stocks[i].feedKey, vm.serializeAddress(string.concat("feed-", stocks[i].feedKey), "oracle", wrapperFeeds[i]));
        }
        vm.writeJson(vm.serializeString("feed-root", "details", details), path);
        console.log("Feed addresses merged into:", path);
    }
}
