// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeData } from "../../interfaces/ICashModule.sol";
import { IDebtManager } from "../../interfaces/IDebtManager.sol";
import { TopUpDestWithMigration } from "../../top-up/TopUpDestWithMigration.sol";
import { CashLens } from "./CashLens.sol";

/**
 * @title CashLensWithMigration
 * @notice Scroll-specific CashLens that reports migrated safes as unable to borrow (credit mode)
 * @dev Deploy as the CashLens implementation on Scroll. Overrides _creditModeCheck to block
 *      credit mode canSpend for migrated safes.
 * @author ether.fi
 */
contract CashLensWithMigration is CashLens {
    TopUpDestWithMigration public immutable topUpDest;

    constructor(address _cashModule, address _dataProvider, address _topUpDest) CashLens(_cashModule, _dataProvider) {
        topUpDest = TopUpDestWithMigration(payable(_topUpDest));
    }

    function _creditModeCheck(
        address safe,
        address[] memory tokens,
        uint256[] memory amounts,
        uint256 totalSpendingInUsd,
        IDebtManager debtManager,
        SafeData memory safeData
    ) internal view override returns (bool, string memory) {
        if (topUpDest.isMigrated(safe)) return (false, "Safe is migrated");
        return super._creditModeCheck(safe, tokens, amounts, totalSpendingInUsd, debtManager, safeData);
    }
}
