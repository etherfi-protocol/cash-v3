// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../../../src/UUPSProxy.sol";
import { CashModule } from "../../../../src/modules/cash/CashModule.sol";
import { ICashDataProvider } from "../../../../src/interfaces/ICashDataProvider.sol";
import { ICashModule, Mode } from "../../../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../../../src/interfaces/IDebtManager.sol";
import { IPriceProvider } from "../../../../src/interfaces/IPriceProvider.sol";
import { ArrayDeDupLib, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup, EtherFiDataProvider } from "../../SafeTestSetup.t.sol";
import { CashModuleTestSetup } from "./CashModuleTestSetup.t.sol";

contract SpendTest is CashModuleTestSetup {
    function test_spend_works_inDebitMode() public {
        uint256 amount = 100e6;
        deal(address(usdcScroll), address(safe), amount);

        vm.prank(etherFiWallet);
        cashModule.spend(address(safe), keccak256("txId"), address(usdcScroll), amount);
        
        // Verify transaction was cleared
        assertTrue(cashModule.transactionCleared(address(safe), keccak256("txId")));
    }
    
    // TODO: Wont work unless debt manager changes
    // function test_spend_works_inCreditMode() public {
    //     deal(address(usdcScroll), address(safe), 1000e6);
        
    //     cashModule.setMode(address(safe), Mode.Credit);
        
    //     uint256 amount = 100e6;
    //     vm.prank(etherFiWallet);
    //     cashModule.spend(address(safe), keccak256("txId"), address(usdcScroll), amount);
    // }
}   