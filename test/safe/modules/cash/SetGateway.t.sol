// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ICashModule } from "../../../../src/interfaces/ICashModule.sol";
import { MockGateway } from "../../../../src/mocks/MockGateway.sol";
import { CashEventEmitter, CashModuleTestSetup } from "./CashModuleTestSetup.t.sol";

contract CashModuleSetGatewayTest is CashModuleTestSetup {
    function test_setGateway_emitsAndUpdates() public {
        MockGateway newGateway = new MockGateway();
        address oldGateway = address(cashModule.getGateway());

        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.GatewayUpdated(oldGateway, address(newGateway));

        vm.prank(owner);
        cashModule.setGateway(address(newGateway));

        assertEq(address(cashModule.getGateway()), address(newGateway));
    }

    function test_setGateway_revertsForNonController() public {
        MockGateway newGateway = new MockGateway();

        vm.prank(notOwner);
        vm.expectRevert(ICashModule.OnlyCashModuleController.selector);
        cashModule.setGateway(address(newGateway));
    }

    function test_setGateway_revertsForZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ICashModule.InvalidInput.selector);
        cashModule.setGateway(address(0));
    }
}
