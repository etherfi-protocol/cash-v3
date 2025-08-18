// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AaveV3TestSetup, MessageHashUtils, AaveV3Module, ModuleBase, IDebtManager, IERC20 } from "./AaveV3TestSetup.t.sol";

contract AaveV3WithdrawTest is AaveV3TestSetup {
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

    function test_withdraw_withdrawsTokensFromPool() public {        
        uint256 collateralAmount = 100e6;
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

        uint256 amountToWithdraw = 50e6;
        uint256 balanceBefore = usdcScroll.balanceOf(address(safe));

        bytes32 withdrawDigestHash = keccak256(abi.encodePacked(
            aaveV3Module.WITHDRAW_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(address(usdcScroll), amountToWithdraw)
        )).toEthSignedMessageHash();

        (uint8 wv, bytes32 wr, bytes32 ws) = vm.sign(owner1Pk, withdrawDigestHash);
        bytes memory withdrawSignature = abi.encodePacked(wr, ws, wv);

        vm.expectEmit(true, true, true, true);
        emit AaveV3Module.WithdrawFromAave(address(safe), address(usdcScroll), amountToWithdraw);
        aaveV3Module.withdraw(address(safe), address(usdcScroll), amountToWithdraw, owner1, withdrawSignature);

        uint256 balanceAfter = usdcScroll.balanceOf(address(safe));
        assertEq(balanceAfter - balanceBefore, amountToWithdraw);
    }

    function test_withdraw_withdrawsAllTokensFromPoolIfAmountIsMax() public {        
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

        uint256 amountToWithdraw = type(uint256).max;
        uint256 balanceBefore = usdcScroll.balanceOf(address(safe));

        bytes32 withdrawDigestHash = keccak256(abi.encodePacked(
            aaveV3Module.WITHDRAW_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(address(usdcScroll), amountToWithdraw)
        )).toEthSignedMessageHash();

        (uint8 wv, bytes32 wr, bytes32 ws) = vm.sign(owner1Pk, withdrawDigestHash);
        bytes memory withdrawSignature = abi.encodePacked(wr, ws, wv);

        vm.expectEmit(true, true, true, false);
        emit AaveV3Module.WithdrawFromAave(address(safe), address(usdcScroll), collateralAmount);
        aaveV3Module.withdraw(address(safe), address(usdcScroll), amountToWithdraw, owner1, withdrawSignature);

        uint256 balanceAfter = usdcScroll.balanceOf(address(safe));
        assertApproxEqAbs(balanceAfter - balanceBefore, collateralAmount, 10);
    }

    function test_withdraw_withdrawsETHFromPool() public {
        uint256 amountToWithdraw = 2 ether;
        uint256 balanceBefore = address(safe).balance;

        bytes32 withdrawDigestHash = keccak256(abi.encodePacked(
            aaveV3Module.WITHDRAW_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(ETH, amountToWithdraw)
        )).toEthSignedMessageHash();

        (uint8 wv, bytes32 wr, bytes32 ws) = vm.sign(owner1Pk, withdrawDigestHash);
        bytes memory withdrawSignature = abi.encodePacked(wr, ws, wv);

        aaveV3Module.withdraw(address(safe), ETH, amountToWithdraw, owner1, withdrawSignature);

        uint256 balanceAfter = address(safe).balance;
        assertEq(balanceAfter - balanceBefore, amountToWithdraw);
    }

    function test_withdraw_revertsForAmountZero() public {
        uint256 amountToWithdraw = 0;

        bytes32 withdrawDigestHash = keccak256(abi.encodePacked(
            aaveV3Module.WITHDRAW_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(ETH, amountToWithdraw)
        )).toEthSignedMessageHash();

        (uint8 wv, bytes32 wr, bytes32 ws) = vm.sign(owner1Pk, withdrawDigestHash);
        bytes memory withdrawSignature = abi.encodePacked(wr, ws, wv);

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        aaveV3Module.withdraw(address(safe), ETH, amountToWithdraw, owner1, withdrawSignature);
    }

    function test_withdraw_reverts_whenSignerIsNotAdmin() public {        
        uint256 amountToWithdraw = 50e6;

        bytes32 digestHash = keccak256(abi.encodePacked(
            aaveV3Module.WITHDRAW_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(address(usdcScroll), amountToWithdraw)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(notOwnerPk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleBase.OnlySafeAdmin.selector);
        aaveV3Module.withdraw(address(safe), address(usdcScroll), amountToWithdraw, notOwner, signature);
    }

    function test_withdraw_incrementsNonce() public {        
        uint256 collateralAmount = 100e6;
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

        uint256 amountToWithdraw = 50e6;
        uint256 balanceBefore = usdcScroll.balanceOf(address(safe));

        bytes32 withdrawDigestHash = keccak256(abi.encodePacked(
            aaveV3Module.WITHDRAW_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(address(usdcScroll), amountToWithdraw)
        )).toEthSignedMessageHash();

        (uint8 wv, bytes32 wr, bytes32 ws) = vm.sign(owner1Pk, withdrawDigestHash);
        bytes memory withdrawSignature = abi.encodePacked(wr, ws, wv);

        uint256 nonceBefore = aaveV3Module.getNonce(address(safe));

        aaveV3Module.withdraw(address(safe), address(usdcScroll), amountToWithdraw, owner1, withdrawSignature);

        uint256 balanceAfter = usdcScroll.balanceOf(address(safe));
        assertEq(balanceAfter - balanceBefore, amountToWithdraw);

        uint256 nonceAfter = aaveV3Module.getNonce(address(safe));
        assertEq(nonceAfter, nonceBefore + 1);
    }
}