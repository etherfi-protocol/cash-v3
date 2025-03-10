// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import {Constants} from "../../utils/Constants.sol";

/**
 * @title BridgeAdapterBase
 * @notice Base contract for bridge adapter implementations
 * @dev Abstract contract providing common bridge adapter functionality
 * @author ether.fi
 */
abstract contract BridgeAdapterBase is Constants {
    using Math for uint256;

    /// @notice Error thrown when provided native token fee is insufficient
    error InsufficientNativeFee();

    /// @notice Error thrown when received amount is less than minimum required
    error InsufficientMinAmount();

    /**
     * @notice Calculates the minimum amount after applying slippage
     * @dev Uses basis points for slippage calculation (100% = 10000 bps)
     * @param amount The original amount
     * @param slippage The maximum allowed slippage in basis points
     * @return The minimum amount after slippage deduction
     */
    function deductSlippage(uint256 amount, uint256 slippage) internal pure returns (uint256) {
        return amount.mulDiv(10_000 - slippage, 10_000);
    }

    /**
     * @notice Bridges tokens to the destination chain
     * @dev Must be implemented by specific bridge adapters
     * @param token The address of the token to bridge
     * @param amount The amount of tokens to bridge
     * @param destRecipient The recipient address on the destination chain
     * @param maxSlippage Maximum allowed slippage in basis points
     * @param additionalData Bridge-specific data required for the operation
     */
    function bridge(address token, uint256 amount, address destRecipient, uint256 maxSlippage, bytes calldata additionalData) external payable virtual;

    /**
     * @notice Calculates the fee required for bridging
     * @dev Must be implemented by specific bridge adapters
     * @param token The address of the token to bridge
     * @param amount The amount of tokens to bridge
     * @param destRecipient The recipient address on the destination chain
     * @param maxSlippage Maximum allowed slippage in basis points
     * @param additionalData Bridge-specific data required for the calculation
     * @return Token address and amount of the required fee
     */
    function getBridgeFee(address token, uint256 amount, address destRecipient, uint256 maxSlippage, bytes calldata additionalData) external view virtual returns (address, uint256);
}
