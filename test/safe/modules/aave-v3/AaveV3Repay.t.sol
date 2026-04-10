// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AaveV3TestSetup, MessageHashUtils, AaveV3Module, ModuleBase, ModuleCheckBalance, IDebtManager, IERC20 } from "./AaveV3TestSetup.t.sol";

contract AaveV3RepayTest is AaveV3TestSetup {
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
            abi.encode(eth, collateralAmount)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        aaveV3Module.supply(address(safe), eth, collateralAmount, owner1, signature);

        uint256 amountToBorrow = 100e6;
        deal(address(usdc), chainConfig.aaveV3Pool, amountToBorrow * 10);
        
        bytes32 borrowDigestHash = keccak256(abi.encodePacked(
            aaveV3Module.BORROW_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(address(usdc), amountToBorrow)
        )).toEthSignedMessageHash();

        (uint8 bv, bytes32 br, bytes32 bs) = vm.sign(owner1Pk, borrowDigestHash);
        bytes memory borrowSignature = abi.encodePacked(br, bs, bv);

        aaveV3Module.borrow(address(safe), address(usdc), amountToBorrow, owner1, borrowSignature);
    }

    function test_repay_repaysDebt() public {        
        uint256 amountToRepay = 50e6;
        deal(address(usdc), address(safe), amountToRepay);

        uint256 balanceBefore = usdc.balanceOf(address(safe));

        bytes32 digestHash = keccak256(abi.encodePacked(
            aaveV3Module.REPAY_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(address(usdc), amountToRepay)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectEmit(true, true, true, true);
        emit AaveV3Module.RepayOnAave(address(safe), address(usdc), amountToRepay);
        aaveV3Module.repay(address(safe), address(usdc), amountToRepay, owner1, signature);

        uint256 balanceAfter = usdc.balanceOf(address(safe));
        assertEq(balanceBefore - balanceAfter, amountToRepay);
    }
    
    function test_repay_repaysFullDebtIfAmountIsMax() public {        
        uint256 amountToRepay = type(uint256).max;

        uint256 totalDebt = aaveV3Module.getTokenTotalBorrowAmount(address(safe), address(usdc));
        deal(address(usdc), address(safe), 1 ether);

        uint256 balanceBefore = usdc.balanceOf(address(safe));

        bytes32 digestHash = keccak256(abi.encodePacked(
            aaveV3Module.REPAY_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(address(usdc), amountToRepay)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectEmit(true, true, true, true);
        emit AaveV3Module.RepayOnAave(address(safe), address(usdc), totalDebt);
        aaveV3Module.repay(address(safe), address(usdc), amountToRepay, owner1, signature);

        uint256 balanceAfter = usdc.balanceOf(address(safe));
        assertEq(balanceBefore - balanceAfter, totalDebt);
    }

    function test_repay_revertsForAmountZero() public {        
        uint256 amountToRepay = 0;
        deal(address(usdc), address(safe), amountToRepay);

        bytes32 digestHash = keccak256(abi.encodePacked(
            aaveV3Module.REPAY_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(address(usdc), amountToRepay)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        aaveV3Module.repay(address(safe), address(usdc), amountToRepay, owner1, signature);
    }

    function test_repay_repaysETHDebt() public {
        // Setup to borrow ETH first
        uint256 collateralAmount = 1000e6;
        deal(address(usdc), address(safe), collateralAmount);

        bytes32 supplyDigestHash = keccak256(abi.encodePacked(
            aaveV3Module.SUPPLY_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(address(usdc), collateralAmount)
        )).toEthSignedMessageHash();

        (uint8 sv, bytes32 sr, bytes32 ss) = vm.sign(owner1Pk, supplyDigestHash);
        bytes memory supplySignature = abi.encodePacked(sr, ss, sv);

        aaveV3Module.supply(address(safe), address(usdc), collateralAmount, owner1, supplySignature);

        // Borrow ETH
        uint256 amountToBorrow = 1 ether;
        deal(chainConfig.weth, chainConfig.aaveV3Pool, amountToBorrow * 10);
        
        bytes32 borrowDigestHash = keccak256(abi.encodePacked(
            aaveV3Module.BORROW_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(eth, amountToBorrow)
        )).toEthSignedMessageHash();

        (uint8 bv, bytes32 br, bytes32 bs) = vm.sign(owner1Pk, borrowDigestHash);
        bytes memory borrowSignature = abi.encodePacked(br, bs, bv);

        aaveV3Module.borrow(address(safe), eth, amountToBorrow, owner1, borrowSignature);

        // Now repay ETH debt
        uint256 amountToRepay = 0.5 ether;
        uint256 balanceBefore = address(safe).balance;
        
        bytes32 repayDigestHash = keccak256(abi.encodePacked(
            aaveV3Module.REPAY_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(eth, amountToRepay)
        )).toEthSignedMessageHash();

        (uint8 rv, bytes32 rr, bytes32 rs) = vm.sign(owner1Pk, repayDigestHash);
        bytes memory repaySignature = abi.encodePacked(rr, rs, rv);

        aaveV3Module.repay(address(safe), eth, amountToRepay, owner1, repaySignature);

        uint256 balanceAfter = address(safe).balance;
        assertEq(balanceBefore - balanceAfter, amountToRepay);
    }

    function test_repay_reverts_whenInsufficientBalance() public {        
        uint256 amountToRepay = 200e6; // More than we borrowed
        uint256 currentBalance = 50e6;
        deal(address(usdc), address(safe), currentBalance); // Not enough balance

        bytes32 digestHash = keccak256(abi.encodePacked(
            aaveV3Module.REPAY_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(address(usdc), amountToRepay)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        aaveV3Module.repay(address(safe), address(usdc), amountToRepay, owner1, signature);
    }

    function test_repay_reverts_whenSignatureIsInvalid() public {        
        uint256 amountToRepay = 50e6;
        deal(address(usdc), address(safe), amountToRepay);

        bytes32 wrongDigestHash = keccak256("wrong message").toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, wrongDigestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        aaveV3Module.repay(address(safe), address(usdc), amountToRepay, owner1, signature);
    }

    function test_repay_reverts_whenUserCashPositionNotHealthy() public {        
        vm.mockCallRevert(
            address(debtManager), 
            abi.encodeWithSelector(IDebtManager.ensureHealth.selector, address(safe)), 
            abi.encodeWithSelector(IDebtManager.AccountUnhealthy.selector)
        );

        uint256 amountToRepay = 50e6;
        deal(address(usdc), address(safe), amountToRepay);

        bytes32 digestHash = keccak256(abi.encodePacked(
            aaveV3Module.REPAY_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(address(usdc), amountToRepay)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(IDebtManager.AccountUnhealthy.selector);
        aaveV3Module.repay(address(safe), address(usdc), amountToRepay, owner1, signature);
    }
}