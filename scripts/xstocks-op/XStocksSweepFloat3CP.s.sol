// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { stdJson } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { StockMigrationModule } from "../../src/migration/StockMigrationModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { XStock, XStocksOPProd as C } from "./XStocksOPProdConfig.sol";

/**
 * @title XStocksSweepFloat3CP
 * @notice Two Admin Safe bundles (schedule, then execute through the 8h admin timelock) that send to the treasury:
 *           - every stand-in the migration module has collected: sweep(standIn, treasury, 0)
 *           - the wrapper float above what holders still need: sweep(wrapper, treasury, amount), for each nonzero amount
 *           - TopUpDest's stand-in deposits: withdraw(standIn, deposit) to the timelock, then transfer to the treasury
 *
 *         SWEEP_WRAPPER_AMOUNTS and KEEP_WRAPPER_AMOUNTS are wei lists in stock order (SPYx, QQQx, TBLLx). A zero
 *         sweep amount leaves that wrapper alone. KEEP is what holder safes still hold, loose plus supplied (the
 *         keeper's census); the run fails unless the float left after each wrapper sweep covers it.
 *
 * Usage (no broadcast; writes ./output/*.json and simulates on the fork):
 *   XSTOCKS_TREASURY=0x... SWEEP_SALT_LABEL=XStocksOP.sweepFloat.<date> \
 *   SWEEP_WRAPPER_AMOUNTS=0,40000000000000000000,172000000000000000000 KEEP_WRAPPER_AMOUNTS=<spy>,<qqq>,<tbll> \
 *     forge script scripts/xstocks-op/XStocksSweepFloat3CP.s.sol --rpc-url $OPTIMISM_RPC --no-isolate -vv
 */
contract XStocksSweepFloat3CP is Utils, GnosisHelpers, Test {
    using stdJson for string;

    EtherFiTimelock adminTimelock = EtherFiTimelock(payable(C.ADMIN_TIMELOCK));
    StockMigrationModule migration;
    TopUpDest topUpDest;
    address treasury;
    bytes32 sweepSalt;
    XStock[] stocks;
    uint256[] wrapperAmounts;
    uint256[] keep;
    uint256[] deposits;

    address[] targets;
    bytes[] payloads;

    function run() public {
        require(block.chainid == C.OP_CHAIN_ID, "Optimism only");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");
        _load();
        _checkPreconditions();

        string memory schedule = _writeBundle("admin-safe-schedule-float-sweep", abi.encodeWithSignature("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)", targets, new uint256[](targets.length), payloads, bytes32(0), sweepSalt, C.ADMIN_DELAY));
        string memory execute = _writeBundle("admin-safe-execute-float-sweep", abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", targets, new uint256[](targets.length), payloads, bytes32(0), sweepSalt));
        console.log("treasury", treasury);
        console.log("salt");
        console.logBytes32(sweepSalt);
        console.log("operation id");
        console.logBytes32(_opId());

        uint256 n = stocks.length;
        uint256[] memory collected = new uint256[](n);
        uint256[] memory floatBefore = new uint256[](n);
        uint256[] memory standInBefore = new uint256[](n);
        uint256[] memory wrapperBefore = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            collected[i] = IERC20(stocks[i].standIn).balanceOf(address(migration));
            floatBefore[i] = IERC20(stocks[i].wrapper).balanceOf(address(migration));
            standInBefore[i] = IERC20(stocks[i].standIn).balanceOf(treasury);
            wrapperBefore[i] = IERC20(stocks[i].wrapper).balanceOf(treasury);
        }

        executeGnosisTransactionBundle(schedule);
        require(adminTimelock.isOperationPending(_opId()), "sweep not scheduled");
        vm.warp(block.timestamp + C.ADMIN_DELAY);
        executeGnosisTransactionBundle(execute);
        require(adminTimelock.isOperationDone(_opId()), "sweep not done");

        for (uint256 i; i < n; ++i) {
            string memory s = stocks[i].symbol;
            assertEq(IERC20(stocks[i].standIn).balanceOf(address(migration)), 0, string.concat(s, ": stand-in left in module"));
            assertEq(IERC20(stocks[i].standIn).balanceOf(treasury), standInBefore[i] + collected[i] + deposits[i], string.concat(s, ": stand-in at treasury"));
            assertEq(IERC20(stocks[i].wrapper).balanceOf(address(migration)), floatBefore[i] - wrapperAmounts[i], string.concat(s, ": wrapper float"));
            assertEq(IERC20(stocks[i].wrapper).balanceOf(treasury), wrapperBefore[i] + wrapperAmounts[i], string.concat(s, ": wrapper at treasury"));
            assertEq(topUpDest.getDeposit(stocks[i].standIn), 0, string.concat(s, ": TopUpDest deposit left"));
            assertEq(IERC20(stocks[i].standIn).balanceOf(C.ADMIN_TIMELOCK), 0, string.concat(s, ": stand-in left in timelock"));
            console.log(s, "stand-in to treasury", collected[i] + deposits[i]);
            console.log(s, "wrapper to treasury", wrapperAmounts[i]);
            console.log(s, "float left", floatBefore[i] - wrapperAmounts[i]);
        }
        console.log("Simulation OK");
    }

    function _load() internal {
        string memory d = readDeploymentFile();
        migration = StockMigrationModule(d.readAddress(string.concat(".addresses.", C.KEY_MIGRATION)));
        topUpDest = TopUpDest(payable(d.readAddress(".addresses.TopUpDest")));
        treasury = vm.envAddress("XSTOCKS_TREASURY");
        require(treasury != address(0) && treasury != address(migration), "XSTOCKS_TREASURY: zero or the module itself");
        sweepSalt = keccak256(bytes(vm.envString("SWEEP_SALT_LABEL")));
        wrapperAmounts = vm.envUint("SWEEP_WRAPPER_AMOUNTS", ",");
        keep = vm.envUint("KEEP_WRAPPER_AMOUNTS", ",");

        XStock[] memory list = C.stocks();
        require(wrapperAmounts.length == list.length && keep.length == list.length, "one amount per stock");
        for (uint256 i; i < list.length; ++i) {
            stocks.push(list[i]);
            _call(address(migration), abi.encodeCall(StockMigrationModule.sweep, (list[i].standIn, treasury, 0)));
            if (wrapperAmounts[i] != 0) _call(address(migration), abi.encodeCall(StockMigrationModule.sweep, (list[i].wrapper, treasury, wrapperAmounts[i])));
        }
        for (uint256 i; i < list.length; ++i) {
            deposits.push(topUpDest.getDeposit(list[i].standIn));
            if (deposits[i] == 0) continue;
            _call(address(topUpDest), abi.encodeCall(TopUpDest.withdraw, (list[i].standIn, deposits[i])));
            _call(list[i].standIn, abi.encodeCall(IERC20.transfer, (treasury, deposits[i])));
        }
    }

    function _checkPreconditions() internal view {
        RoleRegistry roleRegistry = RoleRegistry(readDeploymentFile().readAddress(".addresses.RoleRegistry"));
        require(roleRegistry.hasRole(keccak256("ADMIN_TIMELOCK_ROLE"), C.ADMIN_TIMELOCK), "admin timelock lacks ADMIN_TIMELOCK_ROLE");
        require(adminTimelock.hasRole(adminTimelock.PROPOSER_ROLE(), C.ADMIN_SAFE), "Admin Safe is not a proposer on the admin timelock");
        require(adminTimelock.hasRole(adminTimelock.EXECUTOR_ROLE(), C.ADMIN_SAFE), "Admin Safe is not an executor on the admin timelock");
        require(adminTimelock.getMinDelay() == C.ADMIN_DELAY, "admin timelock delay moved");
        require(!adminTimelock.isOperation(_opId()), "sweep with this salt already scheduled");
        for (uint256 i; i < stocks.length; ++i) {
            require(migration.swapPairFor(stocks[i].standIn) == stocks[i].wrapper, string.concat(stocks[i].symbol, ": swap pair moved"));
            if (wrapperAmounts[i] == 0) continue;
            uint256 float = IERC20(stocks[i].wrapper).balanceOf(address(migration));
            require(float >= wrapperAmounts[i] && float - wrapperAmounts[i] >= keep[i], string.concat(stocks[i].symbol, ": float left would not cover holders"));
        }
    }

    function _call(address target, bytes memory data) internal {
        targets.push(target);
        payloads.push(data);
    }

    function _writeBundle(string memory step, bytes memory data) internal returns (string memory) {
        vm.createDir("./output", true);
        string memory path = string.concat("./output/XStocksSweepFloat3CP-10-", step, ".json");
        vm.writeFile(path, string.concat(_getGnosisHeader("10", addressToHex(C.ADMIN_SAFE)), _getGnosisTransaction(addressToHex(C.ADMIN_TIMELOCK), iToHex(data), "0", true)));
        console.log("Wrote", path);
        return path;
    }

    function _opId() internal view returns (bytes32) {
        return adminTimelock.hashOperationBatch(targets, new uint256[](targets.length), payloads, bytes32(0), sweepSalt);
    }
}
