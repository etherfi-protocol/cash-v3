// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "solady/auth/Ownable.sol";

import { ITopUpFactory } from "../interfaces/ITopUpFactory.sol";
import { IWETH } from "../interfaces/IWETH.sol";
import { Constants } from "../utils/Constants.sol";

/**
 * @title TopUp
 * @notice A contract that allows the owner to withdraw both ETH and ERC20 tokens
 * @dev Inherits from Constants for ETH address constant and Solady's Ownable for access control
 * @author ether.fi
 */
contract TopUp is Constants, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Error thrown when non-owner tries to access owner-only functions
    error OnlyOwner();
    /// @notice Error thrown when ETH transfer fails
    error EthTransferFailed();
    /// @notice Reverts when `redirectToTradingSafe` is called with zero amount.
    error InvalidAmount();
    /// @notice Reverts when `wrap` is called for a token the factory has registered no ERC-4626
    ///         wrapper for — there is nothing to deposit into.
    error WrapperNotSet();

    /// @notice Emitted when funds are processed
    /// @param token Address of the token processed
    /// @param amount Amount of the token processed
    event ProcessTopUp(address indexed token, uint256 amount);

    address public immutable weth;

    constructor(address _weth) {
        // initialize with dead so the impl ownership cannot be taken over by someone
        _initializeOwner(address(0xdead));

        weth = _weth;
    }

    /**
     * @notice Initializes the contract with an owner
     * @dev Can only be called once, sets initial owner
     * @param _owner Address that will be granted ownership of the contract
     * @custom:throws AlreadyInitialized if already initialized
     */
    function initialize(address _owner) external {
        if (owner() != address(0)) revert AlreadyInitialized();
        _initializeOwner(_owner);
    }

    /**
     * @notice Allows owner to withdraw multiple tokens including ETH
     * @dev Handles both ETH (using ETH constant) and ERC20 tokens
     * @param tokens Array of token addresses (use ETH constant for ETH)
     * @custom:security Uses a gas limit of 10_000 for ETH transfers to prevent reentrancy
     * @custom:throws OnlyOwner if caller is not the owner
     * @custom:throws EthTransferFailed if ETH transfer fails
     */
    function processTopUp(address[] memory tokens) external {
        address _owner = owner();
        if (_owner != msg.sender) revert OnlyOwner();

        uint256 len = tokens.length;

        for (uint256 i = 0; i < len;) {
            uint256 balance;
            if (tokens[i] == ETH) {
                balance = address(this).balance;
                if (balance > 0) _handleETH(balance);
                
                tokens[i] = weth;
            }

            balance = IERC20(tokens[i]).balanceOf(address(this));
            if (balance > 0) { 
                IERC20(tokens[i]).safeTransfer(_owner, balance);
                emit ProcessTopUp(tokens[i], balance);
            }
            
            unchecked {
                ++i;
            }
        }
    }

    function _handleETH(uint256 amount) internal {
        if (amount > 0) {
            IWETH(weth).deposit{value: amount}();
            // This is done to emit a transfer event so we can just track WETH transfers to this contract
            IWETH(weth).transfer(address(this), amount);
        }
    }

    /**
     * @notice Moves `amount` of `token` from this TopUp to `tradingSafe`. Recovery path
     *         for trading-supported, not-topup-supported tokens (e.g. Ondo SPY) that landed
     *         at the TopUp address by mistake.
     *
     * @dev Whether the token travels as-is or gets wrapped on the way out is configuration, not
     *      a parameter: the factory's `wrapperFor(token)` names the ERC-4626 vault a raw Backed
     *      xStock must be deposited into, because the destination TradingSafe's catalog lists the
     *      wrapper (wTSLAx) and not the raw stock (TSLAx) a user actually sends to a TopUp
     *      address. An unconfigured token — every token today — is the plain transfer this has
     *      always been. Reading the mapping off the owner rather than taking it as an argument
     *      keeps the redirect a single call shape for the backend and this contract free of
     *      per-token state.
     *
     *      On the wrap leg the vault mints straight to `tradingSafe`, so the shares never touch
     *      this contract. The deposit itself is `_wrap`, shared with the in-place `wrap` — the
     *      two differ only in who receives the shares.
     *
     * @param token ERC20 to redirect — always the token this TopUp holds, never its wrapper.
     * @param tradingSafe Destination TradingSafe (resolved and supplied by the factory).
     * @param amount Amount of `token` to move.
     * @custom:throws OnlyOwner If caller is not the owner.
     * @custom:throws InvalidAmount If `amount == 0`.
     */
    function redirectToTradingSafe(address token, address tradingSafe, uint256 amount) external {
        address _owner = owner();
        if (_owner != msg.sender) revert OnlyOwner();
        if (amount == 0) revert InvalidAmount();

        address wrapper = ITopUpFactory(_owner).wrapperFor(token);
        if (wrapper == address(0)) {
            IERC20(token).safeTransfer(tradingSafe, amount);
            return;
        }

        _wrap(token, wrapper, tradingSafe, amount);
    }

    /**
     * @notice Wraps `amount` of `token` into the ERC-4626 wrapper the factory has registered for
     *         it, crediting the shares to this same TopUp.
     *
     * @dev Nothing leaves this contract: the raw Backed xStock (TSLAx) a user sent to their TopUp
     *      address becomes the wrapper (wTSLAx) at that same address, which is the form both the
     *      topup and trading catalogs actually list. The raw stock is listed in neither, so until
     *      it is converted it can be neither swept nor redirected — this is what unsticks it, and
     *      it is deliberately not a transfer of any kind.
     *
     *      Which vault a token may be deposited into is the factory's `wrapperFor(token)`, the
     *      same admin-curated mapping the redirect path reads, so the approve/deposit target is
     *      never an arbitrary address and this contract keeps no per-token state. Unlike the
     *      redirect, a token with no registered wrapper reverts here: there is no as-is fallback
     *      for a wrap, and silently doing nothing would hide the missing registration.
     *
     * @param token Raw ERC20 this TopUp holds — never its wrapper.
     * @param amount Amount of `token` to wrap.
     * @custom:throws OnlyOwner If caller is not the owner.
     * @custom:throws InvalidAmount If `amount == 0`.
     * @custom:throws WrapperNotSet If the factory has no wrapper registered for `token`.
     */
    function wrap(address token, uint256 amount) external {
        address _owner = owner();
        if (_owner != msg.sender) revert OnlyOwner();
        if (amount == 0) revert InvalidAmount();

        address wrapper = ITopUpFactory(_owner).wrapperFor(token);
        if (wrapper == address(0)) revert WrapperNotSet();

        _wrap(token, wrapper, address(this), amount);
    }

    /**
     * @dev The ERC-4626 deposit both wrap paths share: `wrap` passes this contract as `receiver`
     *      and `redirectToTradingSafe` passes the destination safe, and that is the only
     *      difference between them.
     *
     *      The allowance is granted per call and zeroed after, so no standing approval survives
     *      and a vault that pulls less than `amount` leaves no remainder behind to spend. Callers
     *      resolve `wrapper` off the factory's `wrapperFor`, which validated the `asset()` pairing
     *      when it was registered, so the approve/deposit target is never an arbitrary address —
     *      this helper takes it as given and must not be reached with an unvalidated one.
     * @param token Raw ERC20 being deposited.
     * @param wrapper The token's registered ERC-4626 vault. Never the zero address.
     * @param receiver Who the vault mints the shares to.
     * @param amount Amount of `token` to deposit.
     */
    function _wrap(address token, address wrapper, address receiver, uint256 amount) internal {
        IERC20(token).forceApprove(wrapper, amount);
        IERC4626(wrapper).deposit(amount, receiver);
        IERC20(token).forceApprove(wrapper, 0);
    }

    /**
     * @notice Deposits all ETH into WETH
     */
    receive() external payable {
        _handleETH(msg.value);
    }
}
