// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { IOperatingTimelock, IPausable, IPausableBridge, ITopUpFactoryLike, MigratedStock, StockMigration } from "./StockMigrationConfig.sol";

/**
 * @notice Operating Safe bundles that stop every rail the three stocks ride before the migration weekend,
 *         and the matching unpause bundles for the rails that stay alive afterwards. PAUSER and UNPAUSER on
 *         both RoleRegistries are the Operating Safe, so one Safe per chain does all of it.
 *
 *         Ethereum: pause the three OFT adapters, remove the three wrappers' top-up configs (so a top-up
 *         cannot route new stock into a lockbox that is about to be emptied), pause the StockUnwrapper. The
 *         top-up removal is gated behind the 8h operating timelock, so it is scheduled at least 8h ahead in
 *         its own bundle and executed from inside the weekend pause bundle.
 *         Optimism: pause the three mirror tokens, the StockWithdrawModule, and both asset recovery modules.
 *
 *         Deliberately not paused: TopUpDest, which credits every asset's top-ups on OP, and the PAXG
 *         adapter, which stays on the OFT rail. The adapters and mirrors are never unpaused again.
 *
 *         Wait for in-flight LayerZero messages to settle before executing: a paused adapter or mirror
 *         holds an inbound message as retryable, and a paused StockUnwrapper holds a compose.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/stock-migration/PauseStockRails3CP.s.sol:PauseStockRailsEthereum3CP --rpc-url $MAINNET_RPC -vv
 *   ENV=mainnet forge script scripts/stock-migration/PauseStockRails3CP.s.sol:PauseStockRailsOptimism3CP --rpc-url $OPTIMISM_RPC -vv
 *   ENV=mainnet forge script scripts/stock-migration/PauseStockRails3CP.s.sol:UnpauseStockRailsOptimism3CP --rpc-url $OPTIMISM_RPC -vv
 *   ENV=mainnet forge script scripts/stock-migration/PauseStockRails3CP.s.sol:UnpauseStockRailsEthereum3CP --rpc-url $MAINNET_RPC -vv
 */
abstract contract StockRailsBundleBase is GnosisHelpers, Test, Utils {
    address constant PAXG = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;
    uint256 constant OP_CHAIN_ID = 10;

    function _requireChain(uint256 chainId) internal view {
        require(block.chainid == chainId, "wrong chain for this bundle");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");
    }

    function _append(string memory txs, address to, bytes memory data, bool isLast) internal pure returns (string memory) {
        return string.concat(txs, _getGnosisTransaction(addressToHex(to), iToHex(data), "0", isLast));
    }

    function _write(string memory path, string memory txs) internal {
        vm.createDir("./output", true);
        vm.writeFile(path, txs);
        console.log("Written: %s", path);
    }

    function _header() internal view returns (string memory) {
        return _getGnosisHeader(vm.toString(block.chainid), addressToHex(StockMigration.OPERATING_SAFE));
    }
}

contract PauseStockRailsEthereum3CP is StockRailsBundleBase {
    string constant SCHEDULE = "./output/PauseStockRailsEthereum3CP-schedule-1.json";
    string constant OUTPUT = "./output/PauseStockRailsEthereum3CP-1.json";

    function run() public {
        _requireChain(1);
        string memory deployments = readDeploymentFile();
        ITopUpFactoryLike factory = ITopUpFactoryLike(stdJson.readAddress(deployments, ".addresses.TopUpSourceFactory"));
        IPausable unwrapper = IPausable(stdJson.readAddress(deployments, ".addresses.StockUnwrapper"));
        MigratedStock[] memory stocks = StockMigration.all();

        address[] memory wrappers = new address[](stocks.length);
        uint256[] memory chainIds = new uint256[](stocks.length);
        for (uint256 i = 0; i < stocks.length; ++i) {
            MigratedStock memory s = stocks[i];
            require(IPausableBridge(s.adapter).owner() == StockMigration.OPERATING_SAFE, string.concat(s.symbol, ": adapter owner is not the Operating Safe"));
            require(!IPausableBridge(s.adapter).paused(), string.concat(s.symbol, ": adapter already paused"));
            require(factory.getTokenConfig(s.wrapper, OP_CHAIN_ID).bridgeAdapter != address(0), string.concat(s.symbol, ": no top-up config to remove"));
            wrappers[i] = s.wrapper;
            chainIds[i] = OP_CHAIN_ID;
        }
        require(!unwrapper.paused(), "StockUnwrapper already paused");
        address paxgAdapter = factory.getTokenConfig(PAXG, OP_CHAIN_ID).bridgeAdapter;

        bytes memory removeCall = abi.encodeCall(ITopUpFactoryLike.removeTokenConfig, (wrappers, chainIds));
        bytes memory executeCall = _scheduleTopUpRemoval(address(factory), removeCall);

        string memory txs = _header();
        for (uint256 i = 0; i < stocks.length; ++i) {
            txs = _append(txs, stocks[i].adapter, abi.encodeCall(IPausableBridge.pauseBridge, ()), false);
        }
        txs = _append(txs, StockMigration.OPERATING_TIMELOCK, executeCall, false);
        txs = _append(txs, address(unwrapper), abi.encodeCall(IPausable.pause, ()), true);
        _write(OUTPUT, txs);

        executeGnosisTransactionBundle(OUTPUT);
        for (uint256 i = 0; i < stocks.length; ++i) {
            assertTrue(IPausableBridge(stocks[i].adapter).paused(), "adapter not paused");
            assertEq(factory.getTokenConfig(stocks[i].wrapper, OP_CHAIN_ID).bridgeAdapter, address(0), "top-up config still set");
        }
        assertTrue(unwrapper.paused(), "unwrapper not paused");
        assertEq(factory.getTokenConfig(PAXG, OP_CHAIN_ID).bridgeAdapter, paxgAdapter, "PAXG top-up config changed");
        console.log("Simulation passed: 3 adapters paused, 3 top-up configs removed, StockUnwrapper paused. PAXG untouched.");
    }

    /// @dev Writes and rehearses the Safe's schedule bundle when the removal is not queued live yet, warps the
    ///      fork past the delay, and returns the timelock execute call for the weekend bundle.
    function _scheduleTopUpRemoval(address factory, bytes memory removeCall) internal returns (bytes memory) {
        IOperatingTimelock timelock = IOperatingTimelock(StockMigration.OPERATING_TIMELOCK);
        bytes32 id = timelock.hashOperation(factory, 0, removeCall, bytes32(0), StockMigration.TOP_UP_SALT);
        require(!timelock.isOperationDone(id), "top-up removal already executed on the timelock");
        if (!timelock.isOperation(id)) {
            _write(SCHEDULE, _append(_header(), address(timelock), abi.encodeCall(IOperatingTimelock.schedule, (factory, 0, removeCall, bytes32(0), StockMigration.TOP_UP_SALT, timelock.getMinDelay())), true));
            executeGnosisTransactionBundle(SCHEDULE);
        } else {
            console.log("Top-up removal already scheduled live; writing the weekend bundle only");
        }
        console.log("  top-up removal operation id:");
        console.logBytes32(id);
        console.log("  executable from (unix):", timelock.getTimestamp(id));
        if (block.timestamp < timelock.getTimestamp(id)) vm.warp(timelock.getTimestamp(id));
        return abi.encodeCall(IOperatingTimelock.execute, (factory, 0, removeCall, bytes32(0), StockMigration.TOP_UP_SALT));
    }
}

contract PauseStockRailsOptimism3CP is StockRailsBundleBase {
    string constant OUTPUT = "./output/PauseStockRailsOptimism3CP-10.json";

    function run() public {
        _requireChain(10);
        (IPausable withdrawModule, IPausable safeRecovery, IPausable recovery) = _opContracts();
        MigratedStock[] memory stocks = StockMigration.all();

        for (uint256 i = 0; i < stocks.length; ++i) {
            require(!IPausableBridge(stocks[i].iToken).paused(), string.concat(stocks[i].symbol, ": mirror already paused"));
        }
        require(!withdrawModule.paused() && !safeRecovery.paused() && !recovery.paused(), "a module is already paused");

        string memory txs = _header();
        for (uint256 i = 0; i < stocks.length; ++i) {
            txs = _append(txs, stocks[i].iToken, abi.encodeCall(IPausableBridge.pauseBridge, ()), false);
        }
        txs = _append(txs, address(withdrawModule), abi.encodeCall(IPausable.pause, ()), false);
        txs = _append(txs, address(safeRecovery), abi.encodeCall(IPausable.pause, ()), false);
        txs = _append(txs, address(recovery), abi.encodeCall(IPausable.pause, ()), true);
        _write(OUTPUT, txs);

        executeGnosisTransactionBundle(OUTPUT);
        for (uint256 i = 0; i < stocks.length; ++i) {
            assertTrue(IPausableBridge(stocks[i].iToken).paused(), "mirror not paused");
        }
        assertTrue(withdrawModule.paused() && safeRecovery.paused() && recovery.paused(), "a module is not paused");
        console.log("Simulation passed: 3 mirrors, StockWithdrawModule and both recovery modules paused.");
    }

    function _opContracts() internal view returns (IPausable, IPausable, IPausable) {
        string memory deployments = readDeploymentFile();
        return (IPausable(stdJson.readAddress(deployments, ".addresses.StockWithdrawModule")), IPausable(stdJson.readAddress(deployments, ".addresses.SafeAssetRecoveryModule")), IPausable(stdJson.readAddress(deployments, ".addresses.AssetRecoveryModule")));
    }
}

/// @notice After cutover: the recovery modules come back. The mirrors and the StockWithdrawModule stay paused for
///         good: the module only withdraws mirrors over the retired OFT rail, so an order placed on it could never
///         settle and would hold the safe's withdrawal slot.
contract UnpauseStockRailsOptimism3CP is StockRailsBundleBase {
    string constant OUTPUT = "./output/UnpauseStockRailsOptimism3CP-10.json";

    function run() public {
        _requireChain(10);
        string memory deployments = readDeploymentFile();
        IPausable withdrawModule = IPausable(stdJson.readAddress(deployments, ".addresses.StockWithdrawModule"));
        IPausable safeRecovery = IPausable(stdJson.readAddress(deployments, ".addresses.SafeAssetRecoveryModule"));
        IPausable recovery = IPausable(stdJson.readAddress(deployments, ".addresses.AssetRecoveryModule"));
        require(safeRecovery.paused() && recovery.paused(), "a recovery module is not paused; nothing to unpause");

        string memory txs = _header();
        txs = _append(txs, address(safeRecovery), abi.encodeCall(IPausable.unpause, ()), false);
        txs = _append(txs, address(recovery), abi.encodeCall(IPausable.unpause, ()), true);
        _write(OUTPUT, txs);

        executeGnosisTransactionBundle(OUTPUT);
        assertFalse(safeRecovery.paused() || recovery.paused(), "a recovery module is still paused");
        assertTrue(withdrawModule.paused(), "StockWithdrawModule must stay paused");
        MigratedStock[] memory stocks = StockMigration.all();
        for (uint256 i = 0; i < stocks.length; ++i) {
            assertTrue(IPausableBridge(stocks[i].iToken).paused(), "mirror must stay paused");
        }
        console.log("Simulation passed: recovery modules unpaused; mirrors and StockWithdrawModule still paused.");
    }
}

/// @notice After cutover: the adapters stay paused for good; the StockUnwrapper comes back.
contract UnpauseStockRailsEthereum3CP is StockRailsBundleBase {
    string constant OUTPUT = "./output/UnpauseStockRailsEthereum3CP-1.json";

    function run() public {
        _requireChain(1);
        IPausable unwrapper = IPausable(stdJson.readAddress(readDeploymentFile(), ".addresses.StockUnwrapper"));
        require(unwrapper.paused(), "StockUnwrapper is not paused; nothing to unpause");

        string memory txs = _header();
        txs = _append(txs, address(unwrapper), abi.encodeCall(IPausable.unpause, ()), true);
        _write(OUTPUT, txs);

        executeGnosisTransactionBundle(OUTPUT);
        assertFalse(unwrapper.paused(), "unwrapper still paused");
        MigratedStock[] memory stocks = StockMigration.all();
        for (uint256 i = 0; i < stocks.length; ++i) {
            assertTrue(IPausableBridge(stocks[i].adapter).paused(), "adapter must stay paused");
        }
        console.log("Simulation passed: StockUnwrapper unpaused, adapters still paused.");
    }
}
