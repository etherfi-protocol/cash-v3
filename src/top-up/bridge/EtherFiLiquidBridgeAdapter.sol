// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { ILayerZeroTeller } from "../../interfaces/ILayerZeroTeller.sol";
import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";

/**
 * @title EtherFiLiquidBridgeAdapter
 * @author ether.fi
 * @notice This contract implements a bridge adapter for transferring EtherFi Liquid tokens across chains
 * @dev Inherits from BridgeAdapterBase and implements specific bridging logic for EtherFi Liquid tokens
 */
contract EtherFiLiquidBridgeAdapter is BridgeAdapterBase {
    using SafeCast for uint256;

    /**
     * @notice Endpoint ID for Scroll network on LayerZero
     * @dev According to LayerZero documentation: https://docs.layerzero.network/v2/developers/evm/technical-reference/deployed-contracts
     */
    uint32 public constant DEST_EID_SCROLL = 30_214;

    /**
     * @notice Emitted when EtherFi Liquid tokens are successfully bridged
     * @param token Address of the token that was bridged
     * @param destRecipient Address of the recipient on the destination chain
     * @param amount Amount of tokens that were bridged
     * @param destEid Endpoint ID of the destination chain
     */
    event EtherFiLiquidTokenBridged(address indexed token, address indexed destRecipient, uint256 amount, uint32 destEid);
    
    /**
     * @notice Thrown when the provided teller does not match the token's vault
     */
    error InvalidTeller();

    /**
     * @notice Bridges EtherFi Liquid tokens to a destination chain
     * @dev Uses LayerZero Teller for cross-chain bridging
     * @param token Address of the token to bridge
     * @param amount Amount of the token to bridge
     * @param destRecipient Address of the recipient on the destination chain
     * @param maxSlippage Maximum acceptable slippage (not used in this implementation)
     * @param additionalData ABI encoded address of the LayerZero Teller contract
     * @custom:throws InvalidTeller If the teller's vault does not match the token
     * @custom:throws InsufficientNativeFee If not enough ETH is provided for fees
     */
    function bridge(address token, uint256 amount, address destRecipient, uint256 maxSlippage, bytes calldata additionalData) external payable override {
        // Silence compiler warning on unused variables.
        maxSlippage = maxSlippage;

        ILayerZeroTeller teller = ILayerZeroTeller(abi.decode(additionalData, (address)));
        if (address(teller.vault()) != token) revert InvalidTeller();
        
        bytes memory bridgeWildCard = abi.encode(DEST_EID_SCROLL);
        uint96 amount_U96 = amount.toUint96();
        uint256 fee = teller.previewFee(amount_U96, destRecipient, bridgeWildCard, ERC20(ETH));

        if (address(this).balance < fee) revert InsufficientNativeFee();

        teller.bridge{value: fee}(amount_U96, destRecipient, bridgeWildCard, ERC20(ETH), fee);

        emit EtherFiLiquidTokenBridged(token, destRecipient, amount, DEST_EID_SCROLL);
    }

    /**
     * @notice Calculates the fee required for bridging
     * @dev Returns the native token address and fee amount
     * @param token Address of the token to bridge (not used in fee calculation)
     * @param amount Amount of the token to bridge
     * @param destRecipient Address of the recipient on the destination chain
     * @param maxSlippage Maximum acceptable slippage (not used in this implementation)
     * @param additionalData ABI encoded address of the LayerZero Teller contract
     * @return feeToken Address of the token used for fees (ETH)
     * @return feeAmount Amount of fees required for the bridge transaction
     */
    function getBridgeFee(address token, uint256 amount, address destRecipient, uint256 maxSlippage, bytes calldata additionalData) external view override returns (address, uint256) {
        // Silence compiler warning on unused variables.
        token = token;
        maxSlippage = maxSlippage;

        ILayerZeroTeller teller = ILayerZeroTeller(abi.decode(additionalData, (address)));
        bytes memory bridgeWildCard = abi.encode(DEST_EID_SCROLL);
        return (ETH, teller.previewFee(amount.toUint96(), destRecipient, bridgeWildCard, ERC20(ETH)));
    }
}