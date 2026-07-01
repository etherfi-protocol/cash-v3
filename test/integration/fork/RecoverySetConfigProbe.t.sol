// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { ILayerZeroEndpointV2, MessagingParams, MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";

import { AssetRecoveryModule } from "../../../src/modules/recovery/AssetRecoveryModule.sol";
import { RecoveryMessageLib } from "../../../src/libraries/RecoveryMessageLib.sol";
import { RecoverySetConfigLib } from "../../../scripts/recovery/RecoverySetConfigLib.sol";

/// Local mirror of UlnBase.UlnConfig (same field order/types) for abi.encode.
struct UlnConfig {
    uint64 confirmations;
    uint8 requiredDVNCount;
    uint8 optionalDVNCount;
    uint8 optionalDVNThreshold;
    address[] requiredDVNs;
    address[] optionalDVNs;
}

/**
 * @title RecoverySetConfigProbe
 * @notice Answers definitively: if we `setConfig` the OP AssetRecoveryModule's SEND ULN config with
 *         the LZ Labs OP DVN, does `quote()` for OP→opBNB (30202) / OP→X-Layer (30274) succeed?
 *
 *         This is the real test of whether `setConfig` unblocks these routes — i.e. whether the
 *         LZ Labs OP-side DVN actually covers the destination (can price the route). A passing
 *         quote means: deploy + setConfig + 3CP and the chain works. A revert means the DVN does
 *         not serve the route and `setConfig` alone is insufficient (needs LZ-side onboarding).
 *
 * Run:  OPTIMISM_RPC=<url> FORK_BLOCK=0 forge test --match-contract RecoverySetConfigProbe -vvv
 */
contract RecoverySetConfigProbe is Test {
    using stdJson for string;

    address constant ENDPOINT  = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant SEND_ULN  = 0x1322871e4ab09Bc7f5717189434f97bBD9546e95; // SendUln302 (OP)
    address constant LZ_DVN_OP = 0x6A02D83e8d433304bba74EF1c427913958187142; // LayerZero Labs DVN (OP)
    address constant DISPATCHER = 0x418e0af7c750Ba5cbffC5C2a8398591755926A29;
    // Module's LZ delegate (confirmed via endpoint.delegates(module)) = operating safe.
    address constant DELEGATE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    uint32  constant CONFIG_TYPE_ULN = 2;

    AssetRecoveryModule internal module;

    function setUp() public {
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork("optimism");
        else vm.createSelectFork("optimism", pin);
        require(block.chainid == 10, "not Optimism");

        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet/10/deployments.json"));
        module = AssetRecoveryModule(json.readAddress(".addresses.AssetRecoveryModule"));
    }

    function test_opToOpBnb_quotableAfterSetConfig() public {
        _setSendDvn(30202);
        _assertQuotable(30202, "OP->opBNB");
    }

    function test_opToXLayer_quotableAfterSetConfig() public {
        _setSendDvn(30274);
        _assertQuotable(30274, "OP->X-Layer");
    }

    /// setConfig the module's SEND ULN config for `dstEid` via RecoverySetConfigLib — this proves the
    /// production 3CP calldata (not a test-local copy) makes the route quotable.
    function _setSendDvn(uint32 dstEid) internal {
        (address target, bytes memory data) = RecoverySetConfigLib.opSendConfig(address(module), dstEid);
        vm.prank(DELEGATE);
        (bool ok, ) = target.call(data);
        require(ok, "RecoverySetConfigLib.opSendConfig setConfig reverted");
    }

    function _assertQuotable(uint32 dstEid, string memory label) internal {
        bytes memory message = RecoveryMessageLib.encode(RecoveryMessageLib.Payload({
            safe: makeAddr("safe"), token: makeAddr("token"), recipient: makeAddr("recipient"), salt: bytes32(uint256(1))
        }));
        bytes memory options = abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), uint128(500_000));
        MessagingParams memory p = MessagingParams({
            dstEid: dstEid, receiver: bytes32(uint256(uint160(DISPATCHER))), message: message, options: options, payInLzToken: false
        });

        try ILayerZeroEndpointV2(ENDPOINT).quote(p, address(module)) returns (MessagingFee memory fee) {
            console.log("%s quotable after setConfig - nativeFee:", label);
            console.log(fee.nativeFee);
            assertGt(fee.nativeFee, 0, string.concat(label, ": zero fee"));
        } catch {
            revert(string.concat(label, ": STILL reverts after setConfig - LZ Labs OP DVN does not cover this route"));
        }
    }
}
