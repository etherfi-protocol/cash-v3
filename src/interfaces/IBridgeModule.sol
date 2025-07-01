// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IBridgeModule {
    /**
     * @notice Cancels a bridge request by the cash module
     * @dev This function is intended to be called by the cash module to cancel a bridge
     * @param safe Address of the EtherFiSafe
     */
    function cancelBridgeByCashModule(address safe) external;
}