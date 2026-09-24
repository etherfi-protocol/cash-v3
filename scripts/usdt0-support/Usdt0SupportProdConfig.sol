// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ZchfUsdt0PaxgyProd } from "../zchf-usdt0-paxgy/ZchfUsdt0PaxgyProdConfig.sol";

/**
 * @title Usdt0SupportProdConfig
 * @notice Address table and parameters for the third and last leg of USD₮0 support on Optimism:
 *         settlement rails, the Summer Lend gateway registration, and cross-chain withdrawals.
 *
 *         The two legs in front of it:
 *           1. 3CP-695 — Operating Safe: PriceProviderV2 / DebtManager / CashModule listing on OP,
 *              plus the Ethereum / Arbitrum / HyperEVM top-up rails (TopUpFactory, 8h timelock).
 *           2. 3CP-698 — Lend Timelock Safe: USDT0 as Summer Lend asset / reserve **23**, borrowable,
 *              plus PAXGy 24 and ZCHF 25. 24h EtherFiTimelock.
 *
 *         This leg (3CP-699):
 *           a. SettlementDispatcher.setSettlementRecipients(USDT0) on Rain, Reap and Pix, mirroring
 *              each dispatcher's live USDT recipient — through the 8h ADMIN_TIMELOCK, which is the
 *              only caller the deployed dispatchers accept.
 *           b. StargateModule.setAssetConfig(USDT0) as an OFT, which opens OP -> Ethereum / Arbitrum
 *              / HyperEVM withdrawals; the destination is a `requestBridge` argument, not config.
 *           c. LendGateway.setReserveId(USDT0, 23) then setSpendAsset(USDT0, true) — direct from the
 *              Operating Safe, and only after 698 has executed.
 *
 *         Every recipient, role and peer below was read off Optimism on 2026-09-24; the provenance
 *         is in queued/699/699.md in the 3CP-secure repo, and the generator re-reads and asserts it.
 */
library Usdt0SupportProd {
    // ---------------------------------------------------------------- Safes / admins
    /// @dev Cash operating safe (OP). Holds LEND_GATEWAY_ADMIN_ROLE and STARGATE_MODULE_ADMIN_ROLE,
    ///      and PROPOSER / EXECUTOR / CANCELLER on the ADMIN_TIMELOCK (verified 2026-09-24)
    address internal constant OPERATING_SAFE = ZchfUsdt0PaxgyProd.OPERATING_SAFE;
    /// @dev The 8h operating timelock, sole holder of ADMIN_TIMELOCK_ROLE. The deployed
    ///      SettlementDispatchers gate setSettlementRecipients on it: a direct Safe call reverts
    ///      OnlyAdminTimelock() (0x7010de69), verified live against all three dispatchers.
    address internal constant ADMIN_TIMELOCK = 0x9AEb8eaa982084219d1A938D8F7B5040a1d47849;

    // ---------------------------------------------------------------- tokens (OP)
    address internal constant USDT0 = ZchfUsdt0PaxgyProd.USDT0;
    /// @dev Legacy bridged USDT — the asset whose settlement and collateral treatment USDT0 mirrors
    address internal constant USDT = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;

    // ---------------------------------------------------------------- settlement dispatchers (OP)
    /// @dev BinSponsor.Reap == 0, .Rain == 1, .Pix == 2, .CardOrder == 3; each read back off
    ///      CashModule.getSettlementDispatcher rather than trusted from the deployment file
    address internal constant DISPATCHER_REAP = 0x9623e86Df854FF3b48F7B4079a516a4F64861Db2;
    address internal constant DISPATCHER_RAIN = 0x50A233C4a0Bb1d7124b0224880037d35767a501C;
    address internal constant DISPATCHER_PIX = 0x95aaddD43b6edF838ec486E9f9814787212Bf42D;
    /// @dev CardOrder is deliberately NOT configured: it has no recipient for USDT or USDC today and
    ///      settlement-bridger skips PhysicalCardOrders for settle() entirely. Listed so a reader can
    ///      see the omission is a decision, not an oversight.
    address internal constant DISPATCHER_CARD_ORDER = 0xb14FDfd7D2cfFb6Cc6953C1b80F1B1d12c2F766a;

    /// @dev The live USDT (and USDC) settlement recipient of Rain and Reap
    address internal constant USD_SETTLEMENT_RECIPIENT = 0xe04031f03DeB0aD7010C5AD0D70e9f1611Aa85DD;
    /// @dev The live USDT settlement recipient of Pix (the BRL rail; Pix settles USDC over CCTP instead)
    address internal constant PIX_USDT_RECIPIENT = 0x4358f4940283E6357128941a5c508e5F314D79CB;

    /// @dev keccak256("ETHERFI_CASH_OP_USDT0_SETTLEMENT_RECIPIENTS_V1"). Non-zero and specific so the
    ///      operation id stays re-schedulable if cancelled, and a stale re-execute reverts once Done.
    bytes32 internal constant OP_SALT_USDT0_SETTLEMENT = keccak256("ETHERFI_CASH_OP_USDT0_SETTLEMENT_RECIPIENTS_V1");
    bytes32 internal constant PREDECESSOR = bytes32(0);

    // ---------------------------------------------------------------- cross-chain withdrawals (OP)
    address internal constant STARGATE_MODULE = 0x865a756d15e40D1D38595a39F29867518594182E;
    /// @dev The USD₮0 OFT on Optimism. token() == USDT0, approvalRequired() == false (it burns from the
    ///      sender rather than pulling), no rate limiter. StargateModule._setAssetConfigs asserts
    ///      IStargate(pool).token() == asset, so a wrong pool here reverts rather than mis-routes.
    address internal constant USDT0_OFT_OP = 0xF03b4d9AC1D5d1E7c4cEf54C2A313b9fe051A0aD;
    /// @dev LayerZero eids the OP OFT peers, i.e. where a USDT0 withdrawal may go. Ethereum's peer is
    ///      an OFT *adapter* over native USDT, so a withdrawal to eid 30101 is DELIVERED AS USDT.
    uint32 internal constant EID_ETHEREUM = 30_101;
    uint32 internal constant EID_ARBITRUM = 30_110;
    uint32 internal constant EID_HYPEREVM = 30_367;
    /// @dev The peer each eid must resolve to, read off the OP OFT's own peers() table
    address internal constant USDT0_OFT_ETHEREUM = 0x6C96dE32CEa08842dcc4058c14d3aaAD7Fa41dee;
    address internal constant USDT0_OFT_ARBITRUM = 0x14E4A1B13bf7F943c8ff7C51fb60FA964A298D92;
    address internal constant USDT0_OFT_HYPEREVM = 0x904861a24F30EC96ea7CFC3bE9EA4B476d237e98;
    /// @dev What the Ethereum adapter releases: native USDT, not USDT0
    address internal constant USDT_ETHEREUM = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // ---------------------------------------------------------------- Summer Lend
    address internal constant CASH_SPOKE = ZchfUsdt0PaxgyProd.CASH_SPOKE;
    /// @dev The reserve id 3CP-698 lists USDT0 at. Pinned rather than discovered so a drifted listing
    ///      (another asset landing on 23 first) fails the generator instead of registering the wrong id.
    uint256 internal constant LEND_RESERVE_ID_USDT0 = 23;
}
