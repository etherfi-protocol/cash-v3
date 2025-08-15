// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "solady/auth/Ownable.sol";

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
        IWETH(weth).deposit{value: amount}();
        // This is done to emit a transfer event so we can just track WETH transfers to this contract
        IWETH(weth).transfer(address(this), amount);
    }

    /**
     * @notice Deposits all ETH into WETH
     */
    receive() external payable {
        _handleETH(msg.value);
    }
}
