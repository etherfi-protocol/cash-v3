// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AaveV3TestSetup, MessageHashUtils, AaveV3Module, ModuleBase, IDebtManager, IERC20 } from "./AaveV3TestSetup.t.sol";

contract AaveV3RepayTest is AaveV3TestSetup {
    using MessageHashUtils for bytes32;

    address wethScroll = 0x5300000000000000000000000000000000000004;

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

        uint256 amountToBorrow = 100e6;
        deal(address(usdcScroll), aaveV3PoolScroll, amountToBorrow * 10);
        
        bytes32 borrowDigestHash = keccak256(abi.encodePacked(
            aaveV3Module.BORROW_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(address(usdcScroll), amountToBorrow)
        )).toEthSignedMessageHash();

        (uint8 bv, bytes32 br, bytes32 bs) = vm.sign(owner1Pk, borrowDigestHash);
        bytes memory borrowSignature = abi.encodePacked(br, bs, bv);

        aaveV3Module.borrow(address(safe), address(usdcScroll), amountToBorrow, owner1, borrowSignature);
    }

    function test_repay_repaysDebt() public {        
        uint256 amountToRepay = 50e6;
        deal(address(usdcScroll), address(safe), amountToRepay);

        uint256 balanceBefore = usdcScroll.balanceOf(address(safe));

        bytes32 digestHash = keccak256(abi.encodePacked(
            aaveV3Module.REPAY_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(address(usdcScroll), amountToRepay)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        aaveV3Module.repay(address(safe), address(usdcScroll), amountToRepay, owner1, signature);

        uint256 balanceAfter = usdcScroll.balanceOf(address(safe));
        assertEq(balanceBefore - balanceAfter, amountToRepay);
    }

    function test_repay_revertsForAmountZero() public {        
        uint256 amountToRepay = 0;
        deal(address(usdcScroll), address(safe), amountToRepay);

        bytes32 digestHash = keccak256(abi.encodePacked(
            aaveV3Module.REPAY_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(address(usdcScroll), amountToRepay)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        aaveV3Module.repay(address(safe), address(usdcScroll), amountToRepay, owner1, signature);
    }

    function test_repay_repaysETHDebt() public {
        // Setup to borrow ETH first
        uint256 collateralAmount = 1000e6;
        deal(address(usdcScroll), address(safe), collateralAmount);

        bytes32 supplyDigestHash = keccak256(abi.encodePacked(
            aaveV3Module.SUPPLY_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(address(usdcScroll), collateralAmount)
        )).toEthSignedMessageHash();

        (uint8 sv, bytes32 sr, bytes32 ss) = vm.sign(owner1Pk, supplyDigestHash);
        bytes memory supplySignature = abi.encodePacked(sr, ss, sv);

        aaveV3Module.supply(address(safe), address(usdcScroll), collateralAmount, owner1, supplySignature);

        // Borrow ETH
        uint256 amountToBorrow = 1 ether;
        deal(address(wethScroll), aaveV3PoolScroll, amountToBorrow * 10);
        
        bytes32 borrowDigestHash = keccak256(abi.encodePacked(
            aaveV3Module.BORROW_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(ETH, amountToBorrow)
        )).toEthSignedMessageHash();

        (uint8 bv, bytes32 br, bytes32 bs) = vm.sign(owner1Pk, borrowDigestHash);
        bytes memory borrowSignature = abi.encodePacked(br, bs, bv);

        aaveV3Module.borrow(address(safe), ETH, amountToBorrow, owner1, borrowSignature);

        // Now repay ETH debt
        uint256 amountToRepay = 0.5 ether;
        uint256 balanceBefore = address(safe).balance;
        
        bytes32 repayDigestHash = keccak256(abi.encodePacked(
            aaveV3Module.REPAY_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(ETH, amountToRepay)
        )).toEthSignedMessageHash();

        (uint8 rv, bytes32 rr, bytes32 rs) = vm.sign(owner1Pk, repayDigestHash);
        bytes memory repaySignature = abi.encodePacked(rr, rs, rv);

        aaveV3Module.repay(address(safe), ETH, amountToRepay, owner1, repaySignature);

        uint256 balanceAfter = address(safe).balance;
        assertEq(balanceBefore - balanceAfter, amountToRepay);
    }

    function test_repay_reverts_whenInsufficientBalance() public {        
        uint256 amountToRepay = 200e6; // More than we borrowed
        uint256 currentBalance = 50e6;
        deal(address(usdcScroll), address(safe), currentBalance); // Not enough balance

        bytes32 digestHash = keccak256(abi.encodePacked(
            aaveV3Module.REPAY_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(address(usdcScroll), amountToRepay)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(AaveV3Module.InsufficientBalanceOnSafe.selector);
        aaveV3Module.repay(address(safe), address(usdcScroll), amountToRepay, owner1, signature);
    }

    function test_repay_reverts_whenSignatureIsInvalid() public {        
        uint256 amountToRepay = 50e6;
        deal(address(usdcScroll), address(safe), amountToRepay);

        bytes32 wrongDigestHash = keccak256("wrong message").toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, wrongDigestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        aaveV3Module.repay(address(safe), address(usdcScroll), amountToRepay, owner1, signature);
    }

    function test_repay_reverts_whenUserCashPositionNotHealthy() public {        
        vm.mockCallRevert(
            address(debtManager), 
            abi.encodeWithSelector(IDebtManager.ensureHealth.selector, address(safe)), 
            abi.encodeWithSelector(IDebtManager.AccountUnhealthy.selector)
        );

        uint256 amountToRepay = 50e6;
        deal(address(usdcScroll), address(safe), amountToRepay);

        bytes32 digestHash = keccak256(abi.encodePacked(
            aaveV3Module.REPAY_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(address(usdcScroll), amountToRepay)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(IDebtManager.AccountUnhealthy.selector);
        aaveV3Module.repay(address(safe), address(usdcScroll), amountToRepay, owner1, signature);
    }
}