// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { OAppReceiverUpgradeable, Origin } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppReceiverUpgradeable.sol";
import { OAppCoreUpgradeable } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppCoreUpgradeable.sol";

import { RecoveryMessageLib } from "../libraries/RecoveryMessageLib.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";
import { TopUpV2 } from "./TopUpV2.sol";

/**
 * @title RecoveryDispatcher
 * @author ether.fi
 * @notice Singleton LayerZero v2 OApp receiver deployed once per destination chain.
 *         Receives recovery messages from the `RecoveryModule` on Optimism and forwards
 *         them to the user's per-chain `TopUpV2` beacon proxy.
 * @dev CREATE3 parity between `TopUp` and the user's EtherFi Safe is enforced by deployment
 *      tooling, so `payload.safe` is also the TopUp proxy address on this chain — no
 *      factory lookup is required. The TopUp gates the transfer on `msg.sender == DISPATCHER`.
 *      Pause/unpause and upgrade authorization are inherited from `UpgradeableProxy`, gated
 *      by the shared RoleRegistry's PAUSER / UNPAUSER / UPGRADER roles. Pausing is sufficient
 *      to halt all recoveries on this chain because every `TopUpV2.executeRecovery` call must
 *      originate from this dispatcher.
 */
contract RecoveryDispatcher is OAppReceiverUpgradeable, UpgradeableProxy {
    /// @notice Source EID this dispatcher trusts (Optimism = 30111).
    uint32 public immutable SOURCE_EID;

    /// @notice Emitted when a recovery message is successfully dispatched to a TopUp on this chain.
    event RecoveryDispatched(bytes32 indexed guid, address indexed safe, address indexed token, uint256 amount, address recipient);

    /// @notice Thrown when the LZ message origin's srcEid does not match `SOURCE_EID`.
    error WrongSrcEid();
    /// @notice Thrown when the target TopUp proxy has no code on this chain (user hasn't deployed yet).
    error TopUpNotDeployed();

    constructor(address _endpoint, uint32 _sourceEid) OAppCoreUpgradeable(_endpoint) {
        SOURCE_EID = _sourceEid;
        _disableInitializers();
    }

    /**
     * @notice Initializes the proxy instance
     * @param _delegate Address of the OApp delegate / owner (operating safe on the destination chain)
     * @param _roleRegistry Address of the shared RoleRegistry (drives pause/unpause and upgrades)
     */
    function initialize(address _delegate, address _roleRegistry) external initializer {
        __Ownable_init(_delegate);
        __OAppCore_init(_delegate);
        __UpgradeableProxy_init(_roleRegistry);
    }

    /**
     * @dev Handles an incoming LayerZero v2 message. Decodes the recovery payload and
     *      forwards it to the user's TopUp proxy (same address as the Safe).
     * @custom:throws WrongSrcEid if `origin.srcEid != SOURCE_EID` (defence-in-depth; peer
     *        check inside `OAppReceiver.lzReceive` already enforces the caller is a trusted
     *        peer, but an operator mistake that sets a peer under a different EID would be
     *        caught here).
     * @custom:throws TopUpNotDeployed if `payload.safe` has no code. Reverting lets the LZ
     *        executor retry the packet later once the TopUp is deployed; swallowing the
     *        error would burn the user's LZ fee.
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal override whenNotPaused {
        if (_origin.srcEid != SOURCE_EID) revert WrongSrcEid();

        RecoveryMessageLib.Payload memory p = RecoveryMessageLib.decode(_message);

        if (p.safe.code.length == 0) revert TopUpNotDeployed();

        TopUpV2(payable(p.safe)).executeRecovery(p.token, p.amount, p.recipient);

        emit RecoveryDispatched(_guid, p.safe, p.token, p.amount, p.recipient);
    }
}
