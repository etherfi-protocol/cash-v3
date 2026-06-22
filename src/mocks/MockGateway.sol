// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IGateway } from "../interfaces/IGateway.sol";

/**
 * @title MockGateway
 * @notice Test double for IGateway. Lets cash-side tests drive a safe's position state directly,
 *         with no live Aave v4 instance, and records the last call to each mutating op for
 *         assertions. Not for production.
 */
contract MockGateway is IGateway {
    /// @notice Recorded arguments of a mutating gateway call (`to` is zero for supply/repay)
    struct Call {
        address safe;
        address asset;
        uint256 amount;
        address to;
    }

    mapping(address => AccountData) internal _accountData;
    mapping(address => mapping(address => bool)) public usingAsCollateral;

    Call public lastSupply;
    Call public lastWithdraw;
    Call public lastBorrow;
    Call public lastRepay;

    /// @notice Sets the account data a subsequent `getAccountData(safe)` will return
    function setAccountData(address safe, AccountData calldata data) external {
        _accountData[safe] = data;
    }

    function supply(address safe, address asset, uint256 amount) external {
        lastSupply = Call(safe, asset, amount, address(0));
    }

    function withdraw(address safe, address asset, uint256 amount, address to) external {
        lastWithdraw = Call(safe, asset, amount, to);
    }

    function borrow(address safe, address asset, uint256 amount, address to) external {
        lastBorrow = Call(safe, asset, amount, to);
    }

    function repay(address safe, address asset, uint256 amount) external returns (uint256) {
        lastRepay = Call(safe, asset, amount, address(0));
        return amount;
    }

    function setUsingAsCollateral(address safe, address asset, bool useAsCollateral) external {
        usingAsCollateral[safe][asset] = useAsCollateral;
    }

    function getAccountData(address safe) external view returns (AccountData memory) {
        return _accountData[safe];
    }
}
