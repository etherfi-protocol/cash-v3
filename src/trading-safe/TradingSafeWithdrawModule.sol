// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { IEtherFiSafe } from "../interfaces/IEtherFiSafe.sol";
import { IRoleRegistry } from "../interfaces/IRoleRegistry.sol";
import { ITradingSafeWithdrawModule, Withdrawal } from "../interfaces/ITradingSafeWithdrawModule.sol";
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
 * @notice A withdrawal may optionally unwrap: the tokenized equities a TradingSafe holds are
 *         `WrappedBackedToken` ERC-4626 vaults over a rebasing Backed xStock (e.g. wTSLAx over
 *         TSLAx), and holders generally want the underlying rather than the DeFi-composability
 *         wrapper. Setting `unwrap[i]` redeems the vault straight to the recipient, so the exit is
 *         still one call. The flag is part of the signed digest, so owners choose per withdrawal;
 *         it is not inferred, since a wrapper is the right form to receive when the destination is
 *         a pool or another protocol.
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
    function withdraw(address safe, Withdrawal[] calldata withdrawals, address recipient, uint256 deadline, address[] calldata signers, bytes[] calldata signatures) external whenNotPaused onlyEtherFiSafe(safe) {
        _validateRequest(withdrawals, recipient, deadline);

        _verifyWithdrawSignatures(safe, keccak256(abi.encode(withdrawals)), recipient, deadline, signers, signatures);

        _emitWithdrawn(safe, withdrawals, recipient, _withdrawExactAmounts(safe, withdrawals, recipient));
    }

    /// @dev Rejects malformed requests before any signature work. Split out of `withdraw` to keep its
    ///      stack shallow.
    function _validateRequest(Withdrawal[] calldata withdrawals, address recipient, uint256 deadline) private view {
        uint256 len = withdrawals.length;
        if (len == 0) revert EmptyWithdrawal();
        if (recipient == address(0)) revert InvalidRecipient();
        if (block.timestamp > deadline) revert WithdrawExpired();

        for (uint256 i = 0; i < len;) {
            if (withdrawals[i].token == address(0)) revert InvalidToken();
            if (withdrawals[i].amount == 0) revert InvalidAmount();
            // Duplicate tokens would break the per-token balance-delta check below, so reject them.
            for (uint256 j = i + 1; j < len;) {
                if (withdrawals[j].token == withdrawals[i].token) revert DuplicateToken();
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev `underlyings[i]` is non-zero only where the entry was unwrapped, which is the one thing the
    ///      `Withdrawn` events can't convey on their own.
    function _emitWithdrawn(address safe, Withdrawal[] calldata withdrawals, address recipient, address[] memory underlyings) private {
        uint256 len = withdrawals.length;
        for (uint256 i = 0; i < len;) {
            emit Withdrawn(safe, withdrawals[i].token, recipient, withdrawals[i].amount);
            if (underlyings[i] != address(0)) emit Unwrapped(safe, withdrawals[i].token, recipient, underlyings[i], withdrawals[i].amount);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Debits each withdrawal's exact `amount` of its `token` from `safe` for `recipient` in a
    ///      single batched safe call, asserting each token's balance decreased by precisely that amount.
    ///      An entry is either a plain `transfer` or, when `unwrap` is set, an ERC-4626 `redeem` that
    ///      burns the shares from the safe and sends the underlying straight to `recipient` — the safe is
    ///      both caller and share owner, so no allowance is involved. Either way the safe is debited
    ///      exactly the signed `amount` of the signed `token`, which is what the check below enforces.
    ///      `execTransactionFromModule` only checks call success, not the ERC20 return value, so a
    ///      false-returning / no-op token would otherwise report success while moving nothing. Tokens are
    ///      duplicate-free (enforced by the caller), so each delta maps to exactly one entry. Note: for a
    ///      fee-on-transfer token the safe is still debited exactly `amount`; the recipient may receive less.
    /// @return underlyings The redeemed asset per entry, or the zero address where no unwrap happened.
    function _withdrawExactAmounts(address safe, Withdrawal[] calldata withdrawals, address recipient) internal returns (address[] memory underlyings) {
        uint256 len = withdrawals.length;
        address[] memory to = new address[](len);
        uint256[] memory values = new uint256[](len);
        bytes[] memory data = new bytes[](len);
        uint256[] memory balancesBefore = new uint256[](len);
        underlyings = new address[](len);

        for (uint256 i = 0; i < len;) {
            Withdrawal calldata w = withdrawals[i];
            uint256 balanceBefore = IERC20(w.token).balanceOf(safe);
            if (balanceBefore < w.amount) revert InsufficientBalance();
            balancesBefore[i] = balanceBefore;

            to[i] = w.token;
            if (w.unwrap) {
                address underlying = _underlyingOf(w.token);
                if (underlying == address(0) || underlying == w.token) revert NotUnwrappable();
                underlyings[i] = underlying;
                data[i] = abi.encodeCall(IERC4626.redeem, (w.amount, recipient, safe));
            } else {
                data[i] = abi.encodeCall(IERC20.transfer, (recipient, w.amount));
            }
            unchecked {
                ++i;
            }
        }

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        for (uint256 i = 0; i < len;) {
            uint256 balanceAfter = IERC20(withdrawals[i].token).balanceOf(safe);
            if (balancesBefore[i] - balanceAfter != withdrawals[i].amount) revert WithdrawTransferFailed();
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Reads a token's ERC-4626 underlying, returning the zero address when it is not a vault.
    ///      Probing beats a curated wrapper registry here: every tokenized equity the safe can hold is
    ///      a `WrappedBackedToken`, new ones are listed regularly, and a stale registry would silently
    ///      fall back to handing out the wrapper. The owner quorum already vouches for the token, so
    ///      the probe only has to distinguish a vault from a plain ERC20, not police which vault.
    function _underlyingOf(address token) private view returns (address) {
        try IERC4626(token).asset() returns (address underlying) {
            return underlying;
        } catch {
            return address(0);
        }
    }

    /// @dev Verifies the owner quorum over the FULL request, consuming a safe nonce so a signed
    ///      request can't replay. Binding chain id + module address + the hash of the withdrawal legs +
    ///      recipient + deadline means a signature can't be reused cross-chain, on another module, or
    ///      for a different set of tokens/amounts/recipient — or to flip a withdrawal between wrapped
    ///      and unwrapped delivery — and expires at `deadline`.
    function _verifyWithdrawSignatures(address safe, bytes32 requestHash, address recipient, uint256 deadline, address[] calldata signers, bytes[] calldata signatures) internal {
        bytes32 digest = _withdrawDigest(safe, requestHash, recipient, deadline, IEtherFiSafe(safe).useNonce());
        if (!IEtherFiSafe(safe).checkSignatures(digest, signers, signatures)) revert InvalidSignature();
    }

    /// @dev Builds the EIP-191 digest from the pre-hashed request arrays. Split out of
    ///      `_verifyWithdrawSignatures` to keep the signing frame's stack shallow.
    function _withdrawDigest(address safe, bytes32 requestHash, address recipient, uint256 deadline, uint256 nonce) private view returns (bytes32) {
        return keccak256(abi.encodePacked(WITHDRAW_SIG, block.chainid, address(this), nonce, safe, requestHash, recipient, deadline)).toEthSignedMessageHash();
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
