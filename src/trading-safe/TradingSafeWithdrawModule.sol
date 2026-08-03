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
 *         immediate, exact-amount withdrawal of one or more ERC20s to any recipient in a single
 *         signed batch. There is no delay: mainnet TradingSafes carry no debt, card holds, or
 *         CashModule accounting to protect, so a withdrawal is a single owner-quorum-signed
 *         transfer — the direct analogue of the signed Enso/Across module transfers that already
 *         move a TradingSafe's assets immediately.
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
    function withdraw(address safe, address[] calldata tokens, uint256[] calldata amounts, address recipient, uint256 deadline, address[] calldata signers, bytes[] calldata signatures) external whenNotPaused onlyEtherFiSafe(safe) {
        uint256 len = tokens.length;
        if (len == 0) revert EmptyWithdrawal();
        if (len != amounts.length) revert ArrayLengthMismatch();
        if (recipient == address(0)) revert InvalidRecipient();
        if (block.timestamp > deadline) revert WithdrawExpired();

        for (uint256 i = 0; i < len;) {
            if (tokens[i] == address(0)) revert InvalidToken();
            if (amounts[i] == 0) revert InvalidAmount();
            // Duplicate tokens would break the per-token balance-delta check below, so reject them.
            for (uint256 j = i + 1; j < len;) {
                if (tokens[j] == tokens[i]) revert DuplicateToken();
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }

        _verifyWithdrawSignatures(safe, keccak256(abi.encode(tokens)), keccak256(abi.encode(amounts)), recipient, deadline, signers, signatures);

        _transferExactAmounts(safe, tokens, amounts, recipient);

        for (uint256 i = 0; i < len;) {
            emit Withdrawn(safe, tokens[i], recipient, amounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Transfers exactly `amounts[i]` of `tokens[i]` out of `safe` to `recipient` in a single
    ///      batched safe call, asserting each token's balance decreased by precisely its amount.
    ///      `execTransactionFromModule` only checks call success, not the ERC20 return value, so a
    ///      false-returning / no-op token would otherwise report success while moving nothing — the
    ///      strict per-token balance-delta check catches it. `tokens` is duplicate-free (enforced by
    ///      the caller), so each delta maps to exactly one entry. Note: for a fee-on-transfer token
    ///      the safe is still debited exactly `amounts[i]`; the recipient may receive less.
    function _transferExactAmounts(address safe, address[] calldata tokens, uint256[] calldata amounts, address recipient) internal {
        uint256 len = tokens.length;
        address[] memory to = new address[](len);
        uint256[] memory values = new uint256[](len);
        bytes[] memory data = new bytes[](len);
        uint256[] memory balancesBefore = new uint256[](len);

        for (uint256 i = 0; i < len;) {
            uint256 balanceBefore = IERC20(tokens[i]).balanceOf(safe);
            if (balanceBefore < amounts[i]) revert InsufficientBalance();
            balancesBefore[i] = balanceBefore;

            to[i] = tokens[i];
            data[i] = abi.encodeCall(IERC20.transfer, (recipient, amounts[i]));
            unchecked {
                ++i;
            }
        }

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        for (uint256 i = 0; i < len;) {
            uint256 balanceAfter = IERC20(tokens[i]).balanceOf(safe);
            if (balancesBefore[i] - balanceAfter != amounts[i]) revert WithdrawTransferFailed();
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Verifies the owner quorum over the FULL request, consuming a safe nonce so a signed
    ///      request can't replay. Binding chain id + module address + the token/amount array hashes +
    ///      recipient + deadline means a signature can't be reused cross-chain, on another module, or
    ///      for a different set of tokens/amounts/recipient, and expires at `deadline`.
    function _verifyWithdrawSignatures(address safe, bytes32 tokensHash, bytes32 amountsHash, address recipient, uint256 deadline, address[] calldata signers, bytes[] calldata signatures) internal {
        bytes32 digest = _withdrawDigest(safe, tokensHash, amountsHash, recipient, deadline, IEtherFiSafe(safe).useNonce());
        if (!IEtherFiSafe(safe).checkSignatures(digest, signers, signatures)) revert InvalidSignature();
    }

    /// @dev Builds the EIP-191 digest from the pre-hashed token/amount arrays. Split out of
    ///      `_verifyWithdrawSignatures` to keep the signing frame's stack shallow.
    function _withdrawDigest(address safe, bytes32 tokensHash, bytes32 amountsHash, address recipient, uint256 deadline, uint256 nonce) private view returns (bytes32) {
        return keccak256(abi.encodePacked(WITHDRAW_SIG, block.chainid, address(this), nonce, safe, tokensHash, amountsHash, recipient, deadline)).toEthSignedMessageHash();
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
