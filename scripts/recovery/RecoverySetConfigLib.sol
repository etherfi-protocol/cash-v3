// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IMessageLibManager, SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";

/**
 * @title RecoverySetConfigLib
 * @notice ULN `setConfig` calldata for the opBNB (204) recovery route, which has no default LZ DVN
 *         pathway to/from OP — so the OApp must pin the DVNs explicitly on both the OP send side and
 *         the destination receive side.
 *
 *         Uses a **4-DVN quorum** (LayerZero Labs + Nethermind + Horizen + Canary) with **45 block
 *         confirmations** on both sides — matching the org-wide standard rolled out in 3CP-455 (weETH
 *         OFT security upgrade) across all 20 chains. A single required DVN never reaches quorum on
 *         this route (message sends but stalls INFLIGHT / DVN WAITING); LZ requires >=2, and 4 is the
 *         etherfi convention. All four providers are available on both OP and opBNB.
 *
 *         `requiredDVNs` MUST be sorted ascending by address with no dupes (the ULN setter enforces
 *         it); `_uln` sorts the set before encoding, so callers may pass any order.
 *
 *         Addresses are from LayerZero metadata (metadata.layerzero-api.com/v1/metadata). The OP send
 *         lib + DVN quorum are proven on a live OP fork by
 *         `test/integration/fork/RecoverySetConfigProbe.t.sol` (quote OP->opBNB succeeds).
 *
 *         Defined once so the ULN encoding lives in a single place across both 3CP generators.
 */
library RecoverySetConfigLib {
    // EndpointV2 — identical on OP, opBNB and X-Layer.
    address internal constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    uint32  internal constant CONFIG_TYPE_ULN = 2;
    // 45 confirmations — matches the 3CP-455 org-wide DVN standard.
    uint64  internal constant CONFIRMATIONS = 45;

    uint32  internal constant OP_EID = 30111;

    // OP source (send) DVNs.
    address internal constant OP_SEND_ULN        = 0x1322871e4ab09Bc7f5717189434f97bBD9546e95;
    address internal constant OP_LZLABS_DVN       = 0x6A02D83e8d433304bba74EF1c427913958187142;
    address internal constant OP_NETHERMIND_DVN   = 0xa7b5189bcA84Cd304D8553977c7C614329750d99;
    address internal constant OP_HORIZEN_DVN       = 0x9E930731cb4A6bf7eCc11F695A295c60bDd212eB;
    address internal constant OP_CANARY_DVN        = 0x5b6735c66d97479cCD18294fc96B3084EcB2fa3f;

    // opBNB destination (receive) DVNs, keyed off srcEid = OP.
    address internal constant OPBNB_RECEIVE_ULN     = 0x9c9e25F9fC4e8134313C2a9f5c719f5c9F4fbD95;
    address internal constant OPBNB_LZLABS_DVN       = 0x3eBb618B5c9d09DE770979D552b27D6357Aff73B;
    address internal constant OPBNB_NETHERMIND_DVN   = 0x6a4C9096F162f0ab3C0517B0a40dc1CE44785e16;
    address internal constant OPBNB_HORIZEN_DVN       = 0xDd7B5E1dB4AaFd5C8EC3b764eFB8ed265Aa5445B;
    address internal constant OPBNB_CANARY_DVN        = 0xE5491Fac6965Aa664EFD6d1aE5e7D1d56Da4FDDa;

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
        params[0] = SetConfigParam({
            eid: dstEid,
            configType: CONFIG_TYPE_ULN,
            config: _uln(OP_LZLABS_DVN, OP_NETHERMIND_DVN, OP_HORIZEN_DVN, OP_CANARY_DVN)
        });
        return (ENDPOINT, abi.encodeCall(IMessageLibManager.setConfig, (module, OP_SEND_ULN, params)));
    }

    /// endpoint.setConfig calldata for the dest dispatcher's RECEIVE ULN from OP (`srcEid = OP_EID`).
    function destReceiveConfig(address dispatcher, uint256 chainId)
        internal
        pure
        returns (address target, bytes memory data)
    {
        (address lib, address d0, address d1, address d2, address d3) = _destLibDvns(chainId);
        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] = SetConfigParam({ eid: OP_EID, configType: CONFIG_TYPE_ULN, config: _uln(d0, d1, d2, d3) });
        return (ENDPOINT, abi.encodeCall(IMessageLibManager.setConfig, (dispatcher, lib, params)));
    }

    /// 4-DVN quorum. Sorts the set ascending (ULN requires `requiredDVNs` sorted, no dupes).
    function _uln(address a, address b, address c, address d) private pure returns (bytes memory) {
        address[] memory req = new address[](4);
        req[0] = a; req[1] = b; req[2] = c; req[3] = d;
        // insertion sort ascending (n=4)
        for (uint256 i = 1; i < 4; ++i) {
            address key = req[i];
            uint256 j = i;
            while (j > 0 && req[j - 1] > key) {
                req[j] = req[j - 1];
                unchecked { --j; }
            }
            req[j] = key;
        }
        for (uint256 i = 1; i < 4; ++i) require(req[i - 1] < req[i], "DVNs must be distinct");
        return abi.encode(UlnConfig(CONFIRMATIONS, 4, 0, 0, req, new address[](0)));
    }

    function _destLibDvns(uint256 chainId)
        private
        pure
        returns (address lib, address d0, address d1, address d2, address d3)
    {
        if (chainId == 204) {
            return (OPBNB_RECEIVE_ULN, OPBNB_LZLABS_DVN, OPBNB_NETHERMIND_DVN, OPBNB_HORIZEN_DVN, OPBNB_CANARY_DVN);
        }
        revert("no custom receive DVN pathway for this chain");
    }
}
