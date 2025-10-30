// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ICCTPTokenMessenger
 * @notice Interface for Circle CCTP TokenMessenger contract
 * @dev Based on Circle's TokenMessengerV2 contract for bridging tokens via CCTP
 * @author ether.fi
 */
interface ICCTPTokenMessenger {
    /**
     * @notice Deposits and burns tokens from sender to be minted on destination domain.
     * @param amount amount of tokens to burn
     * @param destinationDomain destination domain to receive message on
     * @param mintRecipient address of mint recipient on destination domain
     * @param burnToken token to burn `amount` of, on local domain
     * @param destinationCaller authorized caller on the destination domain, as bytes32. If equal to bytes32(0),
     * any address can broadcast the message.
     * @param maxFee maximum fee to pay on the destination domain, specified in units of burnToken
     * @param minFinalityThreshold the minimum finality at which a burn message will be attested to.
     */
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;
}
