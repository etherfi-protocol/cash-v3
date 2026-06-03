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

        // Unsupported-only: collateral backs active debt and a module transfer bypasses the normal
        // withdrawal + debt-health flow, so recovery must never touch a collateral or borrow token.
        IDebtManager debtManager = ICashModule(etherFiDataProvider.getCashModule()).getDebtManager();
        if (debtManager.isCollateralToken(token) || debtManager.isBorrowToken(token)) {
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
