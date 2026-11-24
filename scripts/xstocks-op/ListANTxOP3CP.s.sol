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
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { EtherFiDeployerHelper } from "../utils/EtherFiDeployerHelper.sol";
import { XStocksOPProd as C } from "./XStocksOPProdConfig.sol";

/**
 * @title ListANTxOP3CP
 * @notice Lists Backed's Anthropic xStock (raw ANTx, wrapper wANTx) as a trade-only stock on Optimism, the same
 *         rows XStocksPhase2OP3CP set for the 91 Phase 2 stocks. No price, collateral or lend listing.
 *
 *           admin-safe-schedule   Admin Safe, 8h admin timelock: StockWrapModule.setWrapPairs,
 *                                 StockBridgeWithdrawModule.configureWrappers, TopUpDest.setStockWrappers
 *           admin-safe-execute    Admin Safe, >= 8h later
 *           controller-safe-withdraw  Operating Safe (AAC4), direct: CashModule.configureWithdrawAssets(wANTx)
 *
 * Usage (no broadcast; writes ./output/*.json and simulates every bundle on the fork):
 *   forge script scripts/xstocks-op/ListANTxOP3CP.s.sol --rpc-url $OPTIMISM_RPC --sender 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E --no-isolate -vvv
 */
contract ListANTxOP3CP is EtherFiDeployerHelper, GnosisHelpers, Test {
    using stdJson for string;

    address constant ANTX = 0x909369940f22dC1c143aC78753A33f41597138B1;
    address constant WANTX = 0xabec6AeAb037b77c09a2a99264F9C81a35B02649;

    bytes32 constant TL_PREDECESSOR = bytes32(0);
    bytes32 constant SALT = keccak256("XStocksOP.list.ANTx");

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
        _buildBatch();
        _checkPreconditions();

        string memory schedule = _writeBundle("admin-safe-schedule", string.concat(_header(C.ADMIN_SAFE), _tx(address(tl), abi.encodeWithSignature("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)", targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, SALT, C.ADMIN_DELAY), true)));
        string memory execute = _writeBundle("admin-safe-execute", string.concat(_header(C.ADMIN_SAFE), _tx(address(tl), abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, SALT), true)));
        string memory withdraw = _writeBundle("controller-safe-withdraw", string.concat(_header(C.SAFE), _tx(address(cashModule), abi.encodeCall(ICashModule.configureWithdrawAssets, (wrappers, C.flags(wrappers.length, true))), true)));

        console.log("=== Schedule the batch, withdraw asset direct ===");
        executeGnosisTransactionBundle(schedule);
        require(tl.getOperationState(_id()) == TimelockController.OperationState.Waiting, "batch not scheduled");
        executeGnosisTransactionBundle(withdraw);

        console.log("=== Warp 8h, execute ===");
        vm.warp(block.timestamp + C.ADMIN_DELAY + 1);
        executeGnosisTransactionBundle(execute);
        require(tl.getOperationState(_id()) == TimelockController.OperationState.Done, "batch not executed");

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
        raws.push(ANTX);
        wrappers.push(WANTX);
    }

    function _checkPreconditions() internal view {
        require(roleRegistry.hasRole(keccak256("ADMIN_TIMELOCK_ROLE"), C.ADMIN_TIMELOCK), "admin timelock lacks ADMIN_TIMELOCK_ROLE");
        require(roleRegistry.hasRole(keccak256("ADMIN_ROLE"), C.SAFE), "Safe lacks ADMIN_ROLE");
        require(tl.getMinDelay() == C.ADMIN_DELAY, "timelock minDelay mismatch");
        require(tl.hasRole(tl.PROPOSER_ROLE(), C.ADMIN_SAFE), "Admin Safe is not a proposer");
        require(tl.hasRole(tl.EXECUTOR_ROLE(), C.ADMIN_SAFE) || tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "Admin Safe is not an executor");
        require(!tl.isOperation(_id()), "batch already scheduled");

        require(WANTX.code.length != 0 && ANTX.code.length != 0, "ANTx pair not deployed on Optimism");
        require(IERC4626(WANTX).asset() == ANTX, "wANTx asset is not ANTx");
        require(IBackedCCIPBridge(C.BACKED_BRIDGE).tokenIds(ANTX) != 0, "ANTx not on the Backed bridge");
        require(wrap.wrapPairFor(ANTX) == address(0) && topUpDest.stockWrapperFor(ANTX) == address(0) && !bridgeWithdraw.isWrapperSupported(WANTX), "ANTx pair already set");
        address[] memory withdrawable = cashModule.getWhitelistedWithdrawAssets();
        require(!_contains(withdrawable, WANTX) && !_contains(withdrawable, ANTX), "ANTx or wANTx already a withdraw asset");
    }

    function _buildBatch() internal {
        targets.push(address(wrap));
        payloads.push(abi.encodeCall(StockWrapModule.setWrapPairs, (raws, wrappers)));
        targets.push(address(bridgeWithdraw));
        payloads.push(abi.encodeCall(StockBridgeWithdrawModule.configureWrappers, (wrappers, C.flags(wrappers.length, true))));
        targets.push(address(topUpDest));
        payloads.push(abi.encodeCall(TopUpDest.setStockWrappers, (raws, wrappers)));
        console.log(string.concat("ANTx batch: salt ", vm.toString(SALT), " id ", vm.toString(_id())));
    }

    function _assertAfter() internal view {
        assertEq(wrap.wrapPairFor(ANTX), WANTX, "wrap pair");
        assertTrue(bridgeWithdraw.isWrapperSupported(WANTX), "bridge wrapper");
        assertEq(topUpDest.stockWrapperFor(ANTX), WANTX, "TopUpDest wrapper");
        address[] memory withdrawable = cashModule.getWhitelistedWithdrawAssets();
        assertTrue(_contains(withdrawable, WANTX), "wANTx not a withdraw asset");
        assertFalse(_contains(withdrawable, ANTX), "raw ANTx must not be a withdraw asset");
    }

    function _header(address safe) internal pure returns (string memory) {
        return _getGnosisHeader("10", addressToHex(safe));
    }

    function _tx(address to, bytes memory data, bool isLast) internal pure returns (string memory) {
        return _getGnosisTransaction(addressToHex(to), iToHex(data), "0", isLast);
    }

    function _writeBundle(string memory step, string memory txs) internal returns (string memory) {
        vm.createDir("./output", true);
        string memory path = string.concat("./output/ListANTxOP3CP-10-", step, ".json");
        vm.writeFile(path, txs);
        console.log("Wrote", path);
        return path;
    }

    function _id() internal view returns (bytes32) {
        return tl.hashOperationBatch(targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, SALT);
    }

    function _contains(address[] memory list, address item) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == item) return true;
        }
        return false;
    }
}
