// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { BinSponsor } from "../../../src/interfaces/ICashModule.sol";
import { CashbackDispatcher } from "../../../src/cashback-dispatcher/CashbackDispatcher.sol";
import { LiquidUSDLiquifierOPModule } from "../../../src/modules/etherfi/LiquidUSDLiquifierOP.sol";
import { SettlementDispatcherV2 } from "../../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { TopUpDest } from "../../../src/top-up/TopUpDest.sol";
import { TimelockMigrationBase } from "./TimelockMigrationBase.s.sol";

/// @title UpgradeAndHandoverOptimism
/// @notice STAKE-1676 migration for Optimism: upgrades the 7 re-gated proxies (4 settlement
///         dispatchers, TopUpDest, CashbackDispatcher, LiquidUSDLiquifier) to the GOVERNANCE_ROLE
///         impls, grants GOVERNANCE_ROLE to the governance safe, and moves RoleRegistry ownership
///         to the EtherFiTimelock via the two-step handover. See TimelockMigrationBase for the
///         bundle layout and ordering rationale.
///
/// Usage:
///   forge script scripts/gnosis-txs/timelock-migration/UpgradeAndHandoverOptimism.s.sol --rpc-url $OPTIMISM_RPC --ledger --broadcast --slow
///   # step1 JSON → Safe UI now; step2 JSON → Safe UI after the 2-day delay
contract UpgradeAndHandoverOptimism is TimelockMigrationBase {
    // Deployed proxies on Optimism (deployments/mainnet/10/deployments.json)
    address constant ROLE_REGISTRY       = 0x5C1E3D653fcbC54Ae25c2AD9d59548D2082C687B;
    address constant DATA_PROVIDER       = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address constant DEBT_MANAGER        = 0x0078C5a459132e279056B2371fE8A8eC973A9553;
    address constant REAP_PROXY          = 0x9623e86Df854FF3b48F7B4079a516a4F64861Db2;
    address constant RAIN_PROXY          = 0x50A233C4a0Bb1d7124b0224880037d35767a501C;
    address constant PIX_PROXY           = 0x95aaddD43b6edF838ec486E9f9814787212Bf42D;
    address constant CARD_ORDER_PROXY    = 0xb14FDfd7D2cfFb6Cc6953C1b80F1B1d12c2F766a;
    address constant OP_TOP_UP_DEST      = 0x3a6A724595184dda4be69dB1Ce726F2Ac3D66B87;
    address constant CASHBACK_PROXY      = 0xef55eC694B0B8273967f28627C5BC26F5deea836;
    address constant LIQUIFIER_PROXY     = 0x39161A44588ec2327a18D4707EA5216C721ba539;

    address constant WETH_OP = 0x4200000000000000000000000000000000000006;

    // CREATE3 salts — one per implementation
    bytes32 constant SALT_REAP_IMPL        = keccak256("TimelockMigration.SettlementDispatcherReapImpl");
    bytes32 constant SALT_RAIN_IMPL        = keccak256("TimelockMigration.SettlementDispatcherRainImpl");
    bytes32 constant SALT_PIX_IMPL         = keccak256("TimelockMigration.SettlementDispatcherPixImpl");
    bytes32 constant SALT_CARD_ORDER_IMPL  = keccak256("TimelockMigration.SettlementDispatcherCardOrderImpl");
    bytes32 constant SALT_TOP_UP_DEST_IMPL = keccak256("TimelockMigration.TopUpDestImpl");
    bytes32 constant SALT_CASHBACK_IMPL    = keccak256("TimelockMigration.CashbackDispatcherImpl");
    bytes32 constant SALT_LIQUIFIER_IMPL   = keccak256("TimelockMigration.LiquidUSDLiquifierImpl");

    function run() public {
        address safe = _resolveContext(10, ROLE_REGISTRY);
        console.log("Safe (RoleRegistry owner):", safe);

        // ── 1. Deploy the 7 new implementations (deterministic, idempotent) ──
        vm.startBroadcast();
        address[] memory impls = new address[](7);
        impls[0] = deployCreate3(abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.Reap, DATA_PROVIDER)), SALT_REAP_IMPL);
        impls[1] = deployCreate3(abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.Rain, DATA_PROVIDER)), SALT_RAIN_IMPL);
        impls[2] = deployCreate3(abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.PIX, DATA_PROVIDER)), SALT_PIX_IMPL);
        impls[3] = deployCreate3(abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.CardOrder, DATA_PROVIDER)), SALT_CARD_ORDER_IMPL);
        impls[4] = deployCreate3(abi.encodePacked(type(TopUpDest).creationCode, abi.encode(DATA_PROVIDER, WETH_OP)), SALT_TOP_UP_DEST_IMPL);
        impls[5] = deployCreate3(abi.encodePacked(type(CashbackDispatcher).creationCode, abi.encode(DATA_PROVIDER)), SALT_CASHBACK_IMPL);
        impls[6] = deployCreate3(abi.encodePacked(type(LiquidUSDLiquifierOPModule).creationCode, abi.encode(DEBT_MANAGER, DATA_PROVIDER)), SALT_LIQUIFIER_IMPL);
        vm.stopBroadcast();

        address[] memory proxies = new address[](7);
        proxies[0] = REAP_PROXY;
        proxies[1] = RAIN_PROXY;
        proxies[2] = PIX_PROXY;
        proxies[3] = CARD_ORDER_PROXY;
        proxies[4] = OP_TOP_UP_DEST;
        proxies[5] = CASHBACK_PROXY;
        proxies[6] = LIQUIFIER_PROXY;

        // ── 2. step1 bundle: 7 upgrades + role grant + schedule handover request ──
        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(safe));
        for (uint256 i = 0; i < 7; i++) {
            txs = string(abi.encodePacked(txs, _upgradeTx(proxies[i], impls[i], false)));
        }
        txs = string(abi.encodePacked(txs, _grantGovernanceRoleTx(ROLE_REGISTRY, safe, false)));
        txs = string(abi.encodePacked(txs, _scheduleHandoverRequestTx(ROLE_REGISTRY, true)));
        string memory step1Path = _writeBundle("step1", txs);

        // ── 3. step2 bundle: execute handover request + complete handover ──
        string memory step2Path = _writeBundle("step2", _buildStep2(ROLE_REGISTRY, safe));

        // ── 4. Simulate both bundles on this fork and assert the end state ──
        _simulateAndVerify(step1Path, step2Path, ROLE_REGISTRY, safe, proxies, impls);

        // Re-gated function stays fast at the safe after the handover
        address refundWallet = SettlementDispatcherV2(payable(REAP_PROXY)).getRefundWallet();
        vm.prank(safe);
        SettlementDispatcherV2(payable(REAP_PROXY)).setRefundWallet(refundWallet);
        console.log("  [OK] safe can still call re-gated config functions");
    }
}
