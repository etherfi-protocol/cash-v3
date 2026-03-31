// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IL1StandardBridge
 * @notice Interface for the Optimism L1 Standard Bridge contract
 */
interface IL1StandardBridge {
    /**
     * @notice Deposits an amount of ERC20 tokens into a target account on L2.
     * @param _l1Token     Address of the L1 token being deposited.
     * @param _l2Token     Address of the corresponding L2 token.
     * @param _amount      Amount of the ERC20 to deposit.
     * @param _minGasLimit Minimum gas limit for the deposit message on L2.
     * @param _extraData   Optional data to forward to L2.
     */
    function depositERC20(
        address _l1Token,
        address _l2Token,
        uint256 _amount,
        uint32 _minGasLimit,
        bytes calldata _extraData
    ) external;

    /**
     * @notice Deposits an amount of ERC20 tokens to a specified recipient on L2.
     * @param _l1Token     Address of the L1 token being deposited.
     * @param _l2Token     Address of the corresponding L2 token.
     * @param _to          Recipient address on L2.
     * @param _amount      Amount of the ERC20 to deposit.
     * @param _minGasLimit Minimum gas limit for the deposit message on L2.
     * @param _extraData   Optional data to forward to L2.
     */
    function depositERC20To(
        address _l1Token,
        address _l2Token,
        address _to,
        uint256 _amount,
        uint32 _minGasLimit,
        bytes calldata _extraData
    ) external;
}
