// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IMessageLibManager, SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";

/**
 * @title RecoverySetConfigLib
 * @notice ULN `setConfig` calldata for the opBNB (204) and X-Layer (196) recovery routes, which have
 *         no default LZ DVN pathway to/from OP — so the OApp must pin the LayerZero Labs DVN explicitly
 *         on both the OP send side and the destination receive side.
 *
 *         Addresses are from LayerZero metadata (metadata.layerzero-api.com/v1/metadata), parsed
 *         deterministically. The OP send lib + OP DVN are additionally proven on a live OP fork by
 *         `test/integration/fork/RecoverySetConfigProbe.t.sol` (quote OP->opBNB / OP->X-Layer succeeds).
 *         The destination receive lib + DVN still want a live confirmation in the Phase 0.5 dev
 *         round-trip before prod broadcast — see ALL_CHAINS_LAUNCH.md.
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

    // OP source (send) — probe-verified.
    address internal constant OP_SEND_ULN   = 0x1322871e4ab09Bc7f5717189434f97bBD9546e95;
    address internal constant OP_LZLABS_DVN = 0x6A02D83e8d433304bba74EF1c427913958187142;

    // Destination (receive), keyed off srcEid = OP.
    address internal constant OPBNB_RECEIVE_ULN  = 0x9c9e25F9fC4e8134313C2a9f5c719f5c9F4fbD95;
    address internal constant OPBNB_LZLABS_DVN   = 0x3eBb618B5c9d09DE770979D552b27D6357Aff73B;
    address internal constant XLAYER_RECEIVE_ULN = 0x2367325334447C5E1E0f1b3a6fB947b262F58312;
    address internal constant XLAYER_LZLABS_DVN  = 0x9C061c9A4782294eeF65ef28Cb88233A987F4bdD;

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
        return chainId == 204 || chainId == 196;
    }

    /// endpoint.setConfig calldata for the OP module's SEND ULN toward one dest route (`dstEid`).
    function opSendConfig(address module, uint32 dstEid)
        internal
        pure
        returns (address target, bytes memory data)
    {
        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] = SetConfigParam({ eid: dstEid, configType: CONFIG_TYPE_ULN, config: _uln(OP_LZLABS_DVN) });
        return (ENDPOINT, abi.encodeCall(IMessageLibManager.setConfig, (module, OP_SEND_ULN, params)));
    }

    /// endpoint.setConfig calldata for the dest dispatcher's RECEIVE ULN from OP (`srcEid = OP_EID`).
    function destReceiveConfig(address dispatcher, uint256 chainId)
        internal
        pure
        returns (address target, bytes memory data)
    {
        (address lib, address dvn) = _destLibDvn(chainId);
        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] = SetConfigParam({ eid: OP_EID, configType: CONFIG_TYPE_ULN, config: _uln(dvn) });
        return (ENDPOINT, abi.encodeCall(IMessageLibManager.setConfig, (dispatcher, lib, params)));
    }

    function _uln(address dvn) private pure returns (bytes memory) {
        address[] memory req = new address[](1);
        req[0] = dvn;
        return abi.encode(UlnConfig(CONFIRMATIONS, 1, 0, 0, req, new address[](0)));
    }

    function _destLibDvn(uint256 chainId) private pure returns (address lib, address dvn) {
        if (chainId == 204) return (OPBNB_RECEIVE_ULN, OPBNB_LZLABS_DVN);
        if (chainId == 196) return (XLAYER_RECEIVE_ULN, XLAYER_LZLABS_DVN);
        revert("no custom receive DVN pathway for this chain");
    }
}
