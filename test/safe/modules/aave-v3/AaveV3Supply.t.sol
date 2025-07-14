// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AaveV3TestSetup, MessageHashUtils, AaveV3Module, ModuleBase, ModuleCheckBalance, IDebtManager } from "./AaveV3TestSetup.t.sol";

contract AaveV3SupplyTest is AaveV3TestSetup {
    using MessageHashUtils for bytes32;

    // supply tests
    function test_supply_transfersTokensToPool() public {
        uint256 amountToSupply = 100e6;
        deal(address(usdcScroll), address(safe), amountToSupply);

        bytes32 digestHash = keccak256(abi.encodePacked(aaveV3Module.SUPPLY_SIG(), block.chainid, address(aaveV3Module), aaveV3Module.getNonce(address(safe)), address(safe), abi.encode(address(usdcScroll), amountToSupply))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 balanceBefore = usdcScroll.balanceOf(address(safe));

        vm.expectEmit(true, true, true, true);
        emit AaveV3Module.SupplyOnAave(address(safe), address(usdcScroll), amountToSupply);
        aaveV3Module.supply(address(safe), address(usdcScroll), amountToSupply, owner1, signature);

        uint256 balanceAfter = usdcScroll.balanceOf(address(safe));

        assertEq(balanceBefore - balanceAfter, amountToSupply);
    }

    function test_supply_revertsForAmountZero() public {
        uint256 amountToSupply = 0;
        deal(address(usdcScroll), address(safe), amountToSupply);

        bytes32 digestHash = keccak256(abi.encodePacked(aaveV3Module.SUPPLY_SIG(), block.chainid, address(aaveV3Module), aaveV3Module.getNonce(address(safe)), address(safe), abi.encode(address(usdcScroll), amountToSupply))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        aaveV3Module.supply(address(safe), address(usdcScroll), amountToSupply, owner1, signature);
    }

    // supply tests
    function test_supply_transfersEthToPool() public {
        uint256 amountToSupply = 1 ether;
        deal(address(safe), amountToSupply);

        bytes32 digestHash = keccak256(abi.encodePacked(aaveV3Module.SUPPLY_SIG(), block.chainid, address(aaveV3Module), aaveV3Module.getNonce(address(safe)), address(safe), abi.encode(ETH, amountToSupply))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 balanceBefore = address(safe).balance;

        aaveV3Module.supply(address(safe), ETH, amountToSupply, owner1, signature);

        uint256 balanceAfter = address(safe).balance;

        assertEq(balanceBefore - balanceAfter, amountToSupply);
    }

    function test_supply_reverts_whenSafeHasInsufficientBalance() public {
        uint256 amountToSupply = 100e6;
        // Not providing any tokens to the safe

        bytes32 digestHash = keccak256(abi.encodePacked(aaveV3Module.SUPPLY_SIG(), block.chainid, address(aaveV3Module), aaveV3Module.getNonce(address(safe)), address(safe), abi.encode(address(usdcScroll), amountToSupply))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        aaveV3Module.supply(address(safe), address(usdcScroll), amountToSupply, owner1, signature);
    }

    function test_supply_reverts_whenSignerIsNotAdmin() public {
        uint256 amountToSupply = 100e6;
        deal(address(usdcScroll), address(safe), amountToSupply);

        bytes32 digestHash = keccak256(abi.encodePacked(aaveV3Module.SUPPLY_SIG(), block.chainid, address(aaveV3Module), aaveV3Module.getNonce(address(safe)), address(safe), abi.encode(address(usdcScroll), amountToSupply))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(notOwnerPk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleBase.OnlySafeAdmin.selector);
        aaveV3Module.supply(address(safe), address(usdcScroll), amountToSupply, notOwner, signature);
    }

    function test_supply_reverts_whenSignatureIsInvalid() public {
        uint256 amountToSupply = 100e6;
        deal(address(usdcScroll), address(safe), amountToSupply);

        bytes32 wrongDigestHash = keccak256("wrong message").toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, wrongDigestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        aaveV3Module.supply(address(safe), address(usdcScroll), amountToSupply, owner1, signature);
    }

    function test_supply_incrementsNonce() public {
        uint256 amountToSupply = 100e6;
        deal(address(usdcScroll), address(safe), amountToSupply * 2);

        uint256 nonceBefore = aaveV3Module.getNonce(address(safe));

        bytes32 digestHash = keccak256(abi.encodePacked(aaveV3Module.SUPPLY_SIG(), block.chainid, address(aaveV3Module), nonceBefore, address(safe), abi.encode(address(usdcScroll), amountToSupply))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        aaveV3Module.supply(address(safe), address(usdcScroll), amountToSupply, owner1, signature);

        uint256 nonceAfter = aaveV3Module.getNonce(address(safe));

        assertEq(nonceAfter, nonceBefore + 1);
    }

    function test_supply_reverts_whenReplayingSignature() public {
        uint256 amountToSupply = 100e6;
        deal(address(usdcScroll), address(safe), amountToSupply * 2);

        uint256 nonce = aaveV3Module.getNonce(address(safe));

        bytes32 digestHash = keccak256(abi.encodePacked(aaveV3Module.SUPPLY_SIG(), block.chainid, address(aaveV3Module), nonce, address(safe), abi.encode(address(usdcScroll), amountToSupply))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // First supply should succeed
        aaveV3Module.supply(address(safe), address(usdcScroll), amountToSupply, owner1, signature);

        // Second supply with same signature should fail
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        aaveV3Module.supply(address(safe), address(usdcScroll), amountToSupply, owner1, signature);
    }

    function test_supply_reverts_whenUserCashPositionNotHealthy() public {
        vm.mockCallRevert(
            address(debtManager), 
            abi.encodeWithSelector(IDebtManager.ensureHealth.selector, address(safe)), 
            abi.encodeWithSelector(IDebtManager.AccountUnhealthy.selector)
        );

        uint256 amountToSupply = 100e6;
        deal(address(usdcScroll), address(safe), amountToSupply * 2);

        uint256 nonce = aaveV3Module.getNonce(address(safe));

        bytes32 digestHash = keccak256(abi.encodePacked(aaveV3Module.SUPPLY_SIG(), block.chainid, address(aaveV3Module), nonce, address(safe), abi.encode(address(usdcScroll), amountToSupply))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(IDebtManager.AccountUnhealthy.selector);
        aaveV3Module.supply(address(safe), address(usdcScroll), amountToSupply, owner1, signature);
    }
}
