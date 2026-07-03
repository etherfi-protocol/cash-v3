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
    /// @notice Thrown when the mock is configured to reject borrow calls
    error BorrowBlocked();

    /// @notice Recorded arguments of a mutating gateway call (`to` is zero for supply/repay)
    struct Call {
        address safe;
        address asset;
        uint256 amount;
        address to;
    }

    mapping(address => AccountData) internal _accountData;
    mapping(address => mapping(address => bool)) public usingAsCollateral;
    mapping(address safe => mapping(address asset => uint256)) internal _suppliedOf;
    mapping(address safe => mapping(address asset => uint256)) internal _debtOf;
    mapping(address asset => uint256) internal _availableCash;
    mapping(address asset => uint256) internal _ltv;

    Call public lastSupply;
    Call public lastWithdraw;
    Call public lastBorrow;
    Call public lastRepay;

    /// @notice When set, borrow reverts, to model a blocked borrow (e.g. insufficient Aave collateral)
    bool public borrowReverts;

    /// @notice Toggles the borrow revert
    function setBorrowReverts(bool value) external {
        borrowReverts = value;
    }

    /// @notice Sets the account data a subsequent `getAccountData(safe)` will return
    function setAccountData(address safe, AccountData calldata data) external {
        _accountData[safe] = data;
    }

    /// @notice Sets the supplied amount a subsequent `suppliedOf(safe, asset)` will return
    function setSuppliedOf(address safe, address asset, uint256 amount) external {
        _suppliedOf[safe][asset] = amount;
    }

    /// @notice Sets the debt a subsequent `debtOf(safe, asset)` will return
    function setDebtOf(address safe, address asset, uint256 amount) external {
        _debtOf[safe][asset] = amount;
    }

    /// @notice Sets the reserve liquidity a subsequent `availableCash(asset)` will return
    function setAvailableCash(address asset, uint256 amount) external {
        _availableCash[asset] = amount;
    }

    /// @notice Sets the LTV (100e18 = 100%) a subsequent `ltv(asset)` will return
    function setLtv(address asset, uint256 ltvValue) external {
        _ltv[asset] = ltvValue;
    }

    function supply(address safe, address asset, uint256 amount) external {
        lastSupply = Call(safe, asset, amount, address(0));
    }

    function withdraw(address safe, address asset, uint256 amount, address to) external {
        lastWithdraw = Call(safe, asset, amount, to);
    }

    function borrow(address safe, address asset, uint256 amount, address to) external {
        if (borrowReverts) revert BorrowBlocked();
        lastBorrow = Call(safe, asset, amount, to);
    }

    function repay(address safe, address asset, uint256 amount) external returns (uint256) {
        uint256 debt = _debtOf[safe][asset];
        uint256 repaid = amount < debt ? amount : debt;
        _debtOf[safe][asset] = debt - repaid;
        lastRepay = Call(safe, asset, amount, address(0));
        return repaid;
    }

    function setUsingAsCollateral(address safe, address asset, bool useAsCollateral) external {
        usingAsCollateral[safe][asset] = useAsCollateral;
    }

    function getAccountData(address safe) external view returns (AccountData memory) {
        return _accountData[safe];
    }

    function suppliedOf(address safe, address asset) external view returns (uint256) {
        return _suppliedOf[safe][asset];
    }

    function debtOf(address safe, address asset) external view returns (uint256) {
        return _debtOf[safe][asset];
    }

    function availableCash(address asset) external view returns (uint256) {
        return _availableCash[asset];
    }

    function ltv(address asset) external view returns (uint256) {
        return _ltv[asset];
    }
}
