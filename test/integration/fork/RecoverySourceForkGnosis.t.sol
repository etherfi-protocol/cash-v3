// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { ILayerZeroEndpointV2, MessagingParams, MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import { AssetRecoveryModule } from "../../../src/modules/recovery/AssetRecoveryModule.sol";
import { RecoveryMessageLib } from "../../../src/libraries/RecoveryMessageLib.sol";

/**
 * @title RecoverySourceForkGnosis
 * @notice Source-side (Optimism) fork test for adding Gnosis (chainId 100, EID 30145) as a
 *         recovery destination.
 *
 *         Unlike opBNB/X-Layer, the OP→Gnosis default ULN config carries two real DVNs (identical
 *         to the live OP→Polygon pathway), so the pathway is enabled and `quote` returns a fee.
 *         This test is therefore NOT skipped — it is the launch gate that must stay green. If it
 *         ever reverts, LayerZero has changed the Gnosis default config.
 *
 * Run:  OPTIMISM_RPC=<url> forge test --match-contract RecoverySourceForkGnosis -vvv
 *       FORK_BLOCK=0 forks at latest (use a non-archival public RPC for a quick check).
 */
contract RecoverySourceForkGnosis is Test {
    using stdJson for string;

    uint32 internal constant GNOSIS_EID = 30145;
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

    /// The OP→Gnosis pathway must be quotable on the real endpoint, else recover() can't dispatch.
    function test_opToGnosis_pathwayIsQuotable() public {
        bytes memory message = RecoveryMessageLib.encode(RecoveryMessageLib.Payload({
            safe: makeAddr("safe"), token: makeAddr("token"), recipient: makeAddr("recipient"), salt: bytes32(uint256(1))
        }));
        // LZ v2 type-3 options: one executor lzReceive option, 500k dest gas (deploy TopUp + sweep).
        bytes memory options = abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), uint128(500_000));

        MessagingParams memory params = MessagingParams({
            dstEid: GNOSIS_EID,
            receiver: _toBytes32(DISPATCHER),
            message: message,
            options: options,
            payInLzToken: false
        });

        ILayerZeroEndpointV2 endpoint = module.endpoint();
        try endpoint.quote(params, address(module)) returns (MessagingFee memory fee) {
            assertGt(fee.nativeFee, 0, "OP->Gnosis quote returned zero native fee");
        } catch {
            revert("OP->Gnosis LZ pathway not quotable - default config changed; check DVN set for EID 30145");
        }
    }

    /// setPeer for Gnosis (owner-gated) opens the recover() destEid gate.
    function test_setGnosisPeer() public {
        assertEq(module.peers(GNOSIS_EID), bytes32(0), "Gnosis peer already set?");

        vm.prank(module.owner()); // operating safe
        module.setPeer(GNOSIS_EID, _toBytes32(DISPATCHER));

        assertEq(module.peers(GNOSIS_EID), _toBytes32(DISPATCHER), "Gnosis peer not set");
    }

    function _toBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}
