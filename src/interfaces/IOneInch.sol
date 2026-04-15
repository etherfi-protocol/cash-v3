// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title 1inch interfaces for OneInchSwapModule
/// @dev Minimal interfaces for both Classic (DEX aggregation) and Fusion (RFQ/intent) swaps

/// @notice EIP-1271 interface for smart contract signature validation
interface IERC1271 {
    /// @notice Validates a signature for a given hash
    /// @param hash The hash that was signed
    /// @param signature The signature bytes
    /// @return magicValue 0x1626ba7e if valid, any other value if invalid
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

/// @notice 1inch Aggregation Router SwapDescription for classic (DEX) swaps
/// @dev Matches the SwapDescription struct in the 1inch v6 router's swap() function
struct OneInchSwapDescription {
    IERC20 srcToken;
    IERC20 dstToken;
    address payable srcReceiver;
    address payable dstReceiver;
    uint256 amount;
    uint256 minReturnAmount;
    uint256 flags;
}
