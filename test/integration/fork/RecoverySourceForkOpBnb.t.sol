// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { ILayerZeroEndpointV2, MessagingParams, MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import { AssetRecoveryModule } from "../../../src/modules/recovery/AssetRecoveryModule.sol";
import { RecoveryMessageLib } from "../../../src/libraries/RecoveryMessageLib.sol";

/**
 * @title RecoverySourceForkOpBnb
 * @notice Source-side (Optimism) fork test for adding opBNB (204, EID 30202) as a recovery destination.
 *
 *         opBNB has no LZ default DVN pathway to/from OP, so the OApp must pin the LZ Labs DVN via
 *         setConfig — that path is proven separately by `RecoverySetConfigProbe` (quote succeeds once
 *         the module's send config is set through `RecoverySetConfigLib`). The default-pathway quote
 *         below stays skipped as documentation of why setConfig is required.
 *
 * Run:  OPTIMISM_RPC=<url> forge test --match-contract RecoverySourceForkOpBnb -vvv
 *       FORK_BLOCK=0 forks at latest (use a non-archival public RPC for a quick check).
 */
contract RecoverySourceForkOpBnb is Test {
    using stdJson for string;

    uint32 internal constant OPBNB_EID = 30202;
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

    // DEFAULT pathway is not quotable for OP->opBNB (no default DVN/executor config) — this is exactly
    // why the launch pins the LZ Labs DVN via setConfig. Proven quotable-after-setConfig by
    // RecoverySetConfigProbe. Kept skipped as documentation of the default-pathway gap.
    function test_opToOpBnb_defaultPathwayIsQuotable() public {
        vm.skip(true); // BLOCKED without setConfig; see RecoverySetConfigProbe for the setConfig path.
        _assertPathwayQuotable(OPBNB_EID, "OP->opBNB");
    }

    /// setPeer (owner-gated) opens the recover() destEid gate.
    function test_setPeer() public {
        assertEq(module.peers(OPBNB_EID), bytes32(0), "opBNB peer already set?");

        vm.prank(module.owner()); // operating safe
        module.setPeer(OPBNB_EID, _toBytes32(DISPATCHER));

        assertEq(module.peers(OPBNB_EID), _toBytes32(DISPATCHER), "opBNB peer not set");
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
            revert(string.concat(label, ": LZ pathway not quotable - add endpoint.setConfig (RecoverySetConfigLib) before launch"));
        }
    }

    function _toBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}
