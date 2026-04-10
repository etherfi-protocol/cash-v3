// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BinSponsor } from "../interfaces/ICashModule.sol";
import { TopUpDestWithMigration } from "../top-up/TopUpDestWithMigration.sol";
import { DebtManagerCore } from "./DebtManagerCore.sol";

/**
 * @title DebtManagerCoreWithMigration
 * @notice Scroll-specific DebtManager that blocks borrowing for migrated safes
 * @dev Deploy as the DebtManager implementation on Scroll. After migration, safes cannot borrow.
 * @author ether.fi
 */
contract DebtManagerCoreWithMigration is DebtManagerCore {
    TopUpDestWithMigration public immutable topUpDest;

    error SafeMigrated();

    constructor(address dataProvider, address _topUpDest) DebtManagerCore(dataProvider) {
        topUpDest = TopUpDestWithMigration(payable(_topUpDest));
    }

    function borrow(BinSponsor binSponsor, address token, uint256 amount) public override {
        if (topUpDest.isMigrated(msg.sender)) revert SafeMigrated();
        super.borrow(binSponsor, token, amount);
    }
}
