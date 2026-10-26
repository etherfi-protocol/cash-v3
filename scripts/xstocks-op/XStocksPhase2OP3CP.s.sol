// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { stdJson } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { IBackedCCIPBridge } from "../../src/interfaces/IBackedCCIPBridge.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { StockWrapModule } from "../../src/modules/stock-wrap/StockWrapModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { StockBridgeWithdrawModule } from "../../src/stock-withdraw/StockBridgeWithdrawModule.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { StockRedirectWrappers } from "../top-up/StockRedirectWrappers.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { EtherFiDeployerHelper } from "../utils/EtherFiDeployerHelper.sol";
import { XStocksOPProd as C } from "./XStocksOPProdConfig.sol";

/**
 * @title XStocksPhase2OP3CP
 * @notice The Optimism side of moving the 91 trade-only xStocks: the rows the Phase 1 modules and TopUpDest
 *         need for each raw and wrapper pair, and the wrappers as withdraw assets. No price, collateral or
 *         lend listing: the 91 are trade-only.
 *
 *           admin-safe-step1-schedule    Admin Safe, 8h admin timelock: StockWrapModule.setWrapPairs,
 *                                        StockBridgeWithdrawModule.configureWrappers, TopUpDest.setStockWrappers
 *           admin-safe-step2-execute     Admin Safe, >= 8h later
 *           controller-safe-withdraw     Operating Safe (AAC4), direct: CashModule.configureWithdrawAssets
 *
 * Usage (no broadcast; writes ./output/*.json and simulates every step on the fork):
 *   forge script scripts/xstocks-op/XStocksPhase2OP3CP.s.sol --rpc-url $OPTIMISM_RPC --sender 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E --no-isolate -vvv
 */
contract XStocksPhase2OP3CP is EtherFiDeployerHelper, GnosisHelpers, Test {
    using stdJson for string;

    bytes32 constant TL_PREDECESSOR = bytes32(0);
    bytes32 constant SALT = keccak256("XStocksOP.phase2.modules");
    uint256 constant GAS_TARGET = 14_000_000;

    RoleRegistry roleRegistry;
    EtherFiTimelock tl;
    ICashModule cashModule;
    TopUpDest topUpDest;
    StockWrapModule wrap;
    StockBridgeWithdrawModule bridgeWithdraw;
    address[] raws;
    address[] wrappers;
    address[] targets;
    bytes[] payloads;

    function run() public {
        require(block.chainid == C.OP_CHAIN_ID, "Optimism only");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");
        _load();
        _checkPreconditions();
        _buildBatch();

        string memory schedule = _writeBundle("admin-safe-step1-schedule", string.concat(_header(C.ADMIN_SAFE), _tx(address(tl), abi.encodeWithSignature("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)", targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, SALT, C.ADMIN_DELAY), true)));
        string memory execute = _writeBundle("admin-safe-step2-execute", string.concat(_header(C.ADMIN_SAFE), _tx(address(tl), abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, SALT), true)));
        string memory withdraw = _writeBundle("controller-safe-withdraw", string.concat(_header(C.SAFE), _tx(address(cashModule), abi.encodeCall(ICashModule.configureWithdrawAssets, (wrappers, C.flags(wrappers.length, true))), true)));

        console.log("=== Step 1: schedule the modules batch, withdraw assets direct ===");
        _run(schedule);
        require(tl.getOperationState(_id()) == TimelockController.OperationState.Waiting, "batch not scheduled");
        _run(withdraw);

        console.log("=== Warp 8h, step 2: execute ===");
        vm.warp(block.timestamp + C.ADMIN_DELAY + 1);
        _run(execute);
        _assertAfter();
        console.log("Simulation OK");
    }

    function _load() internal {
        string memory d = readDeploymentFile();
        roleRegistry = RoleRegistry(d.readAddress(".addresses.RoleRegistry"));
        tl = EtherFiTimelock(payable(C.ADMIN_TIMELOCK));
        cashModule = ICashModule(d.readAddress(".addresses.CashModule"));
        topUpDest = TopUpDest(payable(d.readAddress(".addresses.TopUpDest")));
        wrap = StockWrapModule(d.readAddress(string.concat(".addresses.", C.KEY_WRAP)));
        bridgeWithdraw = StockBridgeWithdrawModule(d.readAddress(string.concat(".addresses.", C.KEY_BRIDGE_WITHDRAW)));
        (raws, wrappers) = StockRedirectWrappers.pairs();
    }

    function _checkPreconditions() internal view {
        require(roleRegistry.hasRole(keccak256("ADMIN_TIMELOCK_ROLE"), C.ADMIN_TIMELOCK), "admin timelock lacks ADMIN_TIMELOCK_ROLE");
        require(roleRegistry.hasRole(keccak256("ADMIN_ROLE"), C.SAFE), "Safe lacks ADMIN_ROLE");
        require(tl.getMinDelay() == C.ADMIN_DELAY, "timelock minDelay mismatch");
        require(tl.hasRole(tl.PROPOSER_ROLE(), C.ADMIN_SAFE), "Admin Safe is not a proposer");
        require(tl.hasRole(tl.EXECUTOR_ROLE(), C.ADMIN_SAFE) || tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "Admin Safe is not an executor");
        // Phase 1 left the modules wired in: default modules, the bridge module on the can-request list
        require(wrap.wrapPairFor(C.raws()[0]) == C.wrappers()[0] && topUpDest.stockWrapperFor(C.raws()[0]) == C.wrappers()[0], "Phase 1 rows missing: run after 3CP-730");
        address[] memory withdrawable = cashModule.getWhitelistedWithdrawAssets();
        for (uint256 i; i < raws.length; ++i) {
            string memory n = vm.toString(i);
            require(wrappers[i].code.length != 0 && raws[i].code.length != 0, string.concat("pair not deployed on Optimism: ", n));
            require(IERC4626(wrappers[i]).asset() == raws[i], string.concat("wrapper asset mismatch: ", n));
            require(IBackedCCIPBridge(C.BACKED_BRIDGE).tokenIds(raws[i]) != 0, string.concat("raw not on the bridge: ", n));
            require(wrap.wrapPairFor(raws[i]) == address(0) && topUpDest.stockWrapperFor(raws[i]) == address(0) && !bridgeWithdraw.isWrapperSupported(wrappers[i]), string.concat("pair already set: ", n));
            require(!_contains(withdrawable, wrappers[i]) && !_contains(withdrawable, raws[i]), string.concat("already a withdraw asset: ", n));
        }
    }

    function _buildBatch() internal {
        targets.push(address(wrap));
        payloads.push(abi.encodeCall(StockWrapModule.setWrapPairs, (raws, wrappers)));
        targets.push(address(bridgeWithdraw));
        payloads.push(abi.encodeCall(StockBridgeWithdrawModule.configureWrappers, (wrappers, C.flags(wrappers.length, true))));
        targets.push(address(topUpDest));
        payloads.push(abi.encodeCall(TopUpDest.setStockWrappers, (raws, wrappers)));
        require(!tl.isOperation(_id()), "batch already scheduled");
        console.log(string.concat("modules batch: salt ", vm.toString(SALT), " id ", vm.toString(_id())));
    }

    function _assertAfter() internal view {
        address[] memory withdrawable = cashModule.getWhitelistedWithdrawAssets();
        for (uint256 i; i < raws.length; ++i) {
            string memory n = vm.toString(i);
            assertEq(wrap.wrapPairFor(raws[i]), wrappers[i], string.concat("wrap pair: ", n));
            assertTrue(bridgeWithdraw.isWrapperSupported(wrappers[i]), string.concat("bridge wrapper: ", n));
            assertEq(topUpDest.stockWrapperFor(raws[i]), wrappers[i], string.concat("TopUpDest wrapper: ", n));
            assertTrue(_contains(withdrawable, wrappers[i]), string.concat("wrapper not a withdraw asset: ", n));
            assertFalse(_contains(withdrawable, raws[i]), string.concat("raw must not be a withdraw asset: ", n));
        }
    }

    // ── Bundle encoding and the measured run ───────────────────────────────────────

    function _header(address safe) internal pure returns (string memory) {
        return _getGnosisHeader("10", addressToHex(safe));
    }

    function _tx(address to, bytes memory data, bool isLast) internal pure returns (string memory) {
        return _getGnosisTransaction(addressToHex(to), iToHex(data), "0", isLast);
    }

    function _writeBundle(string memory step, string memory txs) internal returns (string memory) {
        vm.createDir("./output", true);
        string memory path = string.concat("./output/XStocksPhase2OP3CP-10-", step, ".json");
        vm.writeFile(path, txs);
        console.log("Wrote", path);
        return path;
    }

    function _id() internal view returns (bytes32) {
        return tl.hashOperationBatch(targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, SALT);
    }

    /// @dev Sends each transaction of a bundle as the Safe and logs its gas; a bundle whose total passes the target
    ///      would not fit a block once the Safe's own overhead is added
    function _run(string memory path) internal {
        string memory json = vm.readFile(path);
        address safe = vm.parseJsonAddress(json, ".safeAddress");
        uint256 total;
        for (uint256 i; vm.keyExistsJson(json, string.concat(".transactions[", vm.toString(i), "]")); ++i) {
            address to = vm.parseJsonAddress(json, string.concat(".transactions[", vm.toString(i), "].to"));
            bytes memory data = vm.parseJsonBytes(json, string.concat(".transactions[", vm.toString(i), "].data"));
            uint256 before = gasleft();
            vm.prank(safe);
            (bool ok, bytes memory ret) = to.call(data);
            total += before - gasleft();
            if (!ok) {
                console.logBytes(ret);
                revert(string.concat("transaction failed: ", path));
            }
        }
        console.log("  gas", total, path);
        require(total <= GAS_TARGET, string.concat("bundle over the gas target: ", path));
    }

    function _contains(address[] memory list, address item) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == item) return true;
        }
        return false;
    }
}
