// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { MockERC20 } from "./MockERC20.sol";

/**
 * @title MockBoringVault
 * @notice Minimal BoringVault stand-in that pulls deposit assets and mints vault shares.
 * @dev The real teller calls `vault.enter`, and the vault is the ERC20 allowance spender.
 *      Keeping that boundary in the mock prevents tests from accidentally approving the
 *      teller instead of the vault.
 */
contract MockBoringVault is MockERC20 {
    using SafeERC20 for IERC20;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20(name_, symbol_, decimals_) { }

    function enter(address from, ERC20 depositAsset, uint256 depositAmount, address to, uint256 shares) external {
        IERC20(address(depositAsset)).safeTransferFrom(from, address(this), depositAmount);
        mint(to, shares);
    }
}
