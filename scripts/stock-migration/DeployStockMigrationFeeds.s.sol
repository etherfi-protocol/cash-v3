// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { console } from "forge-std/console.sol";

import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { ConstantPriceFeed } from "../../src/oracle/ConstantPriceFeed.sol";
import { ERC4626RatePriceFeed } from "../../src/oracle/ERC4626RatePriceFeed.sol";
import { StockFeedDeployer } from "../stock-listing/DeployStockProdFeeds.s.sol";
import { IAaveOracleLike, LendRails } from "../stock-listing/StockLendConfig.sol";
import { MigratedStock, StockMigration } from "./StockMigrationConfig.sol";

/**
 * @title StockMigrationFeedDeployer
 * @notice Shared feed core for moving the three collateral stocks onto Backed's OP wrappers. Deploys,
 *         or reuses, through the EtherFiDeployer (CREATE3) so every address is final before any bundle
 *         is proposed, and so the 3CP generators can rehearse the same addresses on a fork by pranking
 *         the registered deployer.
 *
 *         Five feeds:
 *           - wSPYx, wQQQx, wTBLLx / USD: {ERC4626RatePriceFeed} on the OP wrapper, composed on the same
 *             live <STOCK>/USD leg the mirror reserve already uses. No relay.
 *           - 1 wei at 8 decimals: the Aave placeholder. New reserves list on it so supplied wrapper
 *             counts for nothing until the flip; retired reserves point at it afterwards.
 *           - 1 unit at 6 decimals: the same idea for PriceProviderV2, whose 6-decimal output would
 *             floor an 8-decimal 1 wei to zero and revert.
 */
abstract contract StockMigrationFeedDeployer is StockFeedDeployer {
    struct MigrationFeeds {
        address[] wrapperUsd;
        address oneWei8;
        address oneUnit6;
    }

    function _deployMigrationFeeds(bool rehearsal) internal returns (MigrationFeeds memory) {
        if (address(etherFiDeployer) == address(0)) _loadEtherFiDeployer();
        if (rehearsal) require(etherFiDeployer.isDeployer(REGISTERED_DEPLOYER), "rehearsal prank address is not a registered deployer");

        MigratedStock[] memory stocks = StockMigration.all();
        MigrationFeeds memory feeds;
        feeds.wrapperUsd = new address[](stocks.length);

        for (uint256 i = 0; i < stocks.length; ++i) {
            MigratedStock memory s = stocks[i];
            require(IERC4626(s.wrapper).asset() == s.stock, string.concat(s.symbol, ": wrapper does not wrap the raw stock"));
            require(IAaveOracleLike(LendRails.AAVE_ORACLE).getReserveSource(s.oldReserveId) != address(0), string.concat(s.symbol, ": old reserve has no source"));
            require(IAaveV4PriceFeed(s.stockUsdLeg).latestAnswer() > 0, string.concat(s.symbol, ": stock/USD leg is not live"));

            feeds.wrapperUsd[i] = _create3(rehearsal, StockMigration.FEED_SALT_PREFIX, s.wrapperFeedName, abi.encodePacked(type(ERC4626RatePriceFeed).creationCode, abi.encode(s.wrapper, s.stockUsdLeg, LendRails.FEED_DECIMALS, s.wrapperFeedDesc)));
            require(address(ERC4626RatePriceFeed(feeds.wrapperUsd[i]).vault()) == s.wrapper, string.concat(s.symbol, ": feed wraps the wrong vault"));
            require(address(ERC4626RatePriceFeed(feeds.wrapperUsd[i]).underlyingUsdFeed()) == s.stockUsdLeg, string.concat(s.symbol, ": feed composed on the wrong leg"));
        }

        feeds.oneWei8 = _create3(rehearsal, StockMigration.FEED_SALT_PREFIX, StockMigration.ONE_WEI_8_NAME, abi.encodePacked(type(ConstantPriceFeed).creationCode, abi.encode(int256(1), LendRails.FEED_DECIMALS, StockMigration.ONE_WEI_8_DESC)));
        feeds.oneUnit6 = _create3(rehearsal, StockMigration.FEED_SALT_PREFIX, StockMigration.ONE_UNIT_6_NAME, abi.encodePacked(type(ConstantPriceFeed).creationCode, abi.encode(int256(1), uint8(6), StockMigration.ONE_UNIT_6_DESC)));
        require(IAaveV4PriceFeed(feeds.oneWei8).latestAnswer() == 1 && IAaveV4PriceFeed(feeds.oneWei8).decimals() == 8, "1 wei feed misconfigured");
        require(IAaveV4PriceFeed(feeds.oneUnit6).latestAnswer() == 1 && IAaveV4PriceFeed(feeds.oneUnit6).decimals() == 6, "1 unit feed misconfigured");
        return feeds;
    }

    /// @dev Each wrapper feed must land within 0.1% of the mirror reserve's live price: same rate on
    ///      both chains, same USD leg, so a wider gap means a wrong leg or a wrong vault.
    function _requireFeedsTrackMirrors(MigrationFeeds memory feeds) internal view {
        MigratedStock[] memory stocks = StockMigration.all();
        for (uint256 i = 0; i < stocks.length; ++i) {
            uint256 local = SafeCast.toUint256(IAaveV4PriceFeed(feeds.wrapperUsd[i]).latestAnswer());
            uint256 mirror = IAaveOracleLike(LendRails.AAVE_ORACLE).getReservePrice(stocks[i].oldReserveId);
            uint256 gap = local > mirror ? local - mirror : mirror - local;
            require(gap * 1000 <= mirror, string.concat(stocks[i].symbol, ": wrapper feed is more than 0.1% off the mirror price"));
            console.log(string.concat("  ", stocks[i].wrapperFeedDesc, " local ", vm.toString(local), " mirror ", vm.toString(mirror)));
        }
    }

    /// @dev Merges the five feeds into summer-lend-feeds.json's `.details` map, keeping every existing entry.
    function _recordMigrationFeeds(MigrationFeeds memory feeds) internal {
        string memory path = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/summer-lend-feeds.json");
        string memory existing = vm.readFile(path);

        string memory details;
        string[] memory keys = vm.parseJsonKeys(existing, ".details");
        for (uint256 i; i < keys.length; ++i) {
            address oracle = vm.parseJsonAddress(existing, string.concat(".details.", keys[i], ".oracle"));
            details = vm.serializeString("migration-details", keys[i], vm.serializeAddress(string.concat("feed-", keys[i]), "oracle", oracle));
        }
        MigratedStock[] memory stocks = StockMigration.all();
        for (uint256 i = 0; i < stocks.length; ++i) {
            string memory key = string.concat("w", stocks[i].symbol);
            details = vm.serializeString("migration-details", key, vm.serializeAddress(string.concat("feed-", key), "oracle", feeds.wrapperUsd[i]));
        }
        details = vm.serializeString("migration-details", "OneWei8", vm.serializeAddress("feed-OneWei8", "oracle", feeds.oneWei8));
        details = vm.serializeString("migration-details", "OneUnit6", vm.serializeAddress("feed-OneUnit6", "oracle", feeds.oneUnit6));

        vm.writeJson(vm.serializeString("migration-root", "details", details), path);
        console.log("Feed addresses merged into:", path);
    }
}

/**
 * @title DeployStockMigrationFeeds
 * @notice Broadcasts the five migration feeds on Optimism and records them. Immutable and admin-less, so
 *         this runs any time before the listing bundle is proposed.
 *
 * Usage (simulate by dropping --broadcast; the sender must be a registered EtherFiDeployer deployer):
 *   source .env && ENV=mainnet forge script scripts/stock-migration/DeployStockMigrationFeeds.s.sol \
 *     --rpc-url $OPTIMISM_RPC --account dev-admin --sender $PROD_DEPLOYER --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvv
 */
contract DeployStockMigrationFeeds is StockMigrationFeedDeployer {
    function run() public {
        require(block.chainid == 10, "Must run on Optimism (10)");
        require(isEqualString(getEnv(), "mainnet"), "prod-only: run with ENV=mainnet");

        vm.startBroadcast();
        MigrationFeeds memory feeds = _deployMigrationFeeds(false);
        vm.stopBroadcast();

        _requireFeedsTrackMirrors(feeds);
        _recordMigrationFeeds(feeds);
    }
}
