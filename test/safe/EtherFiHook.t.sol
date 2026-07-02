// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IGateway } from "../../src/interfaces/IGateway.sol";
import { EtherFiHook, SafeTestSetup } from "./SafeTestSetup.t.sol";

contract EtherFiHookTest is SafeTestSetup {
    address nonCashModule = makeAddr("nonCashModule");

    function test_postOpHook_reverts_whenBelowMinHealthFactor() public {
        _setUnhealthyGatewayPosition(address(safe));

        vm.prank(address(safe));
        vm.expectRevert(EtherFiHook.OperationBreachesHealth.selector);
        hook.postOpHook(nonCashModule);
    }

    function test_postOpHook_passes_atExactlyMinHealthFactor() public {
        gateway.setAccountData(address(safe), IGateway.AccountData({ collateralUsd: 1000e6, debtUsd: 900e6, availableBorrowsUsd: 0, healthFactor: hook.minHealthFactor() }));

        vm.prank(address(safe));
        hook.postOpHook(nonCashModule);
    }

    function test_postOpHook_passes_whenNoDebt() public {
        // No account data set: the gateway reports an infinite health factor for a debt-free safe
        vm.prank(address(safe));
        hook.postOpHook(nonCashModule);
    }

    function test_postOpHook_skipsCashModuleOperations() public {
        _setUnhealthyGatewayPosition(address(safe));

        vm.prank(address(safe));
        hook.postOpHook(address(cashModule));
    }
}
