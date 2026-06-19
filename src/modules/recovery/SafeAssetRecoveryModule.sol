// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { ISafeAssetRecoveryModule } from "../../interfaces/ISafeAssetRecoveryModule.sol";
import { IRoleRegistry } from "../../interfaces/IRoleRegistry.sol";
import { ICashModule } from "../../interfaces/ICashModule.sol";
import { IDebtManager } from "../../interfaces/IDebtManager.sol";
import { ModuleBase } from "../ModuleBase.sol";

/**
 * @title SafeAssetRecoveryModule
 * @author ether.fi
 * @notice Safe module on Optimism for sweeping an *unsupported* ERC20 stuck in the user's own
 *         EtherFiSafe directly to a recipient, on owner-quorum authorization. No cross-chain hop.
 * @dev Mirrors `AssetRecoveryModule` but without any LayerZero machinery: it moves the token through
 *      the safe itself via `execTransactionFromModule`, so the module must be **enabled on the safe**
 *      (not merely whitelisted in the data provider). Amount is not signed; the full balance is swept.
 */
contract SafeAssetRecoveryModule is ISafeAssetRecoveryModule, ModuleBase, Pausable {
    constructor(address _dataProvider) ModuleBase(_dataProvider) {}

    function setupModule(bytes calldata) external override {}

    /**
     * @notice Sweep the full balance of one unsupported ERC20 out of `safe` to `recipient`.
     * @dev The caller is untrusted (EtherFi sponsors/submits); the owner signatures authorize.
     *      The per-safe nonce from `ModuleBase` gives replay protection.
     * @dev Subject to the safe's debt-health check (audit I-03): `execTransactionFromModule` fires
     *      `EtherFiHook.postOpHook`, which runs `debtManager.ensureHealth(safe)` for every module
     *      except CashModule. So `recover()` reverts on an unhealthy safe even though the swept token
     *      is non-collateral / non-borrow and cannot affect the debt position. This is intentional and
     *      acknowledged: the module is deliberately NOT excluded from the health check — gating all
     *      asset-moving operations on health keeps the risk surface minimal and consistent with every
     *      other module. An unhealthy safe must regain health (repay / add collateral) before recovery.
     */
    function recover(
        address safe,
        address token,
        address recipient,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external whenNotPaused onlyEtherFiSafe(safe) {
        if (recipient == address(0)) revert InvalidRecipient();
        if (token == address(0)) revert InvalidToken();

        _verifyRecoverySignatures(safe, token, recipient, signers, signatures);
        _assertRecoverable(token);

        uint256 moved = _sweepFullBalance(safe, token, recipient);

        emit AssetRecovered(safe, token, recipient, moved);
    }

    /// @dev Reverts unless `token` is genuinely unsupported. A module transfer bypasses both the
    ///      debt-health flow and the CashModule withdrawal delay, so recovery must never touch a
    ///      supported token:
    ///        - collateral / borrow tokens back the safe's active debt position;
    ///        - whitelisted withdraw assets are timelocked on the normal withdrawal path, and
    ///          sweeping one here would skip that delay (and could drain a pending withdrawal).
    function _assertRecoverable(address token) internal view {
        ICashModule cashModule = ICashModule(etherFiDataProvider.getCashModule());
        IDebtManager debtManager = cashModule.getDebtManager();
        if (
            debtManager.isCollateralToken(token) ||
            debtManager.isBorrowToken(token) ||
            _isWithdrawWhitelisted(cashModule, token)
        ) {
            revert OnlySupportedTokensCannotBeRecovered();
        }
    }

    /// @dev Sweeps the full balance of `token` out of `safe` to `recipient`, returning the amount
    ///      that actually left the safe. Extracted from `recover` to dodge stack-too-deep.
    function _sweepFullBalance(address safe, address token, address recipient) internal returns (uint256 moved) {
        uint256 amount = IERC20(token).balanceOf(safe);
        if (amount == 0) revert NoBalanceToRecover();

        address[] memory to = new address[](1);
        to[0] = token;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeCall(IERC20.transfer, (recipient, amount));

        // Fires EtherFiHook.postOpHook -> debtManager.ensureHealth(safe), so this reverts on an
        // unhealthy safe (audit I-03 — intentional; see recover() docs).
        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        // execTransactionFromModule only checks call success, not the ERC20 return value, so verify
        // the sweep actually moved funds. Require the balance to strictly *decrease* rather than hit
        // exactly zero: share-accounted / rebasing tokens (e.g. stETH) can leave 1-2 wei of dust from
        // rounding, and an `== 0` check would treat that as a failure and trap the token forever. A
        // non-reverting `false` return moves nothing, leaving the balance unchanged -> still caught.
        uint256 remaining = IERC20(token).balanceOf(safe);
        if (remaining >= amount) revert RecoveryTransferFailed();

        return amount - remaining;
    }

    /// @dev True if `token` is whitelisted for delayed withdrawals on the CashModule. The set is
    ///      configured independently of the collateral/borrow sets, so it must be checked
    ///      separately. Scanned linearly: the list is tiny and recovery is a rare manual op.
    function _isWithdrawWhitelisted(ICashModule cashModule, address token) internal view returns (bool) {
        address[] memory withdrawAssets = cashModule.getWhitelistedWithdrawAssets();
        uint256 len = withdrawAssets.length;
        for (uint256 i = 0; i < len;) {
            if (withdrawAssets[i] == token) return true;
            unchecked { ++i; }
        }
        return false;
    }

    /// @dev Digest mirrors `AssetRecoveryModule` minus the LayerZero fields. Amount is not signed
    ///      (full-balance sweep). `_useNonce` consumes the per-safe nonce for replay protection.
    function _verifyRecoverySignatures(
        address safe,
        address token,
        address recipient,
        address[] calldata signers,
        bytes[] calldata signatures
    ) internal {
        bytes32 digest = keccak256(abi.encode(
            block.chainid,
            address(this),
            _useNonce(safe),
            safe,
            token,
            recipient
        ));
        if (!IEtherFiSafe(safe).checkSignatures(digest, signers, signatures)) revert InvalidSignature();
    }

    /// @notice Pause new recoveries. PAUSER role only.
    function pause() external {
        _roleRegistry().onlyPauser(msg.sender);
        _pause();
    }

    /// @notice Unpause recoveries. UNPAUSER role only.
    function unpause() external {
        _roleRegistry().onlyUnpauser(msg.sender);
        _unpause();
    }

    function _roleRegistry() internal view returns (IRoleRegistry) {
        return IRoleRegistry(etherFiDataProvider.roleRegistry());
    }
}
