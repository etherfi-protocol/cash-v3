// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IMessageLibManager, SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";

/**
 * @title RecoverySetConfigLib
 * @notice ULN `setConfig` calldata for the opBNB (204) recovery route, which has no default LZ DVN
 *         pathway to/from OP — so the OApp must pin the DVNs explicitly on both the OP send side and
 *         the destination receive side.
 *
 *         Uses a **2-DVN quorum** (LayerZero Labs + Nethermind) on both sides. A single required DVN
 *         never reaches quorum on this route — the message sends but stalls INFLIGHT / DVN WAITING and
 *         is never verified on destination (confirmed with LZ: >=2 DVNs required, matches the proven
 *         weETH-cross-chain recipe). The `requiredDVNs` array MUST be sorted ascending by address; the
 *         ULN setter enforces it — both pairs here sort to [LZ Labs, Nethermind].
 *
 *         Addresses are from LayerZero metadata (metadata.layerzero-api.com/v1/metadata), parsed
 *         deterministically. The OP send lib + OP DVN are additionally proven on a live OP fork by
 *         `test/integration/fork/RecoverySetConfigProbe.t.sol` (quote OP->opBNB succeeds).
 *
 *         Defined once so the ULN encoding lives in a single place across both 3CP generators.
 */
library RecoverySetConfigLib {
    // EndpointV2 — identical on OP, opBNB and X-Layer.
    address internal constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    uint32  internal constant CONFIG_TYPE_ULN = 2;
    // ponytail: matches the probe's OP send config (source-chain confirmations); tune if finality needs it.
    uint64  internal constant CONFIRMATIONS = 15;

    uint32  internal constant OP_EID = 30111;

    // OP source (send) — probe-verified. DVNs sorted ascending: LZ Labs < Nethermind.
    address internal constant OP_SEND_ULN       = 0x1322871e4ab09Bc7f5717189434f97bBD9546e95;
    address internal constant OP_LZLABS_DVN      = 0x6A02D83e8d433304bba74EF1c427913958187142;
    address internal constant OP_NETHERMIND_DVN  = 0xa7b5189bcA84Cd304D8553977c7C614329750d99;

    // Destination (receive), keyed off srcEid = OP. DVNs sorted ascending: LZ Labs < Nethermind.
    address internal constant OPBNB_RECEIVE_ULN     = 0x9c9e25F9fC4e8134313C2a9f5c719f5c9F4fbD95;
    address internal constant OPBNB_LZLABS_DVN      = 0x3eBb618B5c9d09DE770979D552b27D6357Aff73B;
    address internal constant OPBNB_NETHERMIND_DVN  = 0x6a4C9096F162f0ab3C0517B0a40dc1CE44785e16;

    /// Mirror of `UlnBase.UlnConfig` (same field order/types) for abi.encode.
    struct UlnConfig {
        uint64 confirmations;
        uint8 requiredDVNCount;
        uint8 optionalDVNCount;
        uint8 optionalDVNThreshold;
        address[] requiredDVNs;
        address[] optionalDVNs;
    }

    /// True for the chains whose recovery route needs an explicit DVN setConfig.
    function needsSetConfig(uint256 chainId) internal pure returns (bool) {
        return chainId == 204;
    }

    /// endpoint.setConfig calldata for the OP module's SEND ULN toward one dest route (`dstEid`).
    function opSendConfig(address module, uint32 dstEid)
        internal
        pure
        returns (address target, bytes memory data)
    {
        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] = SetConfigParam({ eid: dstEid, configType: CONFIG_TYPE_ULN, config: _uln(OP_LZLABS_DVN, OP_NETHERMIND_DVN) });
        return (ENDPOINT, abi.encodeCall(IMessageLibManager.setConfig, (module, OP_SEND_ULN, params)));
    }

    /// endpoint.setConfig calldata for the dest dispatcher's RECEIVE ULN from OP (`srcEid = OP_EID`).
    function destReceiveConfig(address dispatcher, uint256 chainId)
        internal
        pure
        returns (address target, bytes memory data)
    {
        (address lib, address dvn0, address dvn1) = _destLibDvns(chainId);
        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] = SetConfigParam({ eid: OP_EID, configType: CONFIG_TYPE_ULN, config: _uln(dvn0, dvn1) });
        return (ENDPOINT, abi.encodeCall(IMessageLibManager.setConfig, (dispatcher, lib, params)));
    }

    /// 2-DVN quorum. `dvn0` MUST be < `dvn1` (ULN requires requiredDVNs sorted ascending, no dupes).
    function _uln(address dvn0, address dvn1) private pure returns (bytes memory) {
        require(dvn0 < dvn1, "DVNs must be ascending and distinct");
        address[] memory req = new address[](2);
        req[0] = dvn0;
        req[1] = dvn1;
        return abi.encode(UlnConfig(CONFIRMATIONS, 2, 0, 0, req, new address[](0)));
    }

    function _destLibDvns(uint256 chainId) private pure returns (address lib, address dvn0, address dvn1) {
        if (chainId == 204) return (OPBNB_RECEIVE_ULN, OPBNB_LZLABS_DVN, OPBNB_NETHERMIND_DVN);
        revert("no custom receive DVN pathway for this chain");
    }
}
