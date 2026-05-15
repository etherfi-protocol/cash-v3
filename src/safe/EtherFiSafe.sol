// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { EtherFiSafeBase } from "./EtherFiSafeBase.sol";
import { EtherFiSafeCore } from "./EtherFiSafeCore.sol";
import { EtherFiSafeErrors } from "./EtherFiSafeErrors.sol";
import { OwnerBridgePublisher } from "./OwnerBridgePublisher.sol";

/**
 * @title EtherFiSafe
 * @author ether.fi
 * @notice OP-side concrete EtherFiSafe - `EtherFiSafeCore` plus the cross-chain owner-mutation
 *         broadcaster (`OwnerBridgePublisher`). 
 */
contract EtherFiSafe is EtherFiSafeCore, OwnerBridgePublisher {
    constructor(address _dataProvider) payable EtherFiSafeCore(_dataProvider) {}

    /// @dev Wire `OwnerBridgePublisher` into the bridge-publish hook surface declared by
    ///      `EtherFiSafeBase`. Each override resolves the multi-inheritance ambiguity and
    ///      delegates to `OwnerBridgePublisher`'s concrete implementation.

    function _publishConfigureOwners(address[] calldata owners, bool[] calldata shouldAdd, uint8 threshold) internal override(EtherFiSafeBase, OwnerBridgePublisher) {
        OwnerBridgePublisher._publishConfigureOwners(owners, shouldAdd, threshold);
    }

    function _publishSetThreshold(uint8 threshold) internal override(EtherFiSafeBase, OwnerBridgePublisher) {
        OwnerBridgePublisher._publishSetThreshold(threshold);
    }

    function _publishRecover(address newOwner, uint256 incomingOwnerEffectiveAt) internal override(EtherFiSafeBase, OwnerBridgePublisher) {
        OwnerBridgePublisher._publishRecover(newOwner, incomingOwnerEffectiveAt);
    }

    function _publishCancelRecovery() internal override(EtherFiSafeBase, OwnerBridgePublisher) {
        OwnerBridgePublisher._publishCancelRecovery();
    }

    /// @inheritdoc OwnerBridgePublisher
    function _getDataProvider() internal view override returns (IEtherFiDataProvider) {
        return dataProvider;
    }
}
