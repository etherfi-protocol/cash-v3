// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OAppSender, MessagingFee, MessagingReceipt } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import { OAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppCore.sol";

import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { IAssetRecoveryModule } from "../../interfaces/IAssetRecoveryModule.sol";
import { IRoleRegistry } from "../../interfaces/IRoleRegistry.sol";
import { RecoveryMessageLib } from "../../libraries/RecoveryMessageLib.sol";
import { ModuleBase } from "../ModuleBase.sol";

/**
 * @title AssetRecoveryModule
 * @author ether.fi
 * @notice Safe module on Optimism for recovering ERC20 funds stuck in a wrong-chain TopUp.
 * @dev Owners sign and dispatch the LayerZero v2 message in a single call. Amount is not signed;
 *      the destination sweeps whatever balance is present at delivery.
 */
contract AssetRecoveryModule is IAssetRecoveryModule, ModuleBase, OAppSender, Pausable {
    constructor(address _dataProvider, address _endpoint, address _delegate)
        ModuleBase(_dataProvider)
        OAppCore(_endpoint, _delegate)
        Ownable(_delegate)
    {}

    function setupModule(bytes calldata) external override {}

    /**
     * @notice Submit and dispatch a cross-chain ERC20 recovery in a single call.
     * @param lzOptions LayerZero v2 options (executor/gas). Bound into the signed digest to
     *                  prevent gas-grief replays with cheaper options.
     * @return lzGuid LayerZero v2 message GUID for delivery tracking.
     */
    function recover(
        address safe,
        address token,
        address recipient,
        uint32 destEid,
        bytes calldata lzOptions,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external payable whenNotPaused onlyEtherFiSafe(safe) returns (bytes32 lzGuid) {
        if (recipient == address(0)) revert InvalidRecipient();
        if (token == address(0)) revert InvalidToken();
        if (peers[destEid] == bytes32(0)) revert InvalidDestEid();

        _verifyRecoverySignatures(safe, token, recipient, destEid, lzOptions, signers, signatures);

        lzGuid = _dispatchRecovery(safe, token, recipient, destEid, lzOptions);

        emit RecoverySent(safe, lzGuid, token, recipient, destEid);
    }

    /// @dev Extracted from `recover` to dodge stack-too-deep. Excess msg.value is refunded
    ///      via the overridden `_payNative`.
    function _dispatchRecovery(
        address safe,
        address token,
        address recipient,
        uint32 destEid,
        bytes calldata lzOptions
    ) internal returns (bytes32) {
        bytes memory message = RecoveryMessageLib.encode(RecoveryMessageLib.Payload({
            safe: safe,
            token: token,
            recipient: recipient
        }));

        MessagingFee memory fee = _quote(destEid, message, lzOptions, false);

        MessagingReceipt memory receipt = _lzSend(
            destEid,
            message,
            lzOptions,
            fee,
            payable(msg.sender)
        );

        return receipt.guid;
    }

    /// @dev Refunds excess msg.value over the quoted fee. Base impl requires strict equality;
    ///      we relax it so callers can over-fund to absorb gas-price drift.
    function _payNative(uint256 _nativeFee) internal override returns (uint256 nativeFee) {
        if (msg.value < _nativeFee) revert NotEnoughNative(msg.value);
        if (msg.value > _nativeFee) {
            (bool ok, ) = payable(msg.sender).call{ value: msg.value - _nativeFee }("");
            if (!ok) revert RefundFailed();
        }
        return _nativeFee;
    }

    /// @dev Extracted from `recover` to dodge stack-too-deep.
    function _verifyRecoverySignatures(
        address safe,
        address token,
        address recipient,
        uint32 destEid,
        bytes calldata lzOptions,
        address[] calldata signers,
        bytes[] calldata signatures
    ) internal {
        bytes32 digest = keccak256(abi.encode(
            block.chainid,
            address(this),
            _useNonce(safe),
            safe,
            token,
            recipient,
            destEid,
            keccak256(lzOptions)
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
