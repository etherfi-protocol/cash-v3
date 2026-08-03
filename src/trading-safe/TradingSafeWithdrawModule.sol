// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { IEtherFiSafe } from "../interfaces/IEtherFiSafe.sol";
import { IRoleRegistry } from "../interfaces/IRoleRegistry.sol";
import { ITradingSafeWithdrawModule } from "../interfaces/ITradingSafeWithdrawModule.sol";
import { ModuleBase } from "../modules/ModuleBase.sol";

/**
 * @title TradingSafeWithdrawModule
 * @author ether.fi
 * @notice Safe module on Ethereum mainnet that lets a TradingSafe's owners authorize an
 *         immediate, exact-amount ERC20 withdrawal to any recipient. There is no delay: mainnet
 *         TradingSafes carry no debt, card holds, or CashModule accounting to protect, so a
 *         withdrawal is a single owner-quorum-signed transfer — the direct analogue of the signed
 *         Enso/Across module transfers that already move a TradingSafe's assets immediately.
 * @dev Moves the token through the safe itself via `execTransactionFromModule`, so the module must
 *      be **enabled on the safe** (registered as a default module on the mainnet data provider, or
 *      added per-safe). The relayer is untrusted — the owner signatures authorize — so submission is
 *      permissionless. Replay protection is the safe nonce; a signed `deadline` stops a stashed
 *      signature from being replayed against a future deposit of the same token.
 */
contract TradingSafeWithdrawModule is ITradingSafeWithdrawModule, ModuleBase, Pausable {
    using MessageHashUtils for bytes32;

    /// @dev Domain-separator-style prefix for the digest the owners sign.
    bytes32 private constant WITHDRAW_SIG = keccak256("TradingSafeWithdrawModule.withdraw");

    constructor(address _dataProvider) ModuleBase(_dataProvider) { }

    function setupModule(bytes calldata) external override { }

    /// @inheritdoc ITradingSafeWithdrawModule
    function withdraw(address safe, address token, address recipient, uint256 amount, uint256 deadline, address[] calldata signers, bytes[] calldata signatures) external whenNotPaused onlyEtherFiSafe(safe) {
        if (token == address(0)) revert InvalidToken();
        if (recipient == address(0)) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();
        if (block.timestamp > deadline) revert WithdrawExpired();

        _verifyWithdrawSignatures(safe, token, recipient, amount, deadline, signers, signatures);

        _transferExactAmount(safe, token, recipient, amount);

        emit Withdrawn(safe, token, recipient, amount);
    }

    /// @dev Transfers exactly `amount` of `token` out of `safe` to `recipient`, asserting the safe's
    ///      balance decreased by precisely `amount`. `execTransactionFromModule` only checks call
    ///      success, not the ERC20 return value, so a false-returning / no-op token would otherwise
    ///      report success while moving nothing — the strict balance-delta check catches it. Note:
    ///      for a fee-on-transfer token the safe is still debited exactly `amount`; the recipient may
    ///      receive less.
    function _transferExactAmount(address safe, address token, address recipient, uint256 amount) internal {
        uint256 balanceBefore = IERC20(token).balanceOf(safe);
        if (balanceBefore < amount) revert InsufficientBalance();

        address[] memory to = new address[](1);
        to[0] = token;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeCall(IERC20.transfer, (recipient, amount));

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        uint256 balanceAfter = IERC20(token).balanceOf(safe);
        if (balanceBefore - balanceAfter != amount) revert WithdrawTransferFailed();
    }

    /// @dev Verifies the owner quorum over the FULL request, consuming a safe nonce so a signed
    ///      request can't replay. Binding chain id + module address + amount + recipient + deadline
    ///      means a signature can't be reused cross-chain, on another module, or for a different
    ///      amount/recipient, and expires at `deadline`.
    function _verifyWithdrawSignatures(address safe, address token, address recipient, uint256 amount, uint256 deadline, address[] calldata signers, bytes[] calldata signatures) internal {
        uint256 nonce = IEtherFiSafe(safe).useNonce();
        bytes32 digest = keccak256(abi.encodePacked(WITHDRAW_SIG, block.chainid, address(this), nonce, safe, token, recipient, amount, deadline)).toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digest, signers, signatures)) revert InvalidSignature();
    }

    /// @notice Pause new withdrawals. PAUSER role only.
    function pause() external {
        _roleRegistry().onlyPauser(msg.sender);
        _pause();
    }

    /// @notice Unpause withdrawals. UNPAUSER role only.
    function unpause() external {
        _roleRegistry().onlyUnpauser(msg.sender);
        _unpause();
    }

    function _roleRegistry() internal view returns (IRoleRegistry) {
        return IRoleRegistry(etherFiDataProvider.roleRegistry());
    }
}
