// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IFraxRemoteHop } from "../../interfaces/IFraxRemoteHop.sol";
import { MessagingFee } from "../../interfaces/IOFT.sol";
import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";

/**
 * @title HopBridgeAdapter
 * @notice Adapter for bridging OFT tokens (e.g. frxUSD) via the Frax Hop V2 hub-and-spoke bridge.
 *         Tokens route through Fraxtal before arriving at the destination chain.
 * @dev Called via delegateCall from TopUpFactory.
 *      additionalData is ABI-encoded as (address hopContract, address oftToken, uint32 destEid)
 *      - hopContract: The Hop V2 router contract
 *      - oftToken: The OFT token address (e.g. frxUSD)
 *      - destEid: LayerZero destination endpoint ID
 * @author ether.fi
 */
contract HopBridgeAdapter is BridgeAdapterBase {
    using SafeERC20 for IERC20;

    event BridgeViaHop(address indexed token, address destRecipient, uint256 amount, uint32 destEid);

    /**
     * @notice Bridges OFT tokens via Hop V2
     * @dev The token parameter is the underlying ERC20. The OFT token wraps it.
     *      Flow: approve underlying → hop.sendOFT(oft, destEid, recipient, amount)
     * @param token The underlying token address held by the factory
     * @param amount Amount to bridge
     * @param destRecipient Recipient on the destination chain
     * @param additionalData ABI-encoded (address hopContract, address oftToken, uint32 destEid)
     */
    function bridge(
        address token,
        uint256 amount,
        address destRecipient,
        uint256, // maxSlippage (unused)
        bytes calldata additionalData
    ) external payable override {
        (address hopContract, address oftToken, uint32 destEid) = abi.decode(additionalData, (address, address, uint32));

        bytes32 recipient = bytes32(uint256(uint160(destRecipient)));

        // Approve the underlying token to the hop contract
        IERC20(token).forceApprove(hopContract, amount);

        // Bridge via Hop V2
        IFraxRemoteHop(hopContract).sendOFT{ value: msg.value }(oftToken, destEid, recipient, amount);

        // Reset approval
        IERC20(token).forceApprove(hopContract, 0);

        emit BridgeViaHop(token, destRecipient, amount, destEid);
    }

    /**
     * @notice Returns the bridge fee for Hop V2
     * @dev Queries the hop contract for the LZ messaging fee
     */
    function getBridgeFee(
        address, // token
        uint256 amount,
        address destRecipient,
        uint256, // maxSlippage
        bytes calldata additionalData
    ) external view override returns (address, uint256) {
        return (ETH, _quote(amount, destRecipient, additionalData));
    }

    function _quote(uint256 amount, address destRecipient, bytes calldata additionalData) internal view returns (uint256) {
        (address hopContract, address oftToken, uint32 destEid) = abi.decode(additionalData, (address, address, uint32));
        MessagingFee memory fee = IFraxRemoteHop(hopContract).quote(oftToken, destEid, bytes32(uint256(uint160(destRecipient))), amount);
        return fee.nativeFee;
    }
}
