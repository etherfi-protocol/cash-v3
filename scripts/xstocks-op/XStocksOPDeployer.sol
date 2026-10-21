// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { StockMigrationModule } from "../../src/migration/StockMigrationModule.sol";
import { StockWrapModule } from "../../src/modules/stock-wrap/StockWrapModule.sol";
import { ERC4626RatePriceFeed } from "../../src/oracle/ERC4626RatePriceFeed.sol";
import { StockBridgeWithdrawModule } from "../../src/stock-withdraw/StockBridgeWithdrawModule.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { BackedCCIPBridgeAdapter } from "../../src/top-up/bridge/BackedCCIPBridgeAdapter.sol";
import { EtherFiDeployerHelper } from "../utils/EtherFiDeployerHelper.sol";
import { XStock, XStocksOPProd as C } from "./XStocksOPProdConfig.sol";

/**
 * @title XStocksOPDeployer
 * @notice The CREATE3 deploys of the xStocks launch, shared by the deploy scripts (broadcast) and the bundle
 *         generators (fork rehearsal, pranking the registered deployer), so both resolve the same addresses
 *         from the same salts and initcode.
 */
abstract contract XStocksOPDeployer is EtherFiDeployerHelper {
    using stdJson for string;

    struct OPDeployment {
        address[] wrapperFeeds;
        address migration;
        address migrationImpl;
        address wrap;
        address wrapImpl;
        address bridgeWithdraw;
        address bridgeWithdrawImpl;
        address topUpDestImpl;
    }

    /// @dev Registered EtherFiDeployer deployer on both chains, pranked for fork rehearsals
    address internal constant REGISTERED_DEPLOYER = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;

    /// @dev Deploys (or reuses) everything the Optimism bundles point at. `feeds` is summer-lend-feeds.json.
    function _deployOP(bool rehearsal, address dataProvider, address roleRegistry, string memory feeds) internal returns (OPDeployment memory) {
        XStock[] memory stocks = C.stocks();
        OPDeployment memory d;
        d.wrapperFeeds = new address[](stocks.length);
        for (uint256 i; i < stocks.length; ++i) {
            address leg = feeds.readAddress(string.concat(".details.", stocks[i].legKey, ".oracle"));
            d.wrapperFeeds[i] = _create3(rehearsal, stocks[i].feedSalt, type(ERC4626RatePriceFeed).creationCode, abi.encode(stocks[i].wrapper, leg, uint8(8), stocks[i].feedDesc));
        }
        d.migrationImpl = _create3(rehearsal, _salt(C.KEY_MIGRATION, true), type(StockMigrationModule).creationCode, abi.encode(dataProvider));
        d.migration = _create3(rehearsal, _salt(C.KEY_MIGRATION, false), type(UUPSProxy).creationCode, abi.encode(d.migrationImpl, abi.encodeCall(StockMigrationModule.initialize, (roleRegistry))));
        d.wrapImpl = _create3(rehearsal, _salt(C.KEY_WRAP, true), type(StockWrapModule).creationCode, abi.encode(dataProvider));
        d.wrap = _create3(rehearsal, _salt(C.KEY_WRAP, false), type(UUPSProxy).creationCode, abi.encode(d.wrapImpl, abi.encodeCall(StockWrapModule.initialize, (roleRegistry))));
        d.bridgeWithdrawImpl = _create3(rehearsal, _salt(C.KEY_BRIDGE_WITHDRAW, true), type(StockBridgeWithdrawModule).creationCode, abi.encode(dataProvider));
        d.bridgeWithdraw = _create3(rehearsal, _salt(C.KEY_BRIDGE_WITHDRAW, false), type(UUPSProxy).creationCode, abi.encode(d.bridgeWithdrawImpl, abi.encodeCall(StockBridgeWithdrawModule.initialize, (roleRegistry, C.BACKED_BRIDGE, C.ETHEREUM_SELECTOR))));
        d.topUpDestImpl = _create3(rehearsal, _salt(C.KEY_TOP_UP_DEST_IMPL, false), type(TopUpDest).creationCode, abi.encode(dataProvider, C.OP_WETH));
        return d;
    }

    function _deployAdapter(bool rehearsal) internal returns (address) {
        return _create3(rehearsal, C.SALT_CCIP_ADAPTER, type(BackedCCIPBridgeAdapter).creationCode, "");
    }

    function _salt(string memory key, bool impl) internal pure returns (string memory) {
        return string.concat(C.SALT_PREFIX, key, impl ? "Impl" : "");
    }

    /// @dev Like EtherFiDeployerHelper._create3, with the registered deployer pranked on a rehearsal
    function _create3(bool rehearsal, string memory saltName, bytes memory creationCode, bytes memory constructorArgs) internal returns (address) {
        address predicted = _predictAddress(saltName);
        if (predicted.code.length != 0) return predicted;
        if (rehearsal) vm.prank(REGISTERED_DEPLOYER);
        address actual = DEPLOYER.deploy(getSalt(saltName), abi.encodePacked(creationCode, constructorArgs));
        require(actual == predicted, string.concat("CREATE3 address mismatch: ", saltName));
        console.log(string.concat(rehearsal ? "  [REHEARSAL] " : "  ", saltName, ":"), predicted);
        return predicted;
    }

    /// @dev A manifest entry, when present, must be the CREATE3 address; a different one means a hijacked manifest
    function _checkRecorded(string memory manifest, string memory key, address predicted) internal view {
        string memory path = string.concat(".addresses.", key);
        if (vm.keyExistsJson(manifest, path)) require(manifest.readAddress(path) == predicted, string.concat("recorded ", key, " != CREATE3 address"));
    }
}
