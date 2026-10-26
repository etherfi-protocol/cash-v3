// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { stdJson } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { IBackedCCIPBridge } from "../../src/interfaces/IBackedCCIPBridge.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { TradingLens } from "../../src/trading-safe/TradingLens.sol";
import { StockRedirectWrappers } from "../top-up/StockRedirectWrappers.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { XStocksOPDeployer } from "./XStocksOPDeployer.sol";
import { XStocksOPProd as C } from "./XStocksOPProdConfig.sol";

/**
 * @title XStocksPhase2Eth3CP
 * @notice The Ethereum side of moving the 91 trade-only xStocks to Optimism, as Operating Safe (AAC4) bundles:
 *
 *           Bundle 1, raw routes:
 *             b1-step1-schedule   cancel the stale Phase 1 top-up operation (SPYx, QQQx, TBLLx keep their
 *                                 current routes), then schedule two 8h batches that route the 91 raw stocks
 *                                 to TopUpDest on Optimism over the Backed CCIP adapter
 *             b1-step2-execute-N  execute each batch (>= 8h later; closes the redirect-to-TradingSafe path,
 *                                 so on the move day)
 *           Bundle 2, wrapper routes and the lens:
 *             b2-step1-schedule   schedule two 8h batches that route the 91 wrappers over the unwrapping
 *                                 adapter, which redeems to raw and sends that over the bridge
 *             b2-step2-execute-N  execute each batch (>= 8h later, after the adapter is deployed)
 *             b2-lens-remove      remove the 91 wrappers from the Ethereum TradingLens (ADMIN_ROLE, direct)
 *
 *         91 routes cost about 21M gas, past the 16.7M transaction cap, so each list goes out as two batches
 *         of 46 and 45. The simulation measures every execute and fails above the gas target.
 *
 * Prerequisites: the Backed CCIP adapter is deployed (Phase 1). The wrapper adapter is rehearsal-deployed at
 * its CREATE3 address when not live yet; its execute must not run before DeployBackedCCIPWrapperAdapterEth.
 *
 * Usage (no broadcast; writes ./output/*.json and simulates every step on the fork):
 *   forge script scripts/xstocks-op/XStocksPhase2Eth3CP.s.sol --rpc-url $MAINNET_RPC --sender 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E --no-isolate -vvv
 */
contract XStocksPhase2Eth3CP is XStocksOPDeployer, GnosisHelpers, Test {
    using stdJson for string;

    struct Operation {
        address[] targets;
        bytes[] payloads;
        bytes32 salt;
    }

    bytes32 constant TL_PREDECESSOR = bytes32(0);
    bytes32 constant PHASE1_SALT = keccak256("XStocksOP.topUpConfig");
    uint256 constant CHUNK = 46;
    uint256 constant GAS_TARGET = 14_000_000;
    uint256 constant SHARES_ROUNDING_DUST = 2;
    address constant LENS = 0x7135AD135Ec21ec765C1930E93DEB7DA9c27290C;

    RoleRegistry roleRegistry;
    TopUpFactory factory;
    EtherFiTimelock tl;
    TradingLens lens;
    address rawAdapter;
    address wrapperAdapter;
    address topUpDest;
    address[] raws;
    address[] wrappers;
    Operation[] rawOps;
    Operation[] wrapperOps;
    bytes32 phase1Id;

    function run() public {
        require(block.chainid == 1, "Ethereum only");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");
        _load();
        _checkPreconditions();
        _buildOps();

        string memory b1Schedule = _writeBundle("b1-step1-schedule", string.concat(_header(), _tx(address(tl), abi.encodeCall(TimelockController.cancel, (phase1Id)), false), _scheduleTx(rawOps[0], false), _scheduleTx(rawOps[1], true)));
        string memory b2Schedule = _writeBundle("b2-step1-schedule", string.concat(_header(), _scheduleTx(wrapperOps[0], false), _scheduleTx(wrapperOps[1], true)));
        string[2] memory b1Execute = [_writeBundle("b1-step2-execute-1", string.concat(_header(), _executeTx(rawOps[0], true))), _writeBundle("b1-step2-execute-2", string.concat(_header(), _executeTx(rawOps[1], true)))];
        string[2] memory b2Execute = [_writeBundle("b2-step2-execute-1", string.concat(_header(), _executeTx(wrapperOps[0], true))), _writeBundle("b2-step2-execute-2", string.concat(_header(), _executeTx(wrapperOps[1], true)))];
        string memory lensRemove = _writeBundle("b2-lens-remove", _lensTxs());

        console.log("=== Bundle 1 and 2, step 1: cancel the Phase 1 operation, schedule four batches ===");
        _run(b1Schedule);
        _run(b2Schedule);
        require(tl.getOperationState(phase1Id) == TimelockController.OperationState.Unset, "Phase 1 operation not cancelled");
        for (uint256 i; i < 2; ++i) {
            require(tl.getOperationState(_id(rawOps[i])) == TimelockController.OperationState.Waiting, "raw batch not scheduled");
            require(tl.getOperationState(_id(wrapperOps[i])) == TimelockController.OperationState.Waiting, "wrapper batch not scheduled");
        }

        console.log("=== Warp 8h, step 2: execute the four batches ===");
        vm.warp(block.timestamp + C.ADMIN_DELAY + 1);
        for (uint256 i; i < 2; ++i) {
            _run(b1Execute[i]);
        }
        _assertRoutes(raws, rawAdapter, "raw");
        for (uint256 i; i < 2; ++i) {
            _run(b2Execute[i]);
        }
        _assertRoutes(wrappers, wrapperAdapter, "wrapper");

        console.log("=== Lens removal ===");
        uint256 listed = lens.getSupportedTokens().length;
        _run(lensRemove);
        assertEq(lens.getSupportedTokens().length, listed - raws.length, "lens count");
        for (uint256 i; i < wrappers.length; ++i) {
            assertFalse(lens.isSupportedToken(wrappers[i]), string.concat("wrapper still on the lens: ", vm.toString(i)));
        }

        _simulateRawBridge(0);
        _simulateWrapperBridge(0);
        console.log("Simulation OK");
    }

    function _load() internal {
        string memory d = readDeploymentFile();
        roleRegistry = RoleRegistry(d.readAddress(".addresses.RoleRegistry"));
        factory = TopUpFactory(payable(d.readAddress(".addresses.TopUpSourceFactory")));
        tl = EtherFiTimelock(payable(C.ADMIN_TIMELOCK));
        lens = TradingLens(LENS);
        rawAdapter = d.readAddress(string.concat(".addresses.", C.KEY_CCIP_ADAPTER));
        require(rawAdapter.code.length != 0, "Backed CCIP adapter not deployed");
        wrapperAdapter = _deployWrapperAdapter(true);
        _checkRecorded(d, C.KEY_CCIP_WRAPPER_ADAPTER, wrapperAdapter);
        topUpDest = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(C.OP_CHAIN_ID), "/deployments.json")).readAddress(".addresses.TopUpDest");
        (raws, wrappers) = StockRedirectWrappers.pairs();

        // The Phase 1 top-up operation: SPYx, QQQx and TBLLx raw routes, scheduled by 3CP-730 nonce 73
        address[] memory targets = new address[](1);
        targets[0] = address(factory);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeCall(TopUpFactory.setTokenConfig, (C.raws(), _chainIds(3), _configs(rawAdapter, 3)));
        phase1Id = tl.hashOperationBatch(targets, new uint256[](1), payloads, TL_PREDECESSOR, PHASE1_SALT);
    }

    function _checkPreconditions() internal view {
        require(roleRegistry.hasRole(keccak256("ADMIN_TIMELOCK_ROLE"), C.ADMIN_TIMELOCK), "admin timelock lacks ADMIN_TIMELOCK_ROLE");
        require(tl.getMinDelay() == C.ADMIN_DELAY, "timelock minDelay mismatch");
        require(tl.hasRole(tl.PROPOSER_ROLE(), C.SAFE), "Safe is not a proposer");
        require(tl.hasRole(tl.EXECUTOR_ROLE(), C.SAFE) || tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "Safe is not an executor");
        require(tl.hasRole(tl.CANCELLER_ROLE(), C.SAFE), "Safe is not a canceller");
        require(tl.isOperationPending(phase1Id), "Phase 1 operation is not pending: drop the cancel");
        require(topUpDest != address(0), "TopUpDest on Optimism not found");
        require(lens.roleRegistry().hasRole(keccak256("ADMIN_ROLE"), C.SAFE), "Safe lacks ADMIN_ROLE on the lens registry");
        for (uint256 i; i < raws.length; ++i) {
            string memory n = vm.toString(i);
            require(IERC4626(wrappers[i]).asset() == raws[i], string.concat("wrapper asset mismatch: ", n));
            require(IBackedCCIPBridge(C.BACKED_BRIDGE).tokenIds(raws[i]) != 0, string.concat("raw not on the bridge: ", n));
            require(factory.getTokenConfig(raws[i], C.OP_CHAIN_ID).bridgeAdapter == address(0), string.concat("raw already routed: ", n));
            require(factory.getTokenConfig(wrappers[i], C.OP_CHAIN_ID).bridgeAdapter == address(0), string.concat("wrapper already routed: ", n));
            require(lens.isSupportedToken(wrappers[i]) && !lens.isSupportedToken(raws[i]), string.concat("lens state unexpected: ", n));
        }
    }

    function _buildOps() internal {
        for (uint256 start; start < raws.length; start += CHUNK) {
            uint256 n = raws.length - start < CHUNK ? raws.length - start : CHUNK;
            uint256 index = start / CHUNK + 1;
            _pushOp(rawOps, _slice(raws, start, n), rawAdapter, keccak256(abi.encodePacked("XStocksOP.phase2.rawRoutes.", vm.toString(index))));
            _pushOp(wrapperOps, _slice(wrappers, start, n), wrapperAdapter, keccak256(abi.encodePacked("XStocksOP.phase2.wrapperRoutes.", vm.toString(index))));
        }
        require(rawOps.length == 2 && wrapperOps.length == 2, "expected two batches per list");
        for (uint256 i; i < 2; ++i) {
            require(!tl.isOperation(_id(rawOps[i])), "raw batch already scheduled");
            require(!tl.isOperation(_id(wrapperOps[i])), "wrapper batch already scheduled");
        }
    }

    function _pushOp(Operation[] storage ops, address[] memory tokens, address adapter, bytes32 salt) internal {
        Operation storage op = ops.push();
        op.targets.push(address(factory));
        op.payloads.push(abi.encodeCall(TopUpFactory.setTokenConfig, (tokens, _chainIds(tokens.length), _configs(adapter, tokens.length))));
        op.salt = salt;
    }

    function _lensTxs() internal view returns (string memory) {
        string memory txs = _header();
        for (uint256 i; i < wrappers.length; ++i) {
            txs = string.concat(txs, _tx(LENS, abi.encodeCall(TradingLens.removeSupportedToken, (wrappers[i])), i == wrappers.length - 1));
        }
        return txs;
    }

    function _chainIds(uint256 n) internal pure returns (uint256[] memory) {
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = C.OP_CHAIN_ID;
        }
        return ids;
    }

    /// @dev The same stock arrives on the other side, as raw or re-wrapped by TopUpDest, so there is no slippage to bound
    function _configs(address adapter, uint256 n) internal view returns (TopUpFactory.TokenConfig[] memory) {
        TopUpFactory.TokenConfig[] memory configs = new TopUpFactory.TokenConfig[](n);
        for (uint256 i; i < n; ++i) {
            configs[i] = TopUpFactory.TokenConfig({ bridgeAdapter: adapter, recipientOnDestChain: topUpDest, maxSlippageInBps: 0, additionalData: abi.encode(C.BACKED_BRIDGE, C.OPTIMISM_SELECTOR) });
        }
        return configs;
    }

    function _slice(address[] memory list, uint256 start, uint256 n) internal pure returns (address[] memory) {
        address[] memory out = new address[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = list[start + i];
        }
        return out;
    }

    function _assertRoutes(address[] memory tokens, address adapter, string memory label) internal view {
        TopUpFactory.TokenConfig memory want = _configs(adapter, 1)[0];
        for (uint256 i; i < tokens.length; ++i) {
            string memory n = string.concat(label, " ", vm.toString(i));
            TopUpFactory.TokenConfig memory got = factory.getTokenConfig(tokens[i], C.OP_CHAIN_ID);
            assertEq(got.bridgeAdapter, want.bridgeAdapter, string.concat(n, ": adapter"));
            assertEq(got.recipientOnDestChain, want.recipientOnDestChain, string.concat(n, ": recipient"));
            assertEq(uint256(got.maxSlippageInBps), 0, string.concat(n, ": slippage"));
            assertEq(got.additionalData, want.additionalData, string.concat(n, ": additional data"));
            assertTrue(factory.isTokenSupported(tokens[i]), string.concat(n, ": not supported"));
        }
    }

    /// @dev Funds the factory with raw stock from the wrapper vault (the raw token is shares-based, so `deal`
    ///      cannot find its balance slot) and bridges it through the live factory over the raw adapter
    function _simulateRawBridge(uint256 i) internal {
        uint256 amount = _vaultAmount(i);
        uint256 before = IERC20(raws[i]).balanceOf(address(factory));
        vm.prank(wrappers[i]);
        IERC20(raws[i]).transfer(address(factory), amount);
        uint256 bridgeAmount = IERC20(raws[i]).balanceOf(address(factory)) - before;
        _bridge(raws[i], bridgeAmount);
        assertApproxEqAbs(IERC20(raws[i]).balanceOf(address(factory)), before, SHARES_ROUNDING_DUST, "raw not consumed by the bridge");
    }

    /// @dev Mints wrapper shares to the factory from raw taken out of the vault, as a TradingSafe redirect leaves
    ///      them, and bridges them through the live factory over the wrapper adapter
    function _simulateWrapperBridge(uint256 i) internal {
        uint256 amount = _vaultAmount(i);
        address funder = makeAddr("xstocksFunder");
        vm.prank(wrappers[i]);
        IERC20(raws[i]).transfer(funder, amount);
        uint256 received = IERC20(raws[i]).balanceOf(funder);
        vm.startPrank(funder);
        IERC20(raws[i]).approve(wrappers[i], received);
        uint256 shares = IERC4626(wrappers[i]).deposit(received, address(factory));
        vm.stopPrank();
        require(shares != 0, "no wrapper shares minted");
        _bridge(wrappers[i], shares);
        assertEq(IERC20(wrappers[i]).balanceOf(address(factory)), 0, "wrapper not consumed by the bridge");
    }

    function _vaultAmount(uint256 i) internal view returns (uint256) {
        uint256 held = IERC20(raws[i]).balanceOf(wrappers[i]);
        require(held != 0, "wrapper vault holds nothing to simulate with");
        return held < 1e18 ? held : 1e18;
    }

    function _bridge(address token, uint256 amount) internal {
        address bridger = makeAddr("xstocksBridger");
        bytes32 bridgerRole = factory.TOPUP_FACTORY_BRIDGER_ROLE();
        if (!roleRegistry.hasRole(bridgerRole, bridger)) {
            vm.prank(roleRegistry.owner());
            roleRegistry.grantRole(bridgerRole, bridger);
        }
        (, uint256 fee) = factory.getBridgeFee(token, amount, C.OP_CHAIN_ID);
        vm.deal(bridger, fee);
        vm.prank(bridger);
        factory.bridge{ value: fee }(token, amount, C.OP_CHAIN_ID);
        console.log("Simulated bridge to Optimism of", amount, "of", token);
        console.log("  native fee (wei):", fee);
    }

    // ── Bundle encoding and the measured run ───────────────────────────────────────

    function _header() internal pure returns (string memory) {
        return _getGnosisHeader("1", addressToHex(C.SAFE));
    }

    function _scheduleTx(Operation storage op, bool isLast) internal view returns (string memory) {
        return _tx(address(tl), abi.encodeWithSignature("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)", op.targets, new uint256[](op.targets.length), op.payloads, TL_PREDECESSOR, op.salt, C.ADMIN_DELAY), isLast);
    }

    function _executeTx(Operation storage op, bool isLast) internal view returns (string memory) {
        return _tx(address(tl), abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", op.targets, new uint256[](op.targets.length), op.payloads, TL_PREDECESSOR, op.salt), isLast);
    }

    function _tx(address to, bytes memory data, bool isLast) internal pure returns (string memory) {
        return _getGnosisTransaction(addressToHex(to), iToHex(data), "0", isLast);
    }

    function _writeBundle(string memory step, string memory txs) internal returns (string memory) {
        vm.createDir("./output", true);
        string memory path = string.concat("./output/XStocksPhase2Eth3CP-1-", step, ".json");
        vm.writeFile(path, txs);
        console.log("Wrote", path);
        return path;
    }

    function _id(Operation storage op) internal view returns (bytes32) {
        return tl.hashOperationBatch(op.targets, new uint256[](op.targets.length), op.payloads, TL_PREDECESSOR, op.salt);
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
}
