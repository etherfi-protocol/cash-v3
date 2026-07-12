// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ILendGateway } from "../interfaces/ILendGateway.sol";

/**
 * @title MockLendGateway
 * @notice Inert test double for ILendGateway. Non-lend safe suites wire it so the cash contracts have a codeful
 *         gateway that reports an empty position, and the SetLendGateway guard tests plus the ModuleLendGatewaySandwich
 *         call-order test drive it directly. Real gateway behavior is exercised against a live Aave v4 instance
 *         under the lend profile (test/safe/modules/cash/lend/**), so this mock no longer fabricates positions.
 *         Not for production.
 * @dev Records the last supply / withdraw call and the collateral flag for the sandwich test; the position
 *      aggregate (getAccountData) and reserve liquidity (availableCash) are settable for the guard tests. The
 *      remaining reads return empty defaults, matching the inert wiring.
 */
contract MockLendGateway is ILendGateway {
    /// @notice Recorded arguments of a mutating gateway call (`to` is zero for supply)
    struct Call {
        address safe;
        address asset;
        uint256 amount;
        address to;
    }

    mapping(address => AccountData) internal _accountData;
    mapping(address => mapping(address => bool)) public usingAsCollateral;
    mapping(address safe => mapping(address asset => uint256)) internal _debtOf;
    mapping(address safe => mapping(address asset => uint256)) internal _suppliedOf;
    mapping(address asset => uint256) internal _availableCash;
    /// @dev Whether an asset is a registered reserve; defaults to false
    mapping(address asset => bool) internal _registered;

    Call public lastSupply;
    Call public lastWithdraw;

    /// @notice Sets the account data a subsequent `getAccountData(safe)` will return
    function setAccountData(address safe, AccountData calldata data) external {
        _accountData[safe] = data;
    }

    /// @notice Sets the reserve liquidity a subsequent `availableCash(asset)` will return
    function setAvailableCash(address asset, uint256 amount) external {
        _availableCash[asset] = amount;
    }

    /// @notice Sets whether an asset is a registered reserve (defaults to unregistered)
    function setRegistered(address asset, bool registered) external {
        _registered[asset] = registered;
    }

    /// @notice Sets the amount a subsequent `suppliedOf(safe, asset)` will return
    function setSuppliedOf(address safe, address asset, uint256 amount) external {
        _suppliedOf[safe][asset] = amount;
    }

    function supply(address safe, address asset, uint256 amount) external {
        lastSupply = Call(safe, asset, amount, address(0));
    }

    function withdraw(address safe, address asset, uint256 amount, address to) external {
        lastWithdraw = Call(safe, asset, amount, to);
    }

    function borrow(address safe, address asset, uint256 amount, address to) external { }

    function repay(address safe, address asset, uint256 amount) external returns (uint256) {
        uint256 debt = _debtOf[safe][asset];
        uint256 repaid = amount < debt ? amount : debt;
        _debtOf[safe][asset] = debt - repaid;
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

    function ltv(address) external pure returns (uint256) {
        return 0;
    }

    function isRegistered(address asset) external view returns (bool) {
        return _registered[asset];
    }

    function registeredAssets() external pure returns (address[] memory) {
        return new address[](0);
    }
}
