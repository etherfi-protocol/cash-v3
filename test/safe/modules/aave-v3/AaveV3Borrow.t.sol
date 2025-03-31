// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AaveV3TestSetup, MessageHashUtils, AaveV3Module, ModuleBase, IDebtManager } from "./AaveV3TestSetup.t.sol";

contract AaveV3BorrowTest is AaveV3TestSetup {
    using MessageHashUtils for bytes32;

    function setUp() public override {
        super.setUp();

        uint256 collateralAmount = 10 ether;
        deal(address(safe), collateralAmount);

        bytes32 digestHash = keccak256(abi.encodePacked(
            aaveV3Module.SUPPLY_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(ETH, collateralAmount)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        aaveV3Module.supply(address(safe), ETH, collateralAmount, owner1, signature);
    }

    function test_borrow_borrowsTokensFromPool() public {
        uint256 amountToBorrow = 100e6;
            
        uint256 balanceBefore = usdcScroll.balanceOf(address(safe));

        bytes32 digestHash = keccak256(abi.encodePacked(
            aaveV3Module.BORROW_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(address(usdcScroll), amountToBorrow)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        aaveV3Module.borrow(address(safe), address(usdcScroll), amountToBorrow, owner1, signature);

        uint256 balanceAfter = usdcScroll.balanceOf(address(safe));

        assertEq(balanceAfter - balanceBefore, amountToBorrow);
    }


    function test_borrow_revertsForAmountZero() public {
        uint256 amountToBorrow = 0;
            
        bytes32 digestHash = keccak256(abi.encodePacked(
            aaveV3Module.BORROW_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(address(usdcScroll), amountToBorrow)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        aaveV3Module.borrow(address(safe), address(usdcScroll), amountToBorrow, owner1, signature);
    }

    function test_borrow_reverts_whenSignerIsNotAdmin() public {
        uint256 amountToBorrow = 100e6;

        bytes32 digestHash = keccak256(abi.encodePacked(
            aaveV3Module.BORROW_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(address(usdcScroll), amountToBorrow)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(notOwnerPk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleBase.OnlySafeAdmin.selector);
        aaveV3Module.borrow(address(safe), address(usdcScroll), amountToBorrow, notOwner, signature);
    }

    function test_borrow_reverts_whenSignatureIsInvalid() public {
        uint256 amountToBorrow = 100e6;

        bytes32 wrongDigestHash = keccak256("wrong message").toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, wrongDigestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        aaveV3Module.borrow(address(safe), address(usdcScroll), amountToBorrow, owner1, signature);
    }

    function test_borrow_incrementsNonce() public {
        uint256 amountToBorrow = 100e6;
        deal(address(usdcScroll), aaveV3PoolScroll, amountToBorrow * 10);

        uint256 nonceBefore = aaveV3Module.getNonce(address(safe));

        bytes32 digestHash = keccak256(abi.encodePacked(
            aaveV3Module.BORROW_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            nonceBefore, 
            address(safe), 
            abi.encode(address(usdcScroll), amountToBorrow)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        aaveV3Module.borrow(address(safe), address(usdcScroll), amountToBorrow, owner1, signature);

        uint256 nonceAfter = aaveV3Module.getNonce(address(safe));

        assertEq(nonceAfter, nonceBefore + 1);
    }

    function test_borrow_reverts_whenReplayingSignature() public {
        uint256 amountToBorrow = 50e6;
        deal(address(usdcScroll), aaveV3PoolScroll, amountToBorrow * 10);

        uint256 nonce = aaveV3Module.getNonce(address(safe));

        bytes32 digestHash = keccak256(abi.encodePacked(
            aaveV3Module.BORROW_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            nonce, 
            address(safe), 
            abi.encode(address(usdcScroll), amountToBorrow)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // First borrow should succeed
        aaveV3Module.borrow(address(safe), address(usdcScroll), amountToBorrow, owner1, signature);

        // Second borrow with same signature should fail
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        aaveV3Module.borrow(address(safe), address(usdcScroll), amountToBorrow, owner1, signature);
    }

    function test_borrow_borrowsETH() public {
        uint256 amountToBorrow = 1 ether;
        
        uint256 balanceBefore = address(safe).balance;

        bytes32 digestHash = keccak256(abi.encodePacked(
            aaveV3Module.BORROW_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(ETH, amountToBorrow)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        aaveV3Module.borrow(address(safe), ETH, amountToBorrow, owner1, signature);

        uint256 balanceAfter = address(safe).balance;

        assertEq(balanceAfter - balanceBefore, amountToBorrow);
    }

    function test_borrow_reverts_whenUserCashPositionNotHealthy() public {
        vm.mockCallRevert(
            address(debtManager), 
            abi.encodeWithSelector(IDebtManager.ensureHealth.selector, address(safe)), 
            abi.encodeWithSelector(IDebtManager.AccountUnhealthy.selector)
        );

        uint256 amountToBorrow = 100e6;
        deal(address(usdcScroll), aaveV3PoolScroll, amountToBorrow * 10);

        uint256 nonce = aaveV3Module.getNonce(address(safe));

        bytes32 digestHash = keccak256(abi.encodePacked(
            aaveV3Module.BORROW_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            nonce, 
            address(safe), 
            abi.encode(address(usdcScroll), amountToBorrow)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(IDebtManager.AccountUnhealthy.selector);
        aaveV3Module.borrow(address(safe), address(usdcScroll), amountToBorrow, owner1, signature);
    }
}