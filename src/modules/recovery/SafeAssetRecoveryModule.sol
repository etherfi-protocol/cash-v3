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

        // Unsupported-only. A module transfer bypasses both the debt-health flow and the
        // CashModule withdrawal delay, so recovery must never touch a supported token:
        //   - collateral / borrow tokens back the safe's active debt position;
        //   - whitelisted withdraw assets are timelocked on the normal withdrawal path, and
        //     sweeping one here would skip that delay (and could drain a pending withdrawal).
        ICashModule cashModule = ICashModule(etherFiDataProvider.getCashModule());
        IDebtManager debtManager = cashModule.getDebtManager();
        if (
            debtManager.isCollateralToken(token) ||
            debtManager.isBorrowToken(token) ||
            _isWithdrawWhitelisted(cashModule, token)
        ) {
            revert OnlySupportedTokensCannotBeRecovered();
        }

        uint256 amount = IERC20(token).balanceOf(safe);
        if (amount == 0) revert NoBalanceToRecover();

        address[] memory to = new address[](1);
        to[0] = token;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeCall(IERC20.transfer, (recipient, amount));

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        // execTransactionFromModule only checks call success, not the ERC20 return value. The
        // post-transfer balance check defends against non-reverting `false` returns and
        // fee-on-transfer behaviour on the arbitrary unsupported tokens this path targets.
        if (IERC20(token).balanceOf(safe) != 0) revert RecoveryTransferFailed();

        emit AssetRecovered(safe, token, recipient, amount);
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
