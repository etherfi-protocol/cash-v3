// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { OAppSenderUpgradeable, MessagingFee, MessagingReceipt } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppSenderUpgradeable.sol";
import { OAppCoreUpgradeable } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppCoreUpgradeable.sol";

import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { IRecoveryModule } from "../../interfaces/IRecoveryModule.sol";
import { IRoleRegistry } from "../../interfaces/IRoleRegistry.sol";
import { RecoveryMessageLib } from "../../libraries/RecoveryMessageLib.sol";
import { ModuleBase } from "../ModuleBase.sol";
import { RecoveryModuleStorage } from "./RecoveryModuleStorage.sol";

/**
 * @title RecoveryModule
 * @author ether.fi
 * @notice Safe module that lets users request timelocked cross-chain ERC20 recovery
 * @dev Runs on Optimism. Sends LayerZero v2 messages to TopUpDispatcher on destination chains.
 *      Real business logic lands in Tasks 6-8; this is the scaffold only.
 */
contract RecoveryModule is IRecoveryModule, ModuleBase, OAppSenderUpgradeable, PausableUpgradeable, RecoveryModuleStorage {
    uint64 public constant TIMELOCK = 3 days;

    /**
     * @notice Constructor — wires immutable references to the data provider and LayerZero endpoint
     * @param _dataProvider Address of the EtherFiDataProvider contract
     * @param _endpoint Address of the local LayerZero v2 endpoint
     * @dev `OAppCoreUpgradeable` stores the endpoint as an immutable set in its constructor; the
     *      delegate is configured later in `initialize` via `__OAppCore_init`.
     */
    constructor(address _dataProvider, address _endpoint) ModuleBase(_dataProvider) OAppCoreUpgradeable(_endpoint) {
        _disableInitializers();
    }

    /**
     * @notice Initializes the proxy instance
     * @param _delegate Address of the OApp delegate / owner
     * @dev Initializes OwnableUpgradeable with `_delegate` as owner, calls `__OAppCore_init`
     *      which registers the delegate on the LayerZero endpoint, and initializes Pausable.
     */
    function initialize(address _delegate) external initializer {
        __Ownable_init(_delegate);
        __OAppCore_init(_delegate);
        __Pausable_init();
    }

    /**
     * @notice Sets up a new Safe's RecoveryModule state (no-op for now)
     * @dev Override from ModuleBase; real setup lands in Tasks 6-8 if needed.
     */
    function setupModule(bytes calldata) external override {}

    // ───── stubs — real implementations land in Tasks 6-8 ─────

    /**
     * @notice Requests a timelocked cross-chain ERC20 recovery on behalf of a Safe
     * @param safe The EtherFi Safe requesting recovery
     * @param token The ERC20 token held on the destination chain to be moved
     * @param amount The amount of `token` to recover
     * @param recipient The address that will receive `amount` of `token` on the destination chain
     * @param destEid The LayerZero v2 destination endpoint ID
     * @param signers Safe owners signing the request (must satisfy the Safe threshold)
     * @param signatures Signatures corresponding to `signers` over the recovery digest
     * @return id The deterministic recovery id, `keccak256(abi.encode(safe, nonce))`
     * @dev Stores a `PendingRecovery` that becomes executable after `TIMELOCK`.
     *      No LayerZero message is sent here — `executeRecovery` (Task 7) performs the send.
     * @custom:throws InvalidAmount if amount is zero
     * @custom:throws InvalidRecipient if recipient is the zero address
     * @custom:throws InvalidDestEid if no peer is configured for the destination endpoint
     */
    function requestRecovery(
        address safe,
        address token,
        uint256 amount,
        address recipient,
        uint32 destEid,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external whenNotPaused onlyEtherFiSafe(safe) returns (bytes32 id) {
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidRecipient();
        if (peers(destEid) == bytes32(0)) revert InvalidDestEid();

        _verifyRequestRecoverySignatures(safe, token, amount, recipient, destEid, signers, signatures);

        RecoveryModuleStorageStruct storage $ = _recoveryStorage();
        id = keccak256(abi.encode(safe, $.recoveryNonce[safe]++));

        uint64 unlockAt = uint64(block.timestamp) + TIMELOCK;
        $.pending[safe][id] = PendingRecovery({
            token: token,
            amount: amount,
            recipient: recipient,
            destEid: destEid,
            unlockAt: unlockAt,
            executed: false,
            cancelled: false
        });

        emit RecoveryRequested(safe, id, token, amount, recipient, destEid, unlockAt);
    }

    /**
     * @dev Builds the replay-protected digest and hands it to the Safe's multisig check.
     *      Extracted into its own function to keep `requestRecovery` under the EVM stack limit.
     */
    function _verifyRequestRecoverySignatures(
        address safe,
        address token,
        uint256 amount,
        address recipient,
        uint32 destEid,
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
            destEid
        ));
        if (!IEtherFiSafe(safe).checkSignatures(digest, signers, signatures)) revert InvalidSignature();
    }

    /**
     * @notice Dispatches a cross-chain recovery message after the timelock has expired
     * @param safe The EtherFi Safe whose pending recovery is being executed
     * @param id The recovery id returned by `requestRecovery`
     * @param lzOptions LayerZero v2 options (executor/gas) — pass from off-chain quoter
     * @dev Marks the recovery as executed BEFORE the external `_lzSend` call (CEI).
     *      The caller attaches the LayerZero native fee as `msg.value`.
     * @custom:throws RecoveryNotFound if no pending recovery exists for `(safe, id)`
     * @custom:throws RecoveryAlreadyFinalized if already executed or cancelled
     * @custom:throws RecoveryStillLocked if current time is before `unlockAt`
     */
    function executeRecovery(address safe, bytes32 id, bytes calldata lzOptions)
        external
        payable
        whenNotPaused
    {
        RecoveryModuleStorageStruct storage $ = _recoveryStorage();
        PendingRecovery storage pr = $.pending[safe][id];

        if (pr.unlockAt == 0) revert RecoveryNotFound();
        if (pr.executed || pr.cancelled) revert RecoveryAlreadyFinalized();
        if (block.timestamp < pr.unlockAt) revert RecoveryStillLocked();

        // Checks-Effects-Interactions: flip executed before the external send.
        pr.executed = true;

        bytes memory message = RecoveryMessageLib.encode(RecoveryMessageLib.Payload({
            safe: safe,
            token: pr.token,
            amount: pr.amount,
            recipient: pr.recipient
        }));

        MessagingReceipt memory receipt = _lzSend(
            pr.destEid,
            message,
            lzOptions,
            MessagingFee({ nativeFee: msg.value, lzTokenFee: 0 }),
            payable(msg.sender)
        );

        emit RecoveryExecuted(safe, id, receipt.guid);
    }

    /**
     * @notice Cancels a pending recovery before it is executed
     * @param safe The EtherFi Safe whose pending recovery is being cancelled
     * @param id The recovery id returned by `requestRecovery`
     * @param signers Safe owners signing the cancel (must satisfy the Safe threshold)
     * @param signatures Signatures corresponding to `signers` over the cancel digest
     * @dev Cancel is always available — not gated by the timelock and not blocked by `whenNotPaused`
     *      so owners can still abort a pending recovery while the module is paused.
     * @custom:throws RecoveryNotFound if no pending recovery exists for `(safe, id)`
     * @custom:throws RecoveryAlreadyFinalized if already executed or cancelled
     * @custom:throws InvalidSignature if the Safe multisig check fails
     */
    function cancelRecovery(
        address safe,
        bytes32 id,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external onlyEtherFiSafe(safe) {
        RecoveryModuleStorageStruct storage $ = _recoveryStorage();
        PendingRecovery storage pr = $.pending[safe][id];

        if (pr.unlockAt == 0) revert RecoveryNotFound();
        if (pr.executed || pr.cancelled) revert RecoveryAlreadyFinalized();

        bytes32 digest = keccak256(abi.encode(
            "cancel",
            block.chainid,
            address(this),
            _useNonce(safe),
            safe,
            id
        ));
        if (!IEtherFiSafe(safe).checkSignatures(digest, signers, signatures)) revert InvalidSignature();

        pr.cancelled = true;
        emit RecoveryCancelled(safe, id);
    }

    /**
     * @notice Quotes the LayerZero native fee required to execute a pending recovery
     * @param safe The EtherFi Safe whose pending recovery would be executed
     * @param id The recovery id
     * @param lzOptions LayerZero v2 options (executor/gas)
     * @return nativeFee The native fee in wei the caller must supply to `executeRecovery`
     * @custom:throws RecoveryNotFound if no pending recovery exists for `(safe, id)`
     */
    function quoteExecute(address safe, bytes32 id, bytes calldata lzOptions)
        external
        view
        returns (uint256 nativeFee)
    {
        PendingRecovery memory pr = _recoveryStorage().pending[safe][id];
        if (pr.unlockAt == 0) revert RecoveryNotFound();

        bytes memory message = RecoveryMessageLib.encode(RecoveryMessageLib.Payload({
            safe: safe,
            token: pr.token,
            amount: pr.amount,
            recipient: pr.recipient
        }));

        MessagingFee memory fee = _quote(pr.destEid, message, lzOptions, false);
        nativeFee = fee.nativeFee;
    }

    /**
     * @notice Returns the stored `PendingRecovery` for a `(safe, id)` pair
     * @param safe The EtherFi Safe that submitted the request
     * @param id The recovery id returned by `requestRecovery`
     * @return The full `PendingRecovery` struct; zero-valued if none exists
     */
    function getRecovery(address safe, bytes32 id) external view returns (PendingRecovery memory) {
        return _recoveryStorage().pending[safe][id];
    }

    /**
     * @notice Pauses new requests and executions
     * @dev Only callable by accounts with the PAUSER role on the shared RoleRegistry
     *      (the operating safe 0xA6cf...AAC4 in production).
     */
    function pause() external {
        _roleRegistry().onlyPauser(msg.sender);
        _pause();
    }

    /**
     * @notice Unpauses requests and executions
     * @dev Only callable by accounts with the UNPAUSER role on the shared RoleRegistry.
     */
    function unpause() external {
        _roleRegistry().onlyUnpauser(msg.sender);
        _unpause();
    }

    /**
     * @dev Returns the shared RoleRegistry via the data provider.
     *      Kept as an internal helper so tests and subclasses can resolve it the same way.
     */
    function _roleRegistry() internal view returns (IRoleRegistry) {
        return IRoleRegistry(etherFiDataProvider.roleRegistry());
    }
}
