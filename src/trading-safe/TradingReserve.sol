// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ITradingSafeFactory } from "../interfaces/ITradingSafeFactory.sol";
import { Constants } from "../utils/Constants.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title TradingReserve
 * @author ether.fi
 * @notice Reserve that provides instant credit to user TradingSafes on "Send to Trading" —
 *         funds appear immediately on the destination chain while rebalancing happens in the
 *         background.
 */
contract TradingReserve is UpgradeableProxy, Constants {
    using SafeERC20 for IERC20;

    /// @notice Role allowed to release reserve funds to a user TradingSafe (held by the BE
    ///         service that observes "Send to Trading" requests on OP).
    bytes32 public constant TRADING_RESERVE_RELEASE_ROLE = keccak256("TRADING_RESERVE_RELEASE_ROLE");

    /// @notice TradingSafe factory used to resolve `sourceSafe → tradingSafe` and verify
    ///         that the destination is a registered TradingSafe.
    ITradingSafeFactory public immutable tradingSafeFactory;

    /// @notice Emitted when reserve funds are released to a user's TradingSafe.
    /// @param token ERC20 released.
    /// @param sourceSafe Source-chain (OP) safe that drove the destination derivation.
    /// @param tradingSafe Destination TradingSafe that received the funds.
    /// @param amount Amount of `token` transferred.
    event FundsReleased(address indexed token, address indexed sourceSafe, address indexed tradingSafe, uint256 amount);

    /// @notice Emitted when the role-registry owner withdraws funds from the reserve.
    /// @param token Token withdrawn (`ETH` sentinel for native).
    /// @param recipient Address that received the funds.
    /// @param amount Amount withdrawn.
    event FundsWithdrawn(address indexed token, address indexed recipient, uint256 amount);

    /// @notice Reverts when `releaseFunds` is called by an account lacking
    ///         `TRADING_RESERVE_RELEASE_ROLE`.
    error OnlyReleaseRole();

    /// @notice Reverts when `releaseFunds` is called with a zero amount.
    error InvalidAmount();

    /// @notice Reverts when the derived destination isn't a registered TradingSafe.
    /// @param tradingSafe The deterministic address that's missing from the factory's set.
    error InvalidTradingSafe(address tradingSafe);

    /// @notice Reverts when `withdrawFunds` is called with the zero-address recipient.
    error InvalidRecipient();

    /// @notice Reverts when `withdrawFunds` resolves to a zero balance / amount.
    error CannotWithdrawZeroAmount();

    /// @notice Reverts when an ETH withdrawal `call` returns false.
    error WithdrawFundsFailed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _tradingSafeFactory) {
        tradingSafeFactory = ITradingSafeFactory(_tradingSafeFactory);
        _disableInitializers();
    }

    /**
     * @notice Initialises the proxy.
     * @param _roleRegistry Role registry used for release authorisation, pause control, and
     *        upgrade authority.
     */
    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
    }

    /**
     * @notice Releases `amount` of `token` to the TradingSafe deterministically derived from
     *         `sourceSafe`. Reverts if the destination isn't a TradingSafe registered with
     *         the factory.
     * @dev Caller (BE release service) MUST ensure the TradingSafe is deployed first — the
     *      registration check is what prevents this role from routing funds to arbitrary
     *      addresses. Any ERC20 is accepted; allowlisting is enforced upstream (the
     *      operator only calls `releaseFunds` for tokens the protocol supports).
     * @param token ERC20 to release.
     * @param sourceSafe Source-chain (OP) safe that identifies the user. The destination is
     *        derived from this via `tradingSafeFactory.getDeterministicAddress`.
     * @param amount Amount of `token` to transfer.
     * @custom:throws OnlyReleaseRole If caller lacks `TRADING_RESERVE_RELEASE_ROLE`.
     * @custom:throws InvalidAmount If `amount == 0`.
     * @custom:throws InvalidTradingSafe If the derived address isn't a registered TradingSafe.
     */
    function releaseFunds(address token, address sourceSafe, uint256 amount) external whenNotPaused {
        if (!roleRegistry().hasRole(TRADING_RESERVE_RELEASE_ROLE, msg.sender)) revert OnlyReleaseRole();
        if (amount == 0) revert InvalidAmount();

        address tradingSafe = tradingSafeFactory.getDeterministicAddress(sourceSafe);
        if (!tradingSafeFactory.isEtherFiSafe(tradingSafe)) revert InvalidTradingSafe(tradingSafe);

        IERC20(token).safeTransfer(tradingSafe, amount);
        emit FundsReleased(token, sourceSafe, tradingSafe, amount);
    }

    /**
     * @notice Withdraws `amount` of `token` from the reserve to `recipient`. Role-registry
     *         owner only — escape hatch for treasury rebalancing, misrouted-asset rescue,
     *         and end-of-life drain.
     * @dev `token == ETH` (the constant) withdraws native value. Pass `amount = 0` to drain
     *      the full balance of that asset.
     * @param token ERC20 to withdraw, or the `ETH` sentinel for native value.
     * @param recipient Destination of the withdrawn funds.
     * @param amount Amount to withdraw; `0` = full balance.
     * @custom:throws OnlyRoleRegistryOwner If `msg.sender` isn't the role registry owner.
     * @custom:throws InvalidRecipient If `recipient == address(0)`.
     * @custom:throws CannotWithdrawZeroAmount If the resolved amount is zero.
     * @custom:throws WithdrawFundsFailed If the ETH transfer fails.
     */
    function withdrawFunds(address token, address recipient, uint256 amount) external nonReentrant onlyRoleRegistryOwner {
        if (recipient == address(0)) revert InvalidRecipient();

        if (token == ETH) {
            if (amount == 0) amount = address(this).balance;
            if (amount == 0) revert CannotWithdrawZeroAmount();
            (bool ok, ) = payable(recipient).call{ value: amount }("");
            if (!ok) revert WithdrawFundsFailed();
        } else {
            if (amount == 0) amount = IERC20(token).balanceOf(address(this));
            if (amount == 0) revert CannotWithdrawZeroAmount();
            IERC20(token).safeTransfer(recipient, amount);
        }

        emit FundsWithdrawn(token, recipient, amount);
    }

    /// @notice Allows the reserve to receive native value.
    receive() external payable {}
}
