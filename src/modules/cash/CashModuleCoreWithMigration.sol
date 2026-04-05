// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BinSponsor, Cashback } from "../../interfaces/ICashModule.sol";
import { TopUpDestWithMigration } from "../../top-up/TopUpDestWithMigration.sol";
import { CashModuleCore } from "./CashModuleCore.sol";
import { CashModuleStorageContract } from "./CashModuleStorageContract.sol";

/**
 * @title CashModuleCoreWithMigration
 * @notice Scroll-specific CashModule that blocks credit mode spending (borrowing) for migrated safes
 * @dev Deploy as the CashModule implementation on Scroll. After migration, safes cannot borrow.
 * @author ether.fi
 */
contract CashModuleCoreWithMigration is CashModuleCore {
    TopUpDestWithMigration public immutable topUpDest;

    error SafeMigrated();

    constructor(address _etherFiDataProvider, address _topUpDest) CashModuleCore(_etherFiDataProvider) {
        topUpDest = TopUpDestWithMigration(payable(_topUpDest));
    }

    function _spendCredit(
        CashModuleStorage storage $,
        address safe,
        bytes32 txId,
        BinSponsor binSponsor,
        address[] memory tokens,
        uint256[] memory amountsInUsd,
        uint256 totalSpendingInUsd
    ) internal override {
        if (topUpDest.isMigrated(safe)) revert SafeMigrated();
        super._spendCredit($, safe, txId, binSponsor, tokens, amountsInUsd, totalSpendingInUsd);
    }
}
