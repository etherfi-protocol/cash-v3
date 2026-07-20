// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity ^0.8.28;

import { SpokeInstance } from "aave-v4/spoke/instances/SpokeInstance.sol";

import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";

/**
 * @title EtherFiSpokeInstance
 * @notice Aave v4 SpokeInstance for the ether.fi whitelabel instance: `borrow` is gated so only ether.fi
 *         Cash Safes (per EtherFiDataProvider.isEtherFiSafe) can be the position owner. Supply, withdraw,
 *         repay, and liquidationCall are untouched — public LPs and liquidators remain permissionless.
 * @dev The check keys on `onBehalfOf` (the position owner), so it holds whether the safe borrows through
 *      the LendGateway (its registered position manager) or directly. The override deliberately adds no
 *      modifiers and no logic beyond the check: the parent's nonReentrant + onlyPositionManager run inside
 *      the super call (redeclaring nonReentrant here would self-deadlock on the shared guard), and keeping
 *      the body to one check + super means upstream borrow changes flow through untouched. The data
 *      provider is immutable (code, not storage), so this instance adds zero storage-layout risk across
 *      Aave upgrades.
 */
contract EtherFiSpokeInstance is SpokeInstance {
    /// @notice The ether.fi data provider used to recognize Cash Safes (a proxy; address is stable)
    IEtherFiDataProvider public immutable etherFiDataProvider;

    error OnlyEtherFiSafe(address account);
    error ZeroAddress();

    constructor(address oracle_, uint16 maxUserReservesLimit_, address etherFiDataProvider_) SpokeInstance(oracle_, maxUserReservesLimit_) {
        if (etherFiDataProvider_ == address(0)) revert ZeroAddress();
        etherFiDataProvider = IEtherFiDataProvider(etherFiDataProvider_);
    }

    /// @notice Borrows `amount` of reserve `reserveId` for `onBehalfOf`, which must be an ether.fi safe
    function borrow(uint256 reserveId, uint256 amount, address onBehalfOf) public override returns (uint256, uint256) {
        if (!etherFiDataProvider.isEtherFiSafe(onBehalfOf)) revert OnlyEtherFiSafe(onBehalfOf);
        return super.borrow(reserveId, amount, onBehalfOf);
    }
}
