// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessagingParams, MessagingFee, MessagingReceipt } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/**
 * @title LZEndpointMock
 * @notice Minimal mock of ILayerZeroEndpointV2 for unit tests — implements only the
 *         selectors actually invoked by OAppCoreUpgradeable / OAppSenderUpgradeable.
 * @dev Intentionally does NOT inherit ILayerZeroEndpointV2 so we don't have to stub
 *      every getter from the full interface. The module stores `endpoint` as an
 *      ILayerZeroEndpointV2 — casts to that type are compile-time only; at runtime
 *      the dispatch is by selector against this mock's bytecode.
 */
contract LZEndpointMock {
    mapping(address oapp => address delegate) public delegates;

    // Recorded send args. Stored as plain fields (not the `MessagingParams` struct) so we can
    // expose `bytes memory` getters without hitting auto-generated struct-return issues.
    uint32 public lastDstEid;
    bytes32 public lastReceiver;
    bytes public lastMessage;
    bytes public lastOptions;
    bool public lastPayInLzToken;
    address public lastRefundAddress;
    uint64 public sendNonce;

    /// @notice Returns the dstEid and message from the most recent `send` call.
    /// @dev Tests use this to assert what the OApp dispatched.
    function lastSendArgs() external view returns (uint32 dstEid, bytes memory message) {
        return (lastDstEid, lastMessage);
    }

    /// @notice Records the delegate for an OApp; called by OAppCore __OAppCore_init
    function setDelegate(address _delegate) external {
        delegates[msg.sender] = _delegate;
    }

    /// @notice Stub quote — returns (0, 0) so upstream code does not revert
    function quote(MessagingParams calldata /*_params*/, address /*_sender*/) external pure returns (MessagingFee memory) {
        return MessagingFee({ nativeFee: 0, lzTokenFee: 0 });
    }

    /// @notice Stub send — records the last send and returns a deterministic receipt
    function send(MessagingParams calldata _params, address _refundAddress) external payable returns (MessagingReceipt memory) {
        lastDstEid = _params.dstEid;
        lastReceiver = _params.receiver;
        lastMessage = _params.message;
        lastOptions = _params.options;
        lastPayInLzToken = _params.payInLzToken;
        lastRefundAddress = _refundAddress;

        unchecked {
            sendNonce += 1;
        }

        return MessagingReceipt({
            guid: keccak256(abi.encode(address(this), msg.sender, sendNonce)),
            nonce: sendNonce,
            fee: MessagingFee({ nativeFee: msg.value, lzTokenFee: 0 })
        });
    }

    /// @notice Required by OAppSender._payLzToken; returns zero address so LZ token payment path is guarded externally
    function lzToken() external pure returns (address) {
        return address(0);
    }
}
