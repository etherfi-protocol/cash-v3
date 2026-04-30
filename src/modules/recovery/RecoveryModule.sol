// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OAppSender, MessagingFee, MessagingReceipt } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import { OAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppCore.sol";

import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { IRecoveryModule } from "../../interfaces/IRecoveryModule.sol";
import { IRoleRegistry } from "../../interfaces/IRoleRegistry.sol";
import { RecoveryMessageLib } from "../../libraries/RecoveryMessageLib.sol";
import { ModuleBase } from "../ModuleBase.sol";

/**
 * @title RecoveryModule
 * @author ether.fi
 * @notice Safe module that lets users recover ERC20 funds stuck in a wrong-chain TopUp contract
 * @dev Runs on Optimism. Single-call: owners sign `recover` and the LayerZero v2 message ships in
 *      the same transaction — no request/execute split, no timelock. Replay protection via
 *      `ModuleBase._useNonce`.
 *
 *      Non-upgradable by design — replaced (not upgraded) via
 *      `EtherFiDataProvider.configureModules`, matching the repo precedent set by
 *      `EtherFiStakeModule`, `EtherFiLiquidModule`, `OpenOceanSwapModule`, `StargateModule`.
 */
contract RecoveryModule is IRecoveryModule, ModuleBase, OAppSender, Pausable {
    constructor(address _dataProvider, address _endpoint, address _delegate)
        ModuleBase(_dataProvider)
        OAppCore(_endpoint, _delegate)
        Ownable(_delegate)
    {}

    function setupModule(bytes calldata) external override {}

    /**
     * @notice Submits and dispatches a cross-chain ERC20 recovery in a single call
     * @param safe The EtherFi Safe whose stuck TopUp on `destEid` will be drained
     * @param token The ERC20 token to recover (looked up by address on the destination chain)
     * @param amount The amount of `token` to recover. Must equal the TopUp's full balance on
     *               the destination chain (enforced by `TopUpV2`).
     * @param recipient The address that will receive `amount` of `token` on the destination chain
     * @param destEid The LayerZero v2 destination endpoint ID
     * @param lzOptions LayerZero v2 options (executor/gas) — pass from off-chain quoter. Bound
     *                  into the signed digest to prevent gas-grief replays with cheaper options.
     * @param signers Safe owners signing the recovery (must satisfy the Safe threshold)
     * @param signatures Signatures corresponding to `signers` over the recovery digest
     * @return lzGuid The LayerZero v2 message GUID used for delivery tracking
     * @custom:throws InvalidAmount if amount is zero
     * @custom:throws InvalidRecipient if recipient is the zero address
     * @custom:throws InvalidToken if token is the zero address
     * @custom:throws InvalidDestEid if no peer is configured for the destination endpoint
     */
    function recover(
        address safe,
        address token,
        uint256 amount,
        address recipient,
        uint32 destEid,
        bytes calldata lzOptions,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external payable whenNotPaused onlyEtherFiSafe(safe) returns (bytes32 lzGuid) {
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidRecipient();
        if (token == address(0)) revert InvalidToken();
        if (peers[destEid] == bytes32(0)) revert InvalidDestEid();

        _verifyRecoverySignatures(safe, token, amount, recipient, destEid, lzOptions, signers, signatures);

        lzGuid = _dispatchRecovery(safe, token, amount, recipient, destEid, lzOptions);

        emit RecoverySent(safe, lzGuid, token, amount, recipient, destEid);
    }

    /// @dev Encodes the recovery payload, fetches the LZ quote on-chain, and ships it via
    ///      `_lzSend` using that quoted fee. Extracted to keep the outer `recover` under the
    ///      EVM stack-too-deep limit. Any excess `msg.value` over the quoted fee is refunded
    ///      to the caller by the overridden `_payNative` below.
    function _dispatchRecovery(
        address safe,
        address token,
        uint256 amount,
        address recipient,
        uint32 destEid,
        bytes calldata lzOptions
    ) internal returns (bytes32) {
        bytes memory message = RecoveryMessageLib.encode(RecoveryMessageLib.Payload({
            safe: safe,
            token: token,
            amount: amount,
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

    /// @dev Override `OAppSender._payNative` to refund any `msg.value` excess over the quoted
    ///      `_nativeFee`. The base implementation requires strict equality; we fetch the
    ///      quote on-chain inside `_dispatchRecovery` and refund the difference here so a
    ///      caller who slightly over-funds (to absorb gas-price drift between off-chain
    ///      `quote()` and submission) doesn't revert.
    function _payNative(uint256 _nativeFee) internal override returns (uint256 nativeFee) {
        if (msg.value < _nativeFee) revert NotEnoughNative(msg.value);
        if (msg.value > _nativeFee) {
            (bool ok, ) = payable(msg.sender).call{ value: msg.value - _nativeFee }("");
            if (!ok) revert RefundFailed();
        }
        return _nativeFee;
    }

    /**
     * @dev Builds the replay-protected digest and hands it to the Safe's multisig check.
     *      Extracted into its own function to keep `recover` under the EVM stack limit.
     */
    function _verifyRecoverySignatures(
        address safe,
        address token,
        uint256 amount,
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
            amount,
            recipient,
            destEid,
            keccak256(lzOptions)
        ));
        if (!IEtherFiSafe(safe).checkSignatures(digest, signers, signatures)) revert InvalidSignature();
    }

    /**
     * @notice Quotes the LayerZero native fee required for `recover` with the given args
     * @return nativeFee The native fee in wei the caller must supply as `msg.value`
     */
    function quote(
        address safe,
        address token,
        uint256 amount,
        address recipient,
        uint32 destEid,
        bytes calldata lzOptions
    ) external view returns (uint256 nativeFee) {
        bytes memory message = RecoveryMessageLib.encode(RecoveryMessageLib.Payload({
            safe: safe,
            token: token,
            amount: amount,
            recipient: recipient
        }));

        MessagingFee memory fee = _quote(destEid, message, lzOptions, false);
        nativeFee = fee.nativeFee;
    }

    /**
     * @notice Pauses new recoveries
     * @dev Only callable by accounts with the PAUSER role on the shared RoleRegistry
     *      (the operating safe 0xA6cf...AAC4 in production).
     */
    function pause() external {
        _roleRegistry().onlyPauser(msg.sender);
        _pause();
    }

    /**
     * @notice Unpauses recoveries
     * @dev Only callable by accounts with the UNPAUSER role on the shared RoleRegistry.
     */
    function unpause() external {
        _roleRegistry().onlyUnpauser(msg.sender);
        _unpause();
    }

    function _roleRegistry() internal view returns (IRoleRegistry) {
        return IRoleRegistry(etherFiDataProvider.roleRegistry());
    }
}
