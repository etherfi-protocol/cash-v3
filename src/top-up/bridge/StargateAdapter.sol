// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { MessagingFee, OFTReceipt, SendParam } from "../../interfaces/IOFT.sol";
import { IStargate, Ticket } from "../../interfaces/IStargate.sol";
import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";

/**
 * @title StargateAdapter
 * @notice Bridge adapter implementation for Stargate Protocol
 * @dev Extends BridgeAdapterBase to provide Stargate-specific bridging functionality
 * @author ether.fi
 */
contract StargateAdapter is BridgeAdapterBase {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted when tokens are bridged through Stargate
     * @param token The address of the token being bridged
     * @param amount The amount of tokens being bridged
     * @param ticket The Stargate bridging ticket containing transaction details
     */
    event BridgeViaStargate(address indexed token, uint256 amount, Ticket ticket);

    /// @notice LayerZero endpoint ID for Scroll network
    // https://docs.layerzero.network/v2/developers/evm/technical-reference/deployed-contracts
    uint32 public constant DEST_EID_SCROLL = 30_214;

    /// @notice Error thrown when the provided Stargate pool doesn't match the token
    error InvalidStargatePool();

    /**
     * @notice Bridges tokens using the Stargate protocol
     * @dev Executes the bridge operation through Stargate's sendToken function
     * @param token The address of the token to bridge
     * @param amount The amount of tokens to bridge
     * @param destRecipient The recipient address on the destination chain
     * @param maxSlippage Maximum allowed slippage in basis points
     * @param additionalData ABI-encoded Stargate pool address
     * @custom:throws InsufficientNativeFee if msg.value is less than required fee
     * @custom:throws InvalidStargatePool if pool token doesn't match input token
     * @custom:throws InsufficientMinAmount if received amount is less than minimum
     */
    function bridge(address token, uint256 amount, address destRecipient, uint256 maxSlippage, bytes calldata additionalData) external payable override {
        address stargatePool = abi.decode(additionalData, (address));
        uint256 minAmount = deductSlippage(amount, maxSlippage);

        (uint256 valueToSend, SendParam memory sendParam, MessagingFee memory messagingFee, address poolToken) = prepareRideBus(stargatePool, amount, destRecipient, minAmount);

        if (address(this).balance < valueToSend) revert InsufficientNativeFee();

        if (poolToken != address(0)) {
            if (poolToken != token) revert InvalidStargatePool();
            IERC20(token).forceApprove(stargatePool, amount);
        }
        (,, Ticket memory ticket) = IStargate(stargatePool).sendToken{ value: valueToSend }(sendParam, messagingFee, payable(address(this)));
        emit BridgeViaStargate(token, amount, ticket);
    }

    // from https://stargateprotocol.gitbook.io/stargate/v/v2-developer-docs/integrate-with-stargate/how-to-swap#ride-the-bus
    /**
     * @notice Prepares parameters for Stargate bridging
     * @dev Implements the "Ride the Bus" pattern from Stargate documentation
     * @param stargate The Stargate pool address
     * @param amount The amount of tokens to bridge
     * @param destRecipient The recipient address on the destination chain
     * @param minAmount Minimum amount to receive after slippage
     * @return valueToSend Total native token value needed for the transaction
     * @return sendParam Stargate bridging parameters
     * @return messagingFee LayerZero messaging fee details
     * @return poolToken Address of the token accepted by the Stargate pool
     * @custom:throws InsufficientMinAmount if expected received amount is below minimum
     */
    function prepareRideBus(address stargate, uint256 amount, address destRecipient, uint256 minAmount) public view returns (uint256 valueToSend, SendParam memory sendParam, MessagingFee memory messagingFee, address poolToken) {
        sendParam = SendParam({ dstEid: DEST_EID_SCROLL, to: bytes32(uint256(uint160(destRecipient))), amountLD: amount, minAmountLD: amount, extraOptions: new bytes(0), composeMsg: new bytes(0), oftCmd: new bytes(1) });

        (,, OFTReceipt memory receipt) = IStargate(stargate).quoteOFT(sendParam);
        sendParam.minAmountLD = receipt.amountReceivedLD;
        if (minAmount > receipt.amountReceivedLD) revert InsufficientMinAmount();

        messagingFee = IStargate(stargate).quoteSend(sendParam, false);
        valueToSend = messagingFee.nativeFee;
        poolToken = IStargate(stargate).token();
        if (poolToken == address(0)) {
            valueToSend += sendParam.amountLD;
        }
    }

    /**
     * @notice Calculates the fee required for bridging through Stargate
     * @dev Returns the native token fee required for the bridge operation
     * @param token Unused in this implementation
     * @param amount The amount of tokens to bridge
     * @param destRecipient The recipient address on the destination chain
     * @param maxSlippage Maximum allowed slippage in basis points
     * @param additionalData ABI-encoded Stargate pool address
     * @return ETH address and the required native token fee amount
     */
    function getBridgeFee(address token, uint256 amount, address destRecipient, uint256 maxSlippage, bytes calldata additionalData) external view override returns (address, uint256) {
        // Silence compiler warning on unused variables.
        token = token;

        address stargatePool = abi.decode(additionalData, (address));
        uint256 minAmount = deductSlippage(amount, maxSlippage);

        (,, MessagingFee memory messagingFee,) = prepareRideBus(stargatePool, amount, destRecipient, minAmount);

        return (ETH, messagingFee.nativeFee);
    }
}
