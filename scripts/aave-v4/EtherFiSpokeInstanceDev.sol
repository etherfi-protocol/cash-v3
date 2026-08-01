// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity ^0.8.28;

import { SpokeInstance } from "aave-v4/spoke/instances/SpokeInstance.sol";

/// @dev The ether.fi data provider used to recognize Cash Safes (a proxy; address is stable).
interface IEtherFiDataProvider {
    function isEtherFiSafe(address account) external view returns (bool);
}

/**
 * @title EtherFiSpokeInstanceDev
 * @notice Dev-instance build of the fork's `src/etherfi/EtherFiSpokeInstance.sol`
 *         (etherfi-protocol/aave-v4): `borrow` is gated so only ether.fi Cash Safes (per
 *         EtherFiDataProvider.isEtherFiSafe) can be the position owner. Supply, withdraw, repay,
 *         and liquidationCall are untouched.
 * @dev Identical to the prod contract except ETHERFI_DATA_PROVIDER, which is a compile-time
 *      constant and so cannot be inherited away: prod bakes the prod data provider proxy, this
 *      build bakes the dev one. Keep everything else in sync with the fork copy.
 */
contract EtherFiSpokeInstanceDev is SpokeInstance {
    /// @notice The ether.fi data provider used to recognize Cash Safes (dev proxy, OP Mainnet).
    address public constant ETHERFI_DATA_PROVIDER = 0x4a9c44c97BBf6079db37C4769AebE425bBcDD09a;

    error OnlyEtherFiSafe(address account);

    constructor(address oracle_, uint16 maxUserReservesLimit_) SpokeInstance(oracle_, maxUserReservesLimit_) { }

    /// @notice Borrows `amount` of reserve `reserveId` for `onBehalfOf`, which must be an ether.fi
    ///         Cash Safe.
    function borrow(uint256 reserveId, uint256 amount, address onBehalfOf) public override returns (uint256, uint256) {
        require(IEtherFiDataProvider(ETHERFI_DATA_PROVIDER).isEtherFiSafe(onBehalfOf), OnlyEtherFiSafe(onBehalfOf));
        return super.borrow(reserveId, amount, onBehalfOf);
    }
}
