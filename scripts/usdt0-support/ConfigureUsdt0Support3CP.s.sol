// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { StargateModule } from "../../src/modules/stargate/StargateModule.sol";
import { IOFT } from "../../src/interfaces/IOFT.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import {
    DynamicReserveConfigLike,
    IHubConfiguratorLike,
    IHubLike,
    ISpokeConfiguratorLike,
    ISpokeLike,
    InterestRateDataLike,
    ReserveConfigLike,
    SpokeConfigLike
} from "../wspyx-paxg/WspyxPaxgProdConfig.sol";
import { ZchfUsdt0PaxgyProd as L } from "../zchf-usdt0-paxgy/ZchfUsdt0PaxgyProdConfig.sol";
import { Usdt0SupportProd as C } from "./Usdt0SupportProdConfig.sol";

interface IAdminTimelock {
    function scheduleBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata payloads, bytes32 predecessor, bytes32 salt, uint256 delay) external;
    function executeBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata payloads, bytes32 predecessor, bytes32 salt) external payable;
    function hashOperationBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata payloads, bytes32 predecessor, bytes32 salt) external pure returns (bytes32);
    function getMinDelay() external view returns (uint256);
    function isOperation(bytes32 id) external view returns (bool);
}

interface ISettlementDispatcherLike {
    function setSettlementRecipients(address[] calldata tokens, address[] calldata recipients) external;
    function getSettlementRecipient(address token) external view returns (address);
}

interface IOAppPeers {
    function peers(uint32 eid) external view returns (bytes32);
}

interface ILendGatewayLike {
    function setReserveId(address asset, uint256 reserveId) external;
    function setSpendAsset(address asset, bool spendable) external;
    function reserveIdOf(address asset) external view returns (uint256);
    function isRegistered(address asset) external view returns (bool);
    function isSpendAsset(address asset) external view returns (bool);
}

/**
 * @title ConfigureUsdt0Support3CP
 * @notice Generates the three Optimism Operating Safe bundles of 3CP-699 — the settlement, lend-gateway
 *         and cross-chain-withdrawal leg of USD₮0 support — and rehearses all three on a fork.
 *
 *         Bundle 1 (Safe nonce N)   two calls, no dependency on any other proposal
 *           1. ADMIN_TIMELOCK.scheduleBatch: setSettlementRecipients(USDT0) on Rain, Reap and Pix,
 *              each mirroring that dispatcher's live USDT recipient. The deployed dispatchers accept
 *              no other caller, so this cannot be a direct Safe call.
 *           2. StargateModule.setAssetConfig([USDT0], [(isOFT true, pool = the OP USD₮0 OFT)]).
 *              One call opens all three destinations: destEid is a requestBridge argument.
 *
 *         Bundle 2 (Safe nonce N+1) after >= 8h: ADMIN_TIMELOCK.executeBatch, byte-identical payload.
 *
 *         Bundle 3 (Safe nonce N+2) after 3CP-698 has EXECUTED:
 *           1. LendGateway.setReserveId(USDT0, 23)
 *           2. LendGateway.setSpendAsset(USDT0, true)   — reverts AssetNotRegistered without call 1
 *
 *         Nonce order is deliberate. The settlement recipients land before USDT0 becomes a lend-gateway
 *         spend asset, so a debit spend can never settle into a dispatcher that has nowhere to send it.
 *
 * Usage:
 *   forge script scripts/usdt0-support/ConfigureUsdt0Support3CP.s.sol --rpc-url $OPTIMISM_RPC
 */
contract ConfigureUsdt0Support3CP is GnosisHelpers, Utils, Test {
    string constant OUT_DIR = "./output/usdt0-support";
    string constant SCHEDULE_PATH = "./output/usdt0-support/settlement-stargate-schedule.json";
    string constant EXECUTE_PATH = "./output/usdt0-support/settlement-execute.json";
    string constant LEND_PATH = "./output/usdt0-support/lend-gateway.json";

    /// @dev 1,000 USDT0 — the amount the withdrawal-route quotes are taken at
    uint256 constant QUOTE_AMOUNT = 1_000e6;

    ILendGatewayLike gateway;

    function run() public {
        require(block.chainid == 10, "must be Optimism");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        gateway = ILendGatewayLike(
            stdJson.readAddress(
                vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/cash-lend.json")),
                ".lendGateway"
            )
        );

        _assertPreState();

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _settlementBatch();
        uint256 delay = IAdminTimelock(C.ADMIN_TIMELOCK).getMinDelay();
        bytes32 operationId = IAdminTimelock(C.ADMIN_TIMELOCK).hashOperationBatch(targets, values, payloads, C.PREDECESSOR, C.OP_SALT_USDT0_SETTLEMENT);
        require(!IAdminTimelock(C.ADMIN_TIMELOCK).isOperation(operationId), "operation id already scheduled");

        console.log("ADMIN_TIMELOCK minDelay (s): %s", delay);
        console.log("settlement operation id:");
        console.logBytes32(operationId);

        vm.createDir(OUT_DIR, true);
        _writeBundle1(targets, values, payloads, delay);
        _writeBundle2(targets, values, payloads);
        _writeBundle3();

        // ── fork rehearsal, in signing order ──────────────────────────────────────────────────────
        executeGnosisTransactionBundle(SCHEDULE_PATH);
        vm.warp(block.timestamp + delay + 1);
        executeGnosisTransactionBundle(EXECUTE_PATH);

        if (_reserveIdOf(C.USDT0) == type(uint256).max) {
            console.log("Reserve 23 not listed live; rehearsing the 3CP-698 USDT0 listing on the fork");
            _rehearse698();
        }
        executeGnosisTransactionBundle(LEND_PATH);

        _assertPostState();
        console.log("Simulation passed. Withdrawal quotes (native fee, wei) for %s USDT0:", QUOTE_AMOUNT);
        _logQuote("Ethereum (delivers USDT)", C.EID_ETHEREUM);
        _logQuote("Arbitrum", C.EID_ARBITRUM);
        _logQuote("HyperEVM", C.EID_HYPEREVM);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //                                        THE BATCH
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    /// @dev One setSettlementRecipients per dispatcher rather than one batched call, because the
    ///      recipient differs per dispatcher and a per-dispatcher call is what a signer can read.
    function _settlementBatch() internal pure returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads) {
        (address[] memory dispatchers, address[] memory recipients) = _settlementRails();
        targets = new address[](dispatchers.length);
        values = new uint256[](dispatchers.length);
        payloads = new bytes[](dispatchers.length);

        for (uint256 i; i < dispatchers.length; ++i) {
            address[] memory tokens = new address[](1);
            address[] memory to = new address[](1);
            tokens[0] = C.USDT0;
            to[0] = recipients[i];
            targets[i] = dispatchers[i];
            payloads[i] = abi.encodeCall(ISettlementDispatcherLike.setSettlementRecipients, (tokens, to));
        }
    }

    /// @dev The three dispatchers that settle USDT today, each with the recipient it settles USDT to.
    ///      CardOrder is absent on purpose — see Usdt0SupportProdConfig.
    function _settlementRails() internal pure returns (address[] memory dispatchers, address[] memory recipients) {
        dispatchers = new address[](3);
        recipients = new address[](3);
        (dispatchers[0], recipients[0]) = (C.DISPATCHER_RAIN, C.USD_SETTLEMENT_RECIPIENT);
        (dispatchers[1], recipients[1]) = (C.DISPATCHER_REAP, C.USD_SETTLEMENT_RECIPIENT);
        (dispatchers[2], recipients[2]) = (C.DISPATCHER_PIX, C.PIX_USDT_RECIPIENT);
    }

    function _stargateConfigCalldata() internal pure returns (bytes memory) {
        address[] memory assets = new address[](1);
        StargateModule.AssetConfig[] memory configs = new StargateModule.AssetConfig[](1);
        assets[0] = C.USDT0;
        configs[0] = StargateModule.AssetConfig({ isOFT: true, pool: C.USDT0_OFT_OP });
        return abi.encodeCall(StargateModule.setAssetConfig, (assets, configs));
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //                                        BUNDLES
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    function _writeBundle1(address[] memory targets, uint256[] memory values, bytes[] memory payloads, uint256 delay) internal {
        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(C.OPERATING_SAFE));
        txs = _append(txs, C.ADMIN_TIMELOCK, abi.encodeCall(IAdminTimelock.scheduleBatch, (targets, values, payloads, C.PREDECESSOR, C.OP_SALT_USDT0_SETTLEMENT, delay)), false);
        txs = _append(txs, C.STARGATE_MODULE, _stargateConfigCalldata(), true);
        vm.writeFile(SCHEDULE_PATH, txs);
        console.log("Written: %s", SCHEDULE_PATH);
    }

    function _writeBundle2(address[] memory targets, uint256[] memory values, bytes[] memory payloads) internal {
        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(C.OPERATING_SAFE));
        txs = _append(txs, C.ADMIN_TIMELOCK, abi.encodeCall(IAdminTimelock.executeBatch, (targets, values, payloads, C.PREDECESSOR, C.OP_SALT_USDT0_SETTLEMENT)), true);
        vm.writeFile(EXECUTE_PATH, txs);
        console.log("Written: %s", EXECUTE_PATH);
    }

    function _writeBundle3() internal {
        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(C.OPERATING_SAFE));
        txs = _append(txs, address(gateway), abi.encodeCall(ILendGatewayLike.setReserveId, (C.USDT0, C.LEND_RESERVE_ID_USDT0)), false);
        txs = _append(txs, address(gateway), abi.encodeCall(ILendGatewayLike.setSpendAsset, (C.USDT0, true)), true);
        vm.writeFile(LEND_PATH, txs);
        console.log("Written: %s", LEND_PATH);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //                                     STATE ASSERTIONS
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    /// @dev Everything this proposal mirrors is read off the chain and matched against the pins, so a
    ///      drifted recipient, a re-pointed OFT or a shifted reserve fails here rather than on-chain.
    function _assertPreState() internal view {
        (address[] memory dispatchers, address[] memory recipients) = _settlementRails();
        for (uint256 i; i < dispatchers.length; ++i) {
            assertEq(ISettlementDispatcherLike(dispatchers[i]).getSettlementRecipient(C.USDT), recipients[i], "live USDT recipient != the pin USDT0 mirrors");
            assertEq(ISettlementDispatcherLike(dispatchers[i]).getSettlementRecipient(C.USDT0), address(0), "USDT0 recipient already set");
        }
        assertEq(ISettlementDispatcherLike(C.DISPATCHER_CARD_ORDER).getSettlementRecipient(C.USDT), address(0), "CardOrder now settles USDT: revisit the omission");

        StargateModule.AssetConfig memory live = StargateModule(payable(C.STARGATE_MODULE)).getAssetConfig(C.USDT0);
        assertEq(live.pool, address(0), "USDT0 already configured on StargateModule");

        assertEq(IOFT(C.USDT0_OFT_OP).token(), C.USDT0, "OP OFT does not wrap USDT0");
        assertFalse(IOFT(C.USDT0_OFT_OP).approvalRequired(), "OP OFT now needs an approval: re-check _bridgeOft");
        _assertPeer(C.EID_ETHEREUM, C.USDT0_OFT_ETHEREUM);
        _assertPeer(C.EID_ARBITRUM, C.USDT0_OFT_ARBITRUM);
        _assertPeer(C.EID_HYPEREVM, C.USDT0_OFT_HYPEREVM);

        assertFalse(gateway.isRegistered(C.USDT0), "USDT0 already a lend-gateway reserve");
        assertTrue(gateway.isRegistered(C.USDT), "USDT is not a lend-gateway reserve: the mirror is wrong");
        assertTrue(gateway.isSpendAsset(C.USDT), "USDT is not a lend-gateway spend asset: the mirror is wrong");
    }

    function _assertPostState() internal view {
        (address[] memory dispatchers, address[] memory recipients) = _settlementRails();
        for (uint256 i; i < dispatchers.length; ++i) {
            assertEq(ISettlementDispatcherLike(dispatchers[i]).getSettlementRecipient(C.USDT0), recipients[i], "USDT0 recipient not set");
            assertEq(
                ISettlementDispatcherLike(dispatchers[i]).getSettlementRecipient(C.USDT0),
                ISettlementDispatcherLike(dispatchers[i]).getSettlementRecipient(C.USDT),
                "USDT0 recipient != USDT recipient"
            );
        }
        assertEq(ISettlementDispatcherLike(C.DISPATCHER_CARD_ORDER).getSettlementRecipient(C.USDT0), address(0), "CardOrder must stay unconfigured");

        StargateModule.AssetConfig memory config = StargateModule(payable(C.STARGATE_MODULE)).getAssetConfig(C.USDT0);
        assertTrue(config.isOFT, "USDT0 not marked as an OFT");
        assertEq(config.pool, C.USDT0_OFT_OP, "USDT0 pool");

        assertTrue(gateway.isRegistered(C.USDT0), "USDT0 not registered");
        assertEq(gateway.reserveIdOf(C.USDT0), C.LEND_RESERVE_ID_USDT0, "USDT0 reserve id");
        assertTrue(gateway.isSpendAsset(C.USDT0), "USDT0 not a spend asset");

        // Each destination quotes end to end: a peer that exists but cannot price would revert here
        _assertQuotes(C.EID_ETHEREUM);
        _assertQuotes(C.EID_ARBITRUM);
        _assertQuotes(C.EID_HYPEREVM);
    }

    function _assertPeer(uint32 eid, address expected) internal view {
        assertEq(IOAppPeers(C.USDT0_OFT_OP).peers(eid), bytes32(uint256(uint160(expected))), "OP OFT peer");
    }

    function _assertQuotes(uint32 eid) internal view {
        (, uint256 fee) = StargateModule(payable(C.STARGATE_MODULE)).getBridgeFee(eid, C.USDT0, QUOTE_AMOUNT, C.OPERATING_SAFE, 50);
        assertGt(fee, 0, "withdrawal route quotes a zero native fee");
    }

    function _logQuote(string memory label, uint32 eid) internal view {
        (, uint256 fee) = StargateModule(payable(C.STARGATE_MODULE)).getBridgeFee(eid, C.USDT0, QUOTE_AMOUNT, C.OPERATING_SAFE, 50);
        console.log("  %s (eid %s): %s", label, eid, fee);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //                                   3CP-698 FORK REHEARSAL
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    /// @dev Fork-only: the USDT0 operation of 3CP-698, sent by the Lend EtherFiTimelock, with the same
    ///      parameters aave-v4 pins. Lets bundle 3 be generated and rehearsed before 698 has executed.
    function _rehearse698() internal {
        uint256 assetId = IHubLike(L.CASH_HUB).getAssetCount();
        require(assetId == C.LEND_RESERVE_ID_USDT0, "hub asset count drifted off the pinned reserve id");

        vm.startPrank(L.LEND_TIMELOCK);
        IHubConfiguratorLike(L.HUB_CONFIGURATOR).addAsset(
            L.CASH_HUB,
            C.USDT0,
            L.TREASURY_SPOKE,
            L.LEND_USDT0_LIQUIDITY_FEE,
            L.IR_STRATEGY,
            abi.encode(
                InterestRateDataLike({
                    optimalUsageRatio: L.LEND_USDT0_OPTIMAL_USAGE_RATIO,
                    baseDrawnRate: L.LEND_USDT0_BASE_DRAWN_RATE,
                    rateGrowthBeforeOptimal: L.LEND_USDT0_RATE_GROWTH_BEFORE_OPTIMAL,
                    rateGrowthAfterOptimal: L.LEND_USDT0_RATE_GROWTH_AFTER_OPTIMAL
                })
            )
        );
        IHubConfiguratorLike(L.HUB_CONFIGURATOR).addSpoke(
            L.CASH_HUB, L.CASH_SPOKE, assetId, SpokeConfigLike({ addCap: L.LEND_USDT0_ADD_CAP, drawCap: 0, riskPremiumThreshold: 0, active: true, halted: false })
        );
        ISpokeConfiguratorLike(L.SPOKE_CONFIGURATOR).addReserve(
            L.CASH_SPOKE,
            L.CASH_HUB,
            assetId,
            L.LEND_USDT0_FEED,
            ReserveConfigLike({ collateralRisk: 0, paused: false, frozen: false, borrowable: true, receiveSharesEnabled: true }),
            DynamicReserveConfigLike({ collateralFactor: L.LEND_USDT0_COLLATERAL_FACTOR, maxLiquidationBonus: L.LEND_USDT0_MAX_LIQUIDATION_BONUS, liquidationFee: L.LEND_LIQUIDATION_FEE })
        );
        vm.stopPrank();
        console.log("  [REHEARSAL] USDT0 listed on Summer Lend as assetId %s", assetId);
    }

    function _reserveIdOf(address token) internal view returns (uint256) {
        ISpokeLike spoke = ISpokeLike(C.CASH_SPOKE);
        uint256 count = spoke.getReserveCount();
        for (uint256 i; i < count; ++i) {
            if (spoke.getReserve(i).underlying == token) return i;
        }
        return type(uint256).max;
    }

    function _append(string memory txs, address to, bytes memory data, bool isLast) internal pure returns (string memory) {
        return string.concat(txs, _getGnosisTransaction(addressToHex(to), iToHex(data), "0", isLast));
    }
}
