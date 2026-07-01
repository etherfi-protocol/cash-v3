// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { ILayerZeroEndpointV2, MessagingParams, MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import { AssetRecoveryModule } from "../../../src/modules/recovery/AssetRecoveryModule.sol";
import { RecoveryMessageLib } from "../../../src/libraries/RecoveryMessageLib.sol";

/**
 * @title RecoverySourceForkOpBnbXLayer
 * @notice Source-side (Optimism) fork test for adding opBNB (204, EID 30202) and X-Layer
 *         (196, EID 30274) as recovery destinations.
 *
 *         The recovery OApps ride LayerZero's *default* send/receive config (no setConfig
 *         anywhere), so a `quote` that returns a non-zero native fee on the real OP endpoint is
 *         direct evidence the OP→dest pathway's default send library exists. This is the only
 *         chain-specific source-side risk; the dest-side lazy-deploy + sweep is chain-agnostic
 *         and proven by the Polygon dest fork harness (RecoveryDestForkBase, which forks real
 *         dest-chain state). A failing quote here means LZ default config is missing for that EID
 *         and a setConfig bundle is required before launch.
 *
 * Run:  OPTIMISM_RPC=<url> forge test --match-contract RecoverySourceForkOpBnbXLayer -vvv
 *       FORK_BLOCK=0 forks at latest (use a non-archival public RPC for a quick check).
 */
contract RecoverySourceForkOpBnbXLayer is Test {
    using stdJson for string;

    uint32 internal constant OPBNB_EID  = 30202;
    uint32 internal constant XLAYER_EID = 30274;
    // Singleton dispatcher — same CREATE3 address on every destination chain.
    address internal constant DISPATCHER = 0x418e0af7c750Ba5cbffC5C2a8398591755926A29;

    AssetRecoveryModule internal module;

    function setUp() public {
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork("optimism");
        else vm.createSelectFork("optimism", pin);

        require(block.chainid == 10, "not Optimism");
        string memory path = string.concat(vm.projectRoot(), "/deployments/mainnet/10/deployments.json");
        string memory json = vm.readFile(path);
        module = AssetRecoveryModule(json.readAddress(".addresses.AssetRecoveryModule"));
        assertTrue(address(module).code.length > 0, "AssetRecoveryModule not deployed on OP");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // LAUNCH GATE — currently SKIPPED. As of this writing, OP->opBNB (30202) and OP->X-Layer
    // (30274) are NOT quotable on the real OP endpoint: defaultSendLibrary + isSupportedEid are
    // set, but the default DVN/executor config for these pathways is missing, so quote() reverts.
    // (Contrast: OP->Polygon 30109 quotes fine — see RecoverySourceForkOptimism.) Recovery to
    // these chains CANNOT dispatch until LayerZero enables the pathway (assign default DVNs) OR we
    // add an explicit setConfig bundle on the OP module — new operational surface the recovery
    // OApps have never used. Once the pathway is enabled, remove the vm.skip and these become the
    // launch gate (they must pass before the OP-side setPeer 3CP).
    // ─────────────────────────────────────────────────────────────────────────────────────────

    function test_opToOpBnb_pathwayIsQuotable() public {
        vm.skip(true); // BLOCKED: OP->opBNB LZ pathway not enabled (no default DVN/executor config). See note above.
        _assertPathwayQuotable(OPBNB_EID, "OP->opBNB");
    }

    function test_opToXLayer_pathwayIsQuotable() public {
        vm.skip(true); // BLOCKED: OP->X-Layer LZ pathway not enabled (no default DVN/executor config). See note above.
        _assertPathwayQuotable(XLAYER_EID, "OP->X-Layer");
    }

    /// setPeer for each new chain (owner-gated) opens the recover() destEid gate.
    function test_setPeers() public {
        assertEq(module.peers(OPBNB_EID), bytes32(0), "opBNB peer already set?");
        assertEq(module.peers(XLAYER_EID), bytes32(0), "X-Layer peer already set?");

        vm.startPrank(module.owner()); // operating safe
        module.setPeer(OPBNB_EID, _toBytes32(DISPATCHER));
        module.setPeer(XLAYER_EID, _toBytes32(DISPATCHER));
        vm.stopPrank();

        assertEq(module.peers(OPBNB_EID), _toBytes32(DISPATCHER), "opBNB peer not set");
        assertEq(module.peers(XLAYER_EID), _toBytes32(DISPATCHER), "X-Layer peer not set");
    }

    function _assertPathwayQuotable(uint32 destEid, string memory label) internal {
        bytes memory message = RecoveryMessageLib.encode(RecoveryMessageLib.Payload({
            safe: makeAddr("safe"), token: makeAddr("token"), recipient: makeAddr("recipient"), salt: bytes32(uint256(1))
        }));
        // LZ v2 type-3 options: one executor lzReceive option, 500k dest gas (deploy TopUp + sweep).
        bytes memory options = abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), uint128(500_000));

        MessagingParams memory params = MessagingParams({
            dstEid: destEid,
            receiver: _toBytes32(DISPATCHER),
            message: message,
            options: options,
            payInLzToken: false
        });

        ILayerZeroEndpointV2 endpoint = module.endpoint();
        try endpoint.quote(params, address(module)) returns (MessagingFee memory fee) {
            assertGt(fee.nativeFee, 0, string.concat(label, ": quote returned zero native fee"));
        } catch {
            revert(string.concat(label, ": LZ pathway not quotable on the real endpoint - no default send config for this EID; add endpoint.setConfig before launch"));
        }
    }

    function _toBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}
