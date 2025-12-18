// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { SafeTestSetup, MessageHashUtils } from "../../SafeTestSetup.t.sol";
import { FraxModule } from "../../../../src/modules/frax/FraxModule.sol";
import { ModuleCheckBalance } from "../../../../src/modules/ModuleCheckBalance.sol";
import { ModuleBase } from "../../../../src/modules/ModuleBase.sol";
import { IBoringOnChainQueue } from "../../../../src/interfaces/IBoringOnChainQueue.sol";
import { IDebtManager } from "../../../../src/interfaces/IDebtManager.sol";
import { ILayerZeroTeller } from "../../../../src/interfaces/ILayerZeroTeller.sol";
import { IEtherFiSafe } from "../../../../src/interfaces/IEtherFiSafe.sol";
import { IEtherFiDataProvider } from "../../../../src/interfaces/IEtherFiDataProvider.sol";
import { ICashModule, WithdrawalRequest } from "../../../../src/interfaces/ICashModule.sol";
import { CashVerificationLib } from "../../../../src/libraries/CashVerificationLib.sol";
import { EtherFiSafeErrors } from "../../../../src/safe/EtherFiSafeErrors.sol";

contract FraxModuleTest is SafeTestSetup {
    using MessageHashUtils for bytes32;

    FraxModule public fraxModule;

    IERC20 public usdc = IERC20(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
    IERC20 public fraxusd = IERC20(0x397F939C3b91A74C321ea7129396492bA9Cdce82);
    address public custodian = 0x05bF905356fbeA7E59500f904b908402dB7A53DD;
    
    
    function setUp() public override {
        super.setUp();
        
        vm.startPrank(owner);

        fraxModule = new FraxModule(address(fraxusd), address(usdc), address(dataProvider), custodian);

        address[] memory modules = new address[](1);
        modules[0] = address(fraxModule);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;
        
        bytes[] memory moduleSetupData = new bytes[](1);
        moduleSetupData[0] = "";
        
        dataProvider.configureModules(modules, shouldWhitelist);
        _configureModules(modules, shouldWhitelist, moduleSetupData);
        
        vm.stopPrank();
    }

    //Success cases
    function test_deposit_successFraxUsd() public {
        uint256 amountToDeposit = 1000 * 10**6; // 1000 USDC (6 decimals)
        deal(address(usdc), address(safe), amountToDeposit);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            fraxModule.DEPOSIT_SIG(),
            block.chainid,
            address(fraxModule),
            fraxModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(usdc), amountToDeposit)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v); 
        
        uint256 usdcBalBefore = usdc.balanceOf(address(safe));
        uint256 fraxUsdBalBefore = fraxusd.balanceOf(address(safe));

        uint256 fraxUsdExpected = amountToDeposit * 10**12; // scaled for decimals difference

        vm.expectEmit(true, true, true, true);
        emit FraxModule.Deposit(address(safe), address(usdc), amountToDeposit, fraxUsdExpected);
        
        fraxModule.deposit(address(safe), address(usdc), amountToDeposit, owner1, signature);
        
        uint256 usdcBalAfter = usdc.balanceOf(address(safe));
        uint256 fraxUsdBalAfter = fraxusd.balanceOf(address(safe));
        
        assertEq(usdcBalAfter, usdcBalBefore - amountToDeposit);
        assertGt(fraxUsdBalAfter, fraxUsdBalBefore);
    }

    function test_withdraw_successFraxUsd() public {    
        vm.prank(owner);

        uint128 amountToWithdraw = 1000 * 10**18;
        deal(address(fraxusd), address(safe), amountToWithdraw);
        deal(address(usdc), address(custodian), amountToWithdraw);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            fraxModule.WITHDRAW_SIG(),
            block.chainid,
            address(fraxModule),
            fraxModule.getNonce(address(safe)),
            address(safe),
            abi.encode(amountToWithdraw)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        uint256 fraxUsdBalBefore = fraxusd.balanceOf(address(safe));
        
        vm.expectEmit(true, true, true, true);
        emit FraxModule.Withdrawal(address(safe), amountToWithdraw, amountToWithdraw);
        
        fraxModule.withdraw(address(safe), amountToWithdraw, owner1, signature);
        
        uint256 fraxUsdBalAfter = fraxusd.balanceOf(address(safe));
        assertEq(fraxUsdBalAfter, fraxUsdBalBefore - amountToWithdraw);
    }

    //Revert cases

    function test_deposit_revertsWhenInvalidSignature() public {
        uint256 amountToDeposit = 1000 * 10**6; // 1000 USDC (6 decimals)
        deal(address(usdc), address(safe), amountToDeposit);

        bytes32 digestHash = keccak256(abi.encodePacked(
            fraxModule.DEPOSIT_SIG(),
            block.chainid,
            address(fraxModule),
            fraxModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(usdc), amountToDeposit)
        )).toEthSignedMessageHash();

        // Sign with a different private key
        uint256 wrongPrivateKey = 0x54321;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, digestHash);
        bytes memory invalidSignature = abi.encodePacked(r, s, v);

        vm.expectRevert(); // Should revert due to ECDSA recovery failure
        fraxModule.deposit(address(safe), address(usdc), amountToDeposit, owner1, invalidSignature);
    }

    function test_deposit_revertsForNonAdminSigner() public {
        uint256 amountToDeposit = 1000 * 10**6; // 1000 USDC (6 decimals)
        deal(address(usdc), address(safe), amountToDeposit);
        
        // Create a non-admin address
        address nonAdmin = makeAddr("nonAdmin");

        bytes32 digestHash = keccak256(abi.encodePacked(
            fraxModule.DEPOSIT_SIG(),
            block.chainid,
            address(fraxModule),
            fraxModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(usdc), amountToDeposit)
        )).toEthSignedMessageHash();

        // Sign with owner1's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory validSignature = abi.encodePacked(r, s, v);

        // Try to use a non-admin signer
        vm.expectRevert();
        fraxModule.deposit(address(safe), address(usdc), amountToDeposit, nonAdmin, validSignature);
    }
    
    function test_deposit_revertsWithZeroAmount() public {        
        vm.prank(owner);
        
        uint128 amountToDeposit = 0;
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            fraxModule.DEPOSIT_SIG(),
            block.chainid,
            address(fraxModule),
            fraxModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(usdc), amountToDeposit)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        fraxModule.deposit(address(safe), address(usdc), amountToDeposit, owner1, signature);
    }

    function test_deposit_revertsWithInsufficientBalance() public {
        vm.prank(owner);
        
        // Ensure the safe has some balance, but less than we'll try to deposit
        uint256 safeBalance = 500 * 10**18;
        uint128 amountToDeposit = 1000 * 10**18; // More than balance
        deal(address(fraxusd), address(safe), safeBalance);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            fraxModule.DEPOSIT_SIG(),
            block.chainid,
            address(fraxModule),
            fraxModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(usdc), amountToDeposit)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        fraxModule.deposit(address(safe), address(usdc), amountToDeposit, owner1, signature);
    }


    function test_withdraw_revertsWithZeroAmount() public {        
        vm.prank(owner);
        
        uint128 amountToWithdraw = 0;
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            fraxModule.WITHDRAW_SIG(),
            block.chainid,
            address(fraxModule),
            fraxModule.getNonce(address(safe)),
            address(safe),
            abi.encode(amountToWithdraw)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        fraxModule.withdraw(address(safe), amountToWithdraw, owner1, signature);
    }

    function test_withdraw_revertsWithInsufficientBalance() public {
        vm.prank(owner);
        
        // Ensure the safe has some balance, but less than we'll try to withdraw
        uint256 safeBalance = 500 * 10**18;
        uint128 amountToWithdraw = 1000 * 10**18; // More than balance
        deal(address(fraxusd), address(safe), safeBalance);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            fraxModule.WITHDRAW_SIG(),
            block.chainid,
            address(fraxModule),
            fraxModule.getNonce(address(safe)),
            address(safe),
            abi.encode(amountToWithdraw)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        fraxModule.withdraw(address(safe), amountToWithdraw, owner1, signature);
    }

    function test_withdraw_revertsWithInvalidSignature() public {
        vm.prank(owner);
        
        uint128 amountToWithdraw = 1000 * 10**18;
        deal(address(fraxusd), address(safe), amountToWithdraw);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            fraxModule.WITHDRAW_SIG(),
            block.chainid,
            address(fraxModule),
            fraxModule.getNonce(address(safe)),
            address(safe),
            abi.encode(amountToWithdraw)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner2Pk, digestHash);
        bytes memory invalidSignature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        fraxModule.withdraw(address(safe), amountToWithdraw, owner1, invalidSignature);
    }

    function test_withdraw_revertsForNonAdminSigner() public {
        vm.prank(owner);
        
        address fakeSafe = makeAddr("fakeSafe");
        uint128 amountToWithdraw = 1000 * 10**18;
        deal(address(fraxusd), address(fakeSafe), amountToWithdraw);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            fraxModule.WITHDRAW_SIG(),
            block.chainid,
            address(fraxModule),
            uint256(0), // nonce
            fakeSafe,
            abi.encode(amountToWithdraw) 
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory invalidSignature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(ModuleBase.OnlyEtherFiSafe.selector);
        fraxModule.withdraw(address(fakeSafe), amountToWithdraw, owner1, invalidSignature);
    }
}
