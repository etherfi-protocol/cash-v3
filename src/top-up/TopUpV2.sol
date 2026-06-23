// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ITopUpFactory } from "../interfaces/ITopUpFactory.sol";
import { TopUp } from "./TopUp.sol";

/**
 * @title TopUpV2
 * @author ether.fi
 * @notice Beacon-proxy implementation extending `TopUp` with a dispatcher-gated recovery path
 *         for funds stuck on the wrong chain.
 */
contract TopUpV2 is TopUp {
    using SafeERC20 for IERC20;

    /// @notice Dispatcher allowed to trigger `executeRecovery`. Rotated by upgrading the beacon.
    address public immutable DISPATCHER;

    error OnlyDispatcher();
    error InvalidRecipient();
    /// @dev Reverts (rather than no-op) so the LZ packet stays retryable until funds arrive.
    error NoBalanceToRecover();
    /// @notice Supported tokens must use the normal claim path; recovery is for stuck-on-wrong-chain only.
    error OnlyUnsupportedTokens();

    event RecoveryExecuted(address indexed token, address indexed recipient, uint256 amount);

    constructor(address _weth, address _dispatcher) TopUp(_weth) {
        DISPATCHER = _dispatcher;
    }

    /// @notice Sweep the full token balance to recipient. Dispatcher-only.
    function executeRecovery(address token, address recipient) external {
        if (msg.sender != DISPATCHER) revert OnlyDispatcher();
        if (recipient == address(0)) revert InvalidRecipient();
        if (ITopUpFactory(owner()).isTokenSupported(token)) revert OnlyUnsupportedTokens();

        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NoBalanceToRecover();

        IERC20(token).safeTransfer(recipient, amount);
        emit RecoveryExecuted(token, recipient, amount);
    }
}
