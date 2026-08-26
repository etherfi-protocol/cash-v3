// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ICashModule } from "../../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../../src/interfaces/IDebtManager.sol";
import { SafeTestSetup } from "../SafeTestSetup.t.sol";

/**
 * @title EtherFiHookPostOpTest
 * @notice postOpHook runs on every non-CashModule Safe tx. It health-checks legacy safes against
 *         DebtManager, and skips the check for gateway safes: their supplied collateral lives inside Aave
 *         (which enforces its own health factor on every op that can worsen it) and loose tokens are not
 *         Aave collateral, so no module tx can push a gateway position underwater.
 */
contract EtherFiHookPostOpTest is SafeTestSetup {
    address internal safeAddr = makeAddr("safeAddr");
    address internal module = makeAddr("someModule");

    /// A gateway safe skips the DebtManager check: postOpHook returns even though ensureHealth would revert.
    function test_postOpHook_skipsCheck_forGatewaySafe() public {
        vm.mockCall(address(cashModule), abi.encodeWithSelector(ICashModule.usesLendGateway.selector, safeAddr), abi.encode(true));
        vm.mockCallRevert(address(debtManager), abi.encodeWithSelector(IDebtManager.ensureHealth.selector, safeAddr), abi.encodeWithSelector(IDebtManager.AccountUnhealthy.selector));

        vm.prank(safeAddr);
        hook.postOpHook(module);
    }

    /// A legacy safe is still health-checked: an unhealthy DebtManager position makes postOpHook revert.
    function test_postOpHook_enforcesCheck_forLegacySafe() public {
        vm.mockCall(address(cashModule), abi.encodeWithSelector(ICashModule.usesLendGateway.selector, safeAddr), abi.encode(false));
        vm.mockCallRevert(address(debtManager), abi.encodeWithSelector(IDebtManager.ensureHealth.selector, safeAddr), abi.encodeWithSelector(IDebtManager.AccountUnhealthy.selector));

        vm.prank(safeAddr);
        vm.expectRevert(IDebtManager.AccountUnhealthy.selector);
        hook.postOpHook(module);
    }
}
