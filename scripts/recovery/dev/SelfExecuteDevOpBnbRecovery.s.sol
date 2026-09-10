// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

/**
 * @notice DEV-ONLY. Manually executes a LayerZero v2 message that the DVN has already verified but
 *         no executor delivered (OP->opBNB, guid 0xde47e73f...). `EndpointV2.lzReceive` is
 *         permissionless once the payload is committed, so any funded opBNB EOA can run it — it
 *         clears the committed payload and calls the dispatcher's `_lzReceive`, which lazy-deploys
 *         the TopUp and sweeps the token to the recipient.
 *
 *         This message is nonce 3, but nonces 1 & 2 (the earlier failed single-DVN test sends on the
 *         same pathway) were never verified, so LZ v2's contiguous-nonce rule blocks execution
 *         (`LZ_InvalidNonce`). We first `skip` the dead nonces as the dispatcher's delegate (the dev
 *         EOA), which advances the lazy inbound nonce past them, then execute nonce 3.
 *
 *         Packet values pulled from LZ Scan (scan.layerzero-api.com) for tx
 *         0xac0ae6b574278fea3c8a5c397c4ccb4060905f3f630b5bce1e43149b90c6d19d.
 *
 * Env: PRIVATE_KEY (must be the dispatcher's delegate — the dev deployer EOA — with opBNB gas)
 * Run: forge script scripts/recovery/dev/SelfExecuteDevOpBnbRecovery.s.sol --rpc-url $OPBNB_RPC --broadcast
 */
struct Origin {
    uint32 srcEid;
    bytes32 sender;
    uint64 nonce;
}

interface IEndpoint {
    function lazyInboundNonce(address _receiver, uint32 _srcEid, bytes32 _sender) external view returns (uint64);
    function skip(address _oapp, uint32 _srcEid, bytes32 _sender, uint64 _nonce) external;
    function lzReceive(
        Origin calldata _origin,
        address _receiver,
        bytes32 _guid,
        bytes calldata _message,
        bytes calldata _extraData
    ) external payable;
}

contract SelfExecuteDevOpBnbRecovery is Script {
    address constant ENDPOINT   = 0x1a44076050125825900e736c501f859c50fE728c;
    uint32  constant OP_EID     = 30111;
    address constant OP_MODULE  = 0xD0134F725b025723f9B5C6acDD0fF8BAacC5E2c6; // dev AssetRecoveryModule (sender)
    address constant DISPATCHER = 0xeB58586Bc0C2D39E0ee83B8218B8Ba3c696B2d8e; // dev AssetRecoveryDispatcher (receiver)
    uint64  constant NONCE      = 3;
    bytes32 constant GUID       = 0xde47e73f1b235f4ea56c01bb1ec90388d48a1cf1baf74d80a4dc322b5abd5cce;

    function run() external {
        require(block.chainid == 204, "run on opBNB");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        // RecoveryMessageLib.encode(safe, token, recipient, salt) — verbatim from the source packet.
        bytes memory message =
            hex"000000000000000000000000c935af774f18310428a5d132968731ac1ca9a305"
            hex"0000000000000000000000009e5aac1ba1a2e6aed6b32689dfcf62a509ca96f3"
            hex"0000000000000000000000009080e9ad688a2fd54c1e524e80028e2820d68628"
            hex"2968c05a40d8dfaf040e235167ab172b4d390d614dae09058748092defe334be";

        bytes32 sender = bytes32(uint256(uint160(OP_MODULE)));
        Origin memory origin = Origin({ srcEid: OP_EID, sender: sender, nonce: NONCE });

        uint64 lazy = IEndpoint(ENDPOINT).lazyInboundNonce(DISPATCHER, OP_EID, sender);
        console.log("lazyInboundNonce before:", lazy);

        vm.startBroadcast(pk);
        // Skip the dead nonces (lazy+1 .. NONCE-1) so the contiguous-nonce check passes. Requires the
        // broadcaster to be the dispatcher's delegate.
        for (uint64 n = lazy + 1; n < NONCE; n++) {
            IEndpoint(ENDPOINT).skip(DISPATCHER, OP_EID, sender, n);
            console.log("skipped dead nonce:", n);
        }
        // value 0: this message carries no native airdrop, only the ERC20 sweep.
        IEndpoint(ENDPOINT).lzReceive(origin, DISPATCHER, GUID, message, "");
        vm.stopBroadcast();

        console.log("Self-executed lzReceive on opBNB dispatcher %s (nonce %s)", DISPATCHER, NONCE);
    }
}
