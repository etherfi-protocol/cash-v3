// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IHopV2
 * @notice Interface for the Frax Hop V2 cross-chain bridge on L2 (Scroll)
 * @dev For the mainnet Hop contract, use IFraxRemoteHop instead
 */
interface IHopV2 {
    function sendOFT(address oft, uint32 dstEid, bytes32 recipient, uint256 amount) external payable;
    function quote(address oft, uint32 dstEid, bytes32 recipient, uint256 amount, uint128 dstGas, bytes calldata data) external view returns (uint256);
}
