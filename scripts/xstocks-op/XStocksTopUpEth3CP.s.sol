// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { stdJson } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { XStocksOPDeployer } from "./XStocksOPDeployer.sol";
import { XStock, XStocksOPProd as C } from "./XStocksOPProdConfig.sol";

/**
 * @title XStocksTopUpEth3CP
 * @notice Two Operating Safe bundles on Ethereum that route raw SPYx, QQQx and TBLLx top-ups to Optimism over
 *         Backed's CCIP bridge: step 1 schedules TopUpFactory.setTokenConfig for the three stocks on the 8h
 *         timelock, step 2 executes it. The recipient on Optimism is TopUpDest, which wraps what arrives.
 * @dev Replaces the LayerZero OFT route for the three stocks; the old config stays until the refill loop has
 *      drained the mirrors. The simulation schedules, warps, executes and then bridges one SPYx through the
 *      live factory to prove the adapter quotes and sends.
 *
 * Prerequisites: DeployBackedCCIPAdapterEth has run. Before it has, the generator rehearsal-deploys the adapter
 * at its CREATE3 address on the fork.
 *
 * Usage (no broadcast; writes ./output/*.json and simulates both steps on the fork):
 *   forge script scripts/xstocks-op/XStocksTopUpEth3CP.s.sol --rpc-url $MAINNET_RPC --sender 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E --no-isolate -vvv
 */
contract XStocksTopUpEth3CP is XStocksOPDeployer, GnosisHelpers, Test {
    using stdJson for string;

    bytes32 constant TL_PREDECESSOR = bytes32(0);
    bytes32 constant SALT = keccak256("XStocksOP.topUpConfig");
    uint256 constant SHARES_ROUNDING_DUST = 2;

    RoleRegistry roleRegistry;
    TopUpFactory factory;
    address adapter;
    address topUpDest;
    address[] targets;
    bytes[] payloads;

    function run() public {
        require(block.chainid == 1, "Ethereum only");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");
        _load();
        _checkPreconditions();

        targets.push(address(factory));
        payloads.push(abi.encodeCall(TopUpFactory.setTokenConfig, (C.raws(), _chainIds(), _configs())));
        require(!_isOperation(), "batch already scheduled");

        string memory step1 = _writeBundle("step1-schedule", string.concat(_header(), _tx(C.ADMIN_TIMELOCK, abi.encodeWithSignature("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)", targets, new uint256[](1), payloads, TL_PREDECESSOR, SALT, C.ADMIN_DELAY), true)));
        string memory step2 = _writeBundle("step2-execute", string.concat(_header(), _tx(C.ADMIN_TIMELOCK, abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", targets, new uint256[](1), payloads, TL_PREDECESSOR, SALT), true)));

        console.log("=== Step 1: schedule ===");
        executeGnosisTransactionBundle(step1);
        require(_isOperation(), "batch not scheduled");
        console.log("=== Warp 8h, step 2: execute ===");
        vm.warp(block.timestamp + C.ADMIN_DELAY + 1);
        executeGnosisTransactionBundle(step2);
        _assertConfigs();
        _simulateBridge(C.stocks()[0]);
        console.log("Simulation OK");
    }

    function _load() internal {
        string memory d = readDeploymentFile();
        roleRegistry = RoleRegistry(d.readAddress(".addresses.RoleRegistry"));
        factory = TopUpFactory(payable(d.readAddress(".addresses.TopUpSourceFactory")));
        adapter = _deployAdapter(true);
        _checkRecorded(d, C.KEY_CCIP_ADAPTER, adapter);
        topUpDest = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(C.OP_CHAIN_ID), "/deployments.json")).readAddress(".addresses.TopUpDest");
    }

    function _checkPreconditions() internal view {
        require(roleRegistry.hasRole(keccak256("ADMIN_TIMELOCK_ROLE"), C.ADMIN_TIMELOCK), "admin timelock lacks ADMIN_TIMELOCK_ROLE");
        EtherFiTimelock tl = EtherFiTimelock(payable(C.ADMIN_TIMELOCK));
        require(tl.getMinDelay() == C.ADMIN_DELAY, "timelock minDelay mismatch");
        require(tl.hasRole(tl.PROPOSER_ROLE(), C.SAFE), "Safe is not a proposer");
        require(tl.hasRole(tl.EXECUTOR_ROLE(), C.SAFE) || tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "Safe is not an executor");
        require(topUpDest != address(0), "TopUpDest on Optimism not found");
        XStock[] memory stocks = C.stocks();
        for (uint256 i; i < stocks.length; ++i) {
            TopUpFactory.TokenConfig memory existing = factory.getTokenConfig(stocks[i].raw, C.OP_CHAIN_ID);
            require(existing.bridgeAdapter != adapter, string.concat(stocks[i].symbol, ": already routed over the CCIP adapter"));
            if (existing.bridgeAdapter != address(0)) console.log(string.concat("NOTE: ", stocks[i].symbol, " config is overwritten, adapter was:"), existing.bridgeAdapter);
        }
    }

    function _chainIds() internal pure returns (uint256[] memory) {
        uint256[] memory ids = new uint256[](3);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = C.OP_CHAIN_ID;
        }
        return ids;
    }

    /// @dev One raw stock arrives as the same raw stock, so there is no slippage to bound
    function _configs() internal view returns (TopUpFactory.TokenConfig[] memory) {
        TopUpFactory.TokenConfig[] memory configs = new TopUpFactory.TokenConfig[](3);
        for (uint256 i; i < configs.length; ++i) {
            configs[i] = TopUpFactory.TokenConfig({ bridgeAdapter: adapter, recipientOnDestChain: topUpDest, maxSlippageInBps: 0, additionalData: abi.encode(C.BACKED_BRIDGE, C.OPTIMISM_SELECTOR) });
        }
        return configs;
    }

    function _assertConfigs() internal view {
        XStock[] memory stocks = C.stocks();
        TopUpFactory.TokenConfig[] memory want = _configs();
        for (uint256 i; i < stocks.length; ++i) {
            TopUpFactory.TokenConfig memory got = factory.getTokenConfig(stocks[i].raw, C.OP_CHAIN_ID);
            assertEq(got.bridgeAdapter, want[i].bridgeAdapter, string.concat(stocks[i].symbol, ": adapter"));
            assertEq(got.recipientOnDestChain, want[i].recipientOnDestChain, string.concat(stocks[i].symbol, ": recipient"));
            assertEq(uint256(got.maxSlippageInBps), 0, string.concat(stocks[i].symbol, ": slippage"));
            assertEq(got.additionalData, want[i].additionalData, string.concat(stocks[i].symbol, ": additional data"));
        }
    }

    /// @dev Funds the factory with one raw stock from the wrapper vault (the raw token is shares-based, so `deal`
    ///      cannot find its balance slot) and bridges it through the live factory
    function _simulateBridge(XStock memory s) internal {
        uint256 amount = 1e18;
        require(IERC20(s.raw).balanceOf(s.wrapper) >= amount, string.concat(s.symbol, ": wrapper vault holds too little to simulate"));
        uint256 before = IERC20(s.raw).balanceOf(address(factory));
        vm.prank(s.wrapper);
        IERC20(s.raw).transfer(address(factory), amount);
        uint256 bridgeAmount = IERC20(s.raw).balanceOf(address(factory)) - before;

        address bridger = makeAddr("xstocksBridger");
        address registryOwner = roleRegistry.owner();
        bytes32 bridgerRole = factory.TOPUP_FACTORY_BRIDGER_ROLE();
        vm.prank(registryOwner);
        roleRegistry.grantRole(bridgerRole, bridger);

        (, uint256 fee) = factory.getBridgeFee(s.raw, bridgeAmount, C.OP_CHAIN_ID);
        vm.deal(bridger, fee);
        vm.prank(bridger);
        factory.bridge{ value: fee }(s.raw, bridgeAmount, C.OP_CHAIN_ID);

        assertApproxEqAbs(IERC20(s.raw).balanceOf(address(factory)), before, SHARES_ROUNDING_DUST, string.concat(s.symbol, ": not consumed by the bridge"));
        console.log(string.concat("Simulated bridge of 1 ", s.symbol, " to Optimism, native fee (wei):"), fee);
    }

    function _header() internal pure returns (string memory) {
        return _getGnosisHeader("1", addressToHex(C.SAFE));
    }

    function _tx(address to, bytes memory data, bool isLast) internal pure returns (string memory) {
        return _getGnosisTransaction(addressToHex(to), iToHex(data), "0", isLast);
    }

    function _writeBundle(string memory step, string memory txs) internal returns (string memory) {
        vm.createDir("./output", true);
        string memory path = string.concat("./output/XStocksTopUpEth3CP-1-", step, ".json");
        vm.writeFile(path, txs);
        console.log("Wrote", path);
        return path;
    }

    function _isOperation() internal view returns (bool) {
        EtherFiTimelock tl = EtherFiTimelock(payable(C.ADMIN_TIMELOCK));
        return tl.isOperation(tl.hashOperationBatch(targets, new uint256[](1), payloads, TL_PREDECESSOR, SALT));
    }
}
