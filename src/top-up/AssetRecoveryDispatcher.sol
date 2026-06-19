// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { OAppReceiverUpgradeable, Origin } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppReceiverUpgradeable.sol";
import { OAppCoreUpgradeable } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppCoreUpgradeable.sol";

import { RecoveryMessageLib } from "../libraries/RecoveryMessageLib.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";
import { TopUpV2 } from "./TopUpV2.sol";

/// @notice Minimal view+deploy surface of TopUpFactory needed by the dispatcher.
interface ITopUpFactoryDeployer {
    function getDeterministicAddress(bytes32 salt) external view returns (address);
    function deployTopUpContract(bytes32 salt) external;
}

/**
 * @title AssetRecoveryDispatcher
 * @author ether.fi
 * @notice Singleton LZ v2 receiver per destination chain. Forwards recovery messages from the
 *         OP-side AssetRecoveryModule into the user's TopUpV2, lazily deploying that TopUp
 *         on first use if a normal topup batch hasn't run for this safe yet.
 * @dev `payload.safe` doubles as the TopUp proxy address: TopUp and Safe share a CREATE3
 *      address by deployment-tooling invariant. The factory immutable lets us deploy that
 *      proxy on demand using the salt carried in the LZ payload.
 */
contract AssetRecoveryDispatcher is OAppReceiverUpgradeable, UpgradeableProxy {
    /// @notice Trusted source EID (Optimism = 30111).
    uint32 public immutable SOURCE_EID;
    /// @notice Local TopUpFactory used to lazily deploy TopUp proxies on first recovery.
    ITopUpFactoryDeployer public immutable TOPUP_FACTORY;

    event RecoveryDispatched(bytes32 indexed guid, address indexed safe, address indexed token, address recipient);
    event TopUpLazyDeployed(address indexed safe, bytes32 salt);

    error WrongSrcEid();
    /// @notice Salt in the LZ payload doesn't match the safe address under this chain's TopUpFactory.
    error SaltDoesNotMatchSafe();
    /// @notice Lazy deploy ran but `payload.safe` still has no code (factory misconfigured).
    error TopUpNotDeployed();

    constructor(address _endpoint, uint32 _sourceEid, address _topUpFactory) OAppCoreUpgradeable(_endpoint) {
        SOURCE_EID = _sourceEid;
        TOPUP_FACTORY = ITopUpFactoryDeployer(_topUpFactory);
        _disableInitializers();
    }

    /// @notice Initialize the proxy. `_delegate` is the OApp owner (operating safe on this chain).
    function initialize(address _delegate, address _roleRegistry) external initializer {
        __Ownable_init(_delegate);
        __OAppCore_init(_delegate);
        __UpgradeableProxy_init(_roleRegistry);
    }

    /// @dev srcEid check is defence-in-depth on top of OAppReceiver's peer check. If TopUp
    ///      isn't deployed yet, we deploy it via the factory using the salt carried in the
    ///      payload — but only after asserting the salt actually corresponds to `p.safe`
    ///      under this chain's factory, so a bogus salt can't litter the chain with stray
    ///      TopUp proxies at attacker-chosen addresses. If the factory call reverts (paused,
    ///      already deployed elsewhere) the LZ packet stays retryable.
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal override whenNotPaused {
        if (_origin.srcEid != SOURCE_EID) revert WrongSrcEid();

        RecoveryMessageLib.Payload memory p = RecoveryMessageLib.decode(_message);

        if (p.safe.code.length == 0) {
            if (TOPUP_FACTORY.getDeterministicAddress(p.salt) != p.safe) revert SaltDoesNotMatchSafe();
            TOPUP_FACTORY.deployTopUpContract(p.salt);
            if (p.safe.code.length == 0) revert TopUpNotDeployed();
            emit TopUpLazyDeployed(p.safe, p.salt);
        }

        TopUpV2(payable(p.safe)).executeRecovery(p.token, p.recipient);

        emit RecoveryDispatched(_guid, p.safe, p.token, p.recipient);
    }
}
