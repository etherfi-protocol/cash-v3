// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { OAppReceiverUpgradeable, Origin } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppReceiverUpgradeable.sol";
import { OAppCoreUpgradeable } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppCoreUpgradeable.sol";

import { RecoveryMessageLib } from "../libraries/RecoveryMessageLib.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";
import { TopUpV2 } from "./TopUpV2.sol";

/**
 * @title AssetRecoveryDispatcher
 * @author ether.fi
 * @notice Singleton LZ v2 receiver per destination chain. Forwards recovery messages from the
 *         OP-side AssetRecoveryModule into the user's TopUpV2.
 * @dev `payload.safe` doubles as the TopUp proxy address: TopUp and Safe share a CREATE3
 *      address by deployment-tooling invariant, so no factory lookup is needed.
 */
contract AssetRecoveryDispatcher is OAppReceiverUpgradeable, UpgradeableProxy {
    /// @notice Trusted source EID (Optimism = 30111).
    uint32 public immutable SOURCE_EID;

    event RecoveryDispatched(bytes32 indexed guid, address indexed safe, address indexed token, address recipient);

    error WrongSrcEid();
    /// @notice Target TopUp proxy has no code on this chain.
    error TopUpNotDeployed();

    constructor(address _endpoint, uint32 _sourceEid) OAppCoreUpgradeable(_endpoint) {
        SOURCE_EID = _sourceEid;
        _disableInitializers();
    }

    /// @notice Initialize the proxy. `_delegate` is the OApp owner (operating safe on this chain).
    function initialize(address _delegate, address _roleRegistry) external initializer {
        __Ownable_init(_delegate);
        __OAppCore_init(_delegate);
        __UpgradeableProxy_init(_roleRegistry);
    }

    /// @dev srcEid check is defence-in-depth on top of OAppReceiver's peer check. Reverting on
    ///      missing TopUp code keeps the LZ packet retryable once the proxy is deployed.
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

        TopUpV2(payable(p.safe)).executeRecovery(p.token, p.recipient);

        emit RecoveryDispatched(_guid, p.safe, p.token, p.recipient);
    }
}
