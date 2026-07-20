// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev The slice of Aave v4's TreasurySpoke (an Ownable2StepUpgradeable) the splitter drives. withdraw
///      pays out to msg.sender, which is why the splitter must be the owner and call it itself.
interface ITreasurySpokeMinimal {
    function withdraw(address hub, address underlying, uint256 amount) external returns (uint256, uint256);
    function acceptOwnership() external;
    function transferOwnership(address newOwner) external;
}

/**
 * @title AaveV4RevenueSplitter
 * @notice Owns the whitelabel instance's TreasurySpoke and splits protocol fees between two immutable
 *         recipients as they are claimed. Claiming and splitting are permissionless,
 *         so revenue sharing needs no operator. 
 */
contract AaveV4RevenueSplitter is Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_BPS = 10_000;

    /// @notice The Aave v4 TreasurySpoke this contract owns and claims fees from
    ITreasurySpokeMinimal public immutable treasurySpoke;
    /// @notice Receives `splitBpsA` of every split (ether.fi treasury)
    address public immutable recipientA;
    /// @notice Receives the remainder of every split (Aave DAO collector)
    address public immutable recipientB;
    /// @notice recipientA's share in BPS (e.g. 8000 = 80%)
    uint256 public immutable splitBpsA;

    event RevenueSplit(address indexed token, uint256 amountA, uint256 amountB);

    error ZeroAddress();
    error InvalidSplitBps();

    constructor(address treasurySpoke_, address recipientA_, address recipientB_, uint256 splitBpsA_, address owner_) Ownable(owner_) {
        if (treasurySpoke_ == address(0) || recipientA_ == address(0) || recipientB_ == address(0)) revert ZeroAddress();
        if (splitBpsA_ == 0 || splitBpsA_ >= MAX_BPS) revert InvalidSplitBps();
        treasurySpoke = ITreasurySpokeMinimal(treasurySpoke_);
        recipientA = recipientA_;
        recipientB = recipientB_;
        splitBpsA = splitBpsA_;
    }

    /// @notice Completes the Ownable2Step handshake making this contract the TreasurySpoke owner
    function acceptTreasurySpokeOwnership() external {
        treasurySpoke.acceptOwnership();
    }

    /**
     * @notice Claims accrued fees from the TreasurySpoke and splits them between the recipients
     * @dev Permissionless. TreasurySpoke.withdraw caps at the claimable balance and pays this contract,
     *      so pass type(uint256).max to claim everything.
     */
    function claimAndSplit(address hub, address underlying, uint256 amount) external {
        treasurySpoke.withdraw(hub, underlying, amount);
        _split(underlying);
    }

    /// @notice Splits any `token` balance held directly by this contract (e.g. sent here by mistake)
    function split(address token) external {
        _split(token);
    }

    /// @notice Escape hatch: initiates a 2-step transfer of the TreasurySpoke's ownership
    function transferTreasurySpokeOwnership(address newOwner) external onlyOwner {
        treasurySpoke.transferOwnership(newOwner);
    }

    function _split(address token) internal {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) return;
        uint256 amountA = balance * splitBpsA / MAX_BPS;
        uint256 amountB = balance - amountA;
        if (amountA > 0) IERC20(token).safeTransfer(recipientA, amountA);
        if (amountB > 0) IERC20(token).safeTransfer(recipientB, amountB);
        emit RevenueSplit(token, amountA, amountB);
    }
}
