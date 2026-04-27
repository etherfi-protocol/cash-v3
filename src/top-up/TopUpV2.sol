// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { TopUp } from "./TopUp.sol";

interface ITopUpFactoryView {
    function isTokenSupported(address token) external view returns (bool);
}

/**
 * @title TopUpV2
 * @author ether.fi
 * @notice Beacon-proxy implementation that extends `TopUp` with a dispatcher-gated
 *         recovery path for funds that landed on the wrong destination chain.
 * @dev Deployed as a new beacon implementation; existing per-user TopUp proxies
 *      keep their owner/storage and gain `executeRecovery` via the beacon upgrade.
 *      Because the proxy and its user's EtherFi Safe share the same CREATE3 address
 *      (enforced by deployment tooling), the `RecoveryModule` on Optimism proves
 *      authority by checking Safe multisig; the `RecoveryDispatcher` on this chain
 *      simply forwards to `address = safe`. No on-chain CREATE3 parity check here.
 */
contract TopUpV2 is TopUp {
    using SafeERC20 for IERC20;

    /// @notice Singleton dispatcher allowed to trigger `executeRecovery`. Immutable per impl version;
    ///         rotate by upgrading the beacon to a new `TopUpV2` deployment.
    address public immutable DISPATCHER;

    /// @notice Thrown when a non-dispatcher tries to call `executeRecovery`.
    error OnlyDispatcher();
    /// @notice Thrown when `recipient` is the zero address.
    error InvalidRecipient();
    /// @notice Thrown when `amount` is zero.
    error InvalidAmount();
    /// @notice Thrown when `amount` does not equal the contract's full token balance.
    ///         The recovery payload must drain the entire stuck balance — partial recoveries
    ///         and pre-empted dust would leave funds behind.
    error AmountMustEqualBalance();
    /// @notice Thrown when `token` is in the local TopUpFactory's supported-token set.
    ///         Supported tokens have a working bridge route and must be moved through the
    ///         normal claim path; the recovery path is only for funds that landed on a chain
    ///         where the token has no route. Mirrors `TopUpFactory.recoverFunds`.
    error OnlyUnsupportedTokens();

    /// @notice Emitted when a stuck-funds recovery transfer succeeds.
    event RecoveryExecuted(address indexed token, address indexed recipient, uint256 amount);

    constructor(address _weth, address _dispatcher) TopUp(_weth) {
        DISPATCHER = _dispatcher;
    }

    /**
     * @notice Transfers stuck ERC20 funds to a user-chosen recipient on behalf of the dispatcher.
     * @param token The ERC20 token to release
     * @param amount The amount of `token` to transfer
     * @param recipient The address that will receive the funds on this chain
     * @dev Must only be called by the local `RecoveryDispatcher` (which, in turn, has already
     *      verified the caller's Safe multisig on Optimism inside `RecoveryModule.recover`).
     *      Enforces `amount == balanceOf(token, address(this))` — the recovery payload must
     *      transfer the full stuck balance, no partial drains. Any inbound dust between the
     *      submit on OP and LZ delivery here will brick this call until ops clears the dust.
     * @custom:throws OnlyDispatcher if `msg.sender != DISPATCHER`
     * @custom:throws InvalidRecipient if `recipient` is the zero address
     * @custom:throws InvalidAmount if `amount` is zero
     * @custom:throws OnlyUnsupportedTokens if `token` is a supported bridge asset on this chain
     * @custom:throws AmountMustEqualBalance if `amount != balanceOf(token, address(this))`
     */
    function executeRecovery(address token, uint256 amount, address recipient) external {
        if (msg.sender != DISPATCHER) revert OnlyDispatcher();
        if (recipient == address(0)) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();
        if (ITopUpFactoryView(owner()).isTokenSupported(token)) revert OnlyUnsupportedTokens();
        if (amount != IERC20(token).balanceOf(address(this))) revert AmountMustEqualBalance();

        IERC20(token).safeTransfer(recipient, amount);
        emit RecoveryExecuted(token, recipient, amount);
    }
}
