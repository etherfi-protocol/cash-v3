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
 * @dev Records the last supply / withdraw call and collateral flag for the sandwich test. AccountData,
 *      withdrawal liquidity, and per-safe borrow capacity are settable for focused guard tests; remaining reads
 *      return inert defaults.
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
    mapping(address asset => uint256) internal _withdrawalLiquidity;
    mapping(address safe => mapping(address asset => uint256)) internal _borrowCapacity;
    mapping(address safe => mapping(address asset => bool)) internal _borrowCapacitySet;
    mapping(address safe => mapping(address asset => uint256)) internal _rawBorrowCapacity;
    mapping(address safe => mapping(address asset => bool)) internal _rawBorrowCapacitySet;
    /// @dev Whether an asset is a registered reserve; defaults to false
    mapping(address asset => bool) internal _registered;
    /// @dev Whether an asset's reserve allows borrowing; defaults to false
    mapping(address asset => bool) internal _borrowable;
    /// @dev Whether an asset is an admin-declared debit-spend token; defaults to false
    mapping(address asset => bool) internal _spendAsset;
    /// @dev Every asset ever registered, in order; registeredAssets/borrowableAssets filter it by the flags
    address[] internal _assets;

    Call public lastSupply;
    Call public lastWithdraw;

    /// @notice Sets the account data a subsequent `getAccountData(safe)` will return
    function setAccountData(address safe, AccountData calldata data) external {
        _accountData[safe] = data;
    }

    /// @notice Sets the reserve liquidity a subsequent `withdrawalLiquidity(asset)` will return
    function setWithdrawalLiquidity(address asset, uint256 amount) external {
        _withdrawalLiquidity[asset] = amount;
    }

    /// @notice Sets the buffered Aave-priced borrowing capacity returned for a safe and asset
    function setBorrowCapacity(address safe, address asset, uint256 amount) external {
        _borrowCapacity[safe][asset] = amount;
        _borrowCapacitySet[safe][asset] = true;
    }

    /// @notice Sets the raw (Aave 1.00) borrowing capacity returned for a safe and asset
    function setRawBorrowCapacity(address safe, address asset, uint256 amount) external {
        _rawBorrowCapacity[safe][asset] = amount;
        _rawBorrowCapacitySet[safe][asset] = true;
    }

    /// @notice Sets whether an asset is a registered reserve (defaults to unregistered)
    function setRegistered(address asset, bool registered) external {
        if (registered && !_registered[asset]) _assets.push(asset);
        _registered[asset] = registered;
    }

    /// @notice Sets whether an asset's reserve allows borrowing (defaults to non-borrowable)
    function setBorrowable(address asset, bool borrowable) external {
        _borrowable[asset] = borrowable;
    }

    /// @notice Sets whether an asset is a debit-spend token (defaults to non-spendable)
    function setSpendAsset(address asset, bool spendable) external {
        _spendAsset[asset] = spendable;
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

    uint256 public minHealthFactor;

    function hasDebt(address safe) external view returns (bool) {
        for (uint256 i = 0; i < _assets.length; i++) {
            if (_debtOf[safe][_assets[i]] != 0) return true;
        }
        return false;
    }

    function setMinHealthFactor(uint256 value) external {
        minHealthFactor = value;
    }

    function ensureMinHealthFactor(address safe) external view { }

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

    function withdrawalLiquidity(address asset) external view returns (uint256) {
        return _withdrawalLiquidity[asset];
    }

    /// @dev The mock models no borrow cap, so the borrowable liquidity equals withdrawalLiquidity
    function borrowLiquidity(address asset) external view returns (uint256) {
        return _withdrawalLiquidity[asset];
    }

    /// @dev Defaults to unlimited so existing tests can configure only their relevant gate.
    function borrowCapacity(address safe, address asset) external view returns (uint256) {
        return _borrowCapacitySet[safe][asset] ? _borrowCapacity[safe][asset] : type(uint256).max;
    }

    /// @dev Defaults to unlimited so existing tests can configure only their relevant gate.
    function rawBorrowCapacity(address safe, address asset) external view returns (uint256) {
        return _rawBorrowCapacitySet[safe][asset] ? _rawBorrowCapacity[safe][asset] : type(uint256).max;
    }

    function ltv(address) external pure returns (uint256) {
        return 0;
    }

    function isRegistered(address asset) external view returns (bool) {
        return _registered[asset];
    }

    function registeredAssets() external view returns (address[] memory) {
        return _filterAssets(false);
    }

    function isBorrowable(address asset) external view returns (bool) {
        return _registered[asset] && _borrowable[asset];
    }

    function borrowableAssets() external view returns (address[] memory) {
        return _filterAssets(true);
    }

    /// @dev The mock models no pause, so the debit-spend gate is just the admin spend flag
    function isSpendAsset(address asset) external view returns (bool) {
        return _spendAsset[asset];
    }

    function spendAssets() external view returns (address[] memory) {
        address[] memory out = new address[](_assets.length);
        uint256 count = 0;
        for (uint256 i = 0; i < _assets.length; i++) {
            if (_spendAsset[_assets[i]]) {
                out[count] = _assets[i];
                unchecked {
                    ++count;
                }
            }
        }
        assembly ("memory-safe") {
            mstore(out, count)
        }
        return out;
    }

    /// @dev The registered assets, optionally narrowed to the borrowable ones
    function _filterAssets(bool onlyBorrowable) internal view returns (address[] memory) {
        address[] memory out = new address[](_assets.length);
        uint256 count = 0;
        for (uint256 i = 0; i < _assets.length; i++) {
            address asset = _assets[i];
            if (_registered[asset] && (!onlyBorrowable || _borrowable[asset])) {
                out[count] = asset;
                unchecked {
                    ++count;
                }
            }
        }
        assembly ("memory-safe") {
            mstore(out, count)
        }
        return out;
    }
}
