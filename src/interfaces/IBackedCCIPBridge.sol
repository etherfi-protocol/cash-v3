// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IBackedCCIPBridge
 * @notice The slice of Backed's CCIP bridge that moves a raw xStock between chains. The bridge pulls the
 *         token from the caller into custody and pays it out on the destination from custody there.
 * @author ether.fi
 */
interface IBackedCCIPBridge {
    /// @notice Sends `amount` of `token` to `tokenReceiver` on the destination chain; the CCIP fee is paid in native
    function send(uint64 destinationChainSelector, bytes32 tokenReceiver, address token, uint256 amount, bytes calldata chainSpecificArgs) external payable returns (bytes32);

    /// @notice The native fee `send` needs for the same arguments
    function getDeliveryFeeCost(uint64 destinationChainSelector, bytes32 tokenReceiver, address token, uint256 amount, bytes calldata chainSpecificArgs) external view returns (uint256);

    /// @notice Bridge id of a registered token, zero if not registered
    function tokenIds(address token) external view returns (uint64);
}
