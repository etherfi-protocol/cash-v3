// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IL1StandardBridge } from "../../interfaces/IL1StandardBridge.sol";
import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";

/**
 * @title OptimismBridgeAdapter
 * @notice Adapter for bridging ERC20 tokens from Ethereum L1 to Optimism L2
 *         via the Optimism L1 Standard Bridge.
 * @dev Called via delegateCall from TopUpFactory. Uses depositERC20To to send
 *      tokens to a specific recipient on Optimism.
 * @author ether.fi
 */
contract OptimismBridgeAdapter is BridgeAdapterBase {
    using SafeERC20 for IERC20;

    /// @notice Optimism L1 Standard Bridge on Ethereum mainnet
    address public constant L1_STANDARD_BRIDGE = 0x99C9fc46f92E8a1c0deC1b1747d010903E884bE1;

    /// @notice Emitted when tokens are bridged to Optimism
    event BridgeToOptimism(address indexed l1Token, address indexed l2Token, address destRecipient, uint256 amount);

    /**
     * @notice Bridges ERC20 tokens from Ethereum L1 to Optimism L2
     * @dev Called via delegateCall from TopUpFactory.
     *      additionalData is ABI-encoded as (address l2Token, uint32 minGasLimit)
     * @param token The L1 token address to bridge
     * @param amount Amount of tokens to bridge
     * @param destRecipient Recipient address on Optimism
     * @param additionalData ABI-encoded (address l2Token, uint32 minGasLimit)
     */
    function bridge(
        address token,
        uint256 amount,
        address destRecipient,
        uint256, // maxSlippage (unused for native bridge)
        bytes calldata additionalData
    ) external payable override {
        (address l2Token, uint32 minGasLimit) = abi.decode(additionalData, (address, uint32));

        IERC20(token).forceApprove(L1_STANDARD_BRIDGE, amount);

        IL1StandardBridge(L1_STANDARD_BRIDGE).depositERC20To(
            token,
            l2Token,
            destRecipient,
            amount,
            minGasLimit,
            ""
        );

        emit BridgeToOptimism(token, l2Token, destRecipient, amount);
    }

    /**
     * @notice Returns the bridge fee for L1 to Optimism
     * @dev No native ETH fee for Optimism native bridge deposits
     */
    function getBridgeFee(
        address, // token
        uint256, // amount
        address, // destRecipient
        uint256, // maxSlippage
        bytes calldata // additionalData
    ) external pure override returns (address, uint256) {
        return (ETH, 0);
    }
}
