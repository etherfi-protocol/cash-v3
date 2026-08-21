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
    /// @notice Reverts when `redirectToTradingSafe` or `unwrap` is called with zero amount.
    error InvalidAmount();
    /// @notice Reverts when `unwrap` names a vault the factory has not registered.
    error VaultNotUnwrappable();

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
     *      this contract, and the allowance is granted per call and zeroed after — no standing
     *      approval survives, and a vault that pulls less than `amount` leaves no remainder
     *      behind to spend. The factory validated the pairing when it configured the wrapper, so
     *      the approve/deposit target is never an arbitrary address.
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

        IERC20(token).forceApprove(wrapper, amount);
        IERC4626(wrapper).deposit(amount, tradingSafe);
        IERC20(token).forceApprove(wrapper, 0);
    }

    /**
     * @notice Redeems `amount` of an ERC-4626 `vault` this TopUp holds into the vault's underlying,
     *         credited back to this same contract.
     *
     * @dev The mirror of the wrap leg above, and configuration in the same way: which vaults may be
     *      redeemed, and what each pays out, is read from the factory's `unwrapAssetFor(vault)`
     *      rather than taken as an argument, so this contract stays free of per-vault state and the
     *      redemption target is never an arbitrary address.
     *
     *      Why the proceeds stay here rather than going to the factory: a wrapped form reaching a
     *      TopUp has no topup configuration of its own, and the sweep only accepts tokens this
     *      factory bridges — so the wrapped form can never leave as itself. Redeeming in place turns
     *      it into the underlying, which IS a configured topup asset, and the ordinary sweep then
     *      moves it along with everything else. Nothing here needs to know about bridging.
     *
     *      No approval leg at all, unlike the wrap: this contract is both the shares' owner and the
     *      caller, so ERC-4626 `redeem` needs no allowance and leaves none behind.
     *
     * @param vault ERC-4626 vault to redeem — always a vault this TopUp holds shares of.
     * @param amount Amount of vault shares to redeem.
     * @custom:throws OnlyOwner If caller is not the owner.
     * @custom:throws InvalidAmount If `amount == 0`.
     * @custom:throws VaultNotUnwrappable If the factory has not registered `vault`.
     */
    function unwrap(address vault, uint256 amount) external {
        address _owner = owner();
        if (_owner != msg.sender) revert OnlyOwner();
        if (amount == 0) revert InvalidAmount();

        if (ITopUpFactory(_owner).unwrapAssetFor(vault) == address(0)) revert VaultNotUnwrappable();

        IERC4626(vault).redeem(amount, address(this), address(this));
    }

    /**
     * @notice Deposits all ETH into WETH
     */
    receive() external payable {
        _handleETH(msg.value);
    }
}
