// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { Test } from "forge-std/Test.sol";

import { AaveV3Module, ModuleBase } from "../../../../src/modules/aave-v3/AaveV3Module.sol";
import { ArrayDeDupLib, EtherFiDataProvider, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup } from "../../SafeTestSetup.t.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract AaveV3ModuleTest is SafeTestSetup {
    using MessageHashUtils for bytes32;

    AaveV3Module public aaveV3Module;
    address public aaveV3PoolScroll = 0x11fCfe756c05AD438e312a7fd934381537D3cFfe;
    IERC20 public usdcScroll = IERC20(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);

    function setUp() public override {
        vm.createSelectFork("https://rpc.scroll.io");

        super.setUp();

        aaveV3Module = new AaveV3Module(aaveV3PoolScroll, address(dataProvider));

        address[] memory modules = new address[](1);
        modules[0] = address(aaveV3Module);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.prank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);

        bytes[] memory setupData = new bytes[](1);

        _configureModules(modules, shouldWhitelist, setupData);
    }

    // supplyAdmin tests
    function test_supplyAdmin_transfersTokensToPool() public {
        uint256 amountToSupply = 100e6;
        deal(address(usdcScroll), address(safe), amountToSupply);

        uint256 balanceBefore = usdcScroll.balanceOf(address(safe));

        vm.prank(owner1);
        aaveV3Module.supplyAdmin(address(safe), address(usdcScroll), amountToSupply);

        uint256 balanceAfter = usdcScroll.balanceOf(address(safe));

        assertEq(balanceBefore - balanceAfter, amountToSupply);
    }

    function test_supplyAdmin_reverts_whenAccountIsNotADeployedSafe() public {
        address notSafe = makeAddr("safe");
        uint256 amountToSupply = 100e6;
        deal(address(usdcScroll), address(notSafe), amountToSupply);

        vm.prank(owner1);
        vm.expectRevert(ModuleBase.OnlyEtherFiSafe.selector);
        aaveV3Module.supplyAdmin(address(notSafe), address(usdcScroll), amountToSupply);
    }

    function test_supplyAdmin_reverts_whenCallerIsNotAdmin() public {
        uint256 amountToSupply = 100e6;
        deal(address(usdcScroll), address(safe), amountToSupply);

        vm.prank(notOwner);
        vm.expectRevert(ModuleBase.OnlySafeAdmin.selector);
        aaveV3Module.supplyAdmin(address(safe), address(usdcScroll), amountToSupply);
    }

    function test_supplyAdmin_reverts_whenSafeHasInsufficientBalance() public {
        uint256 amountToSupply = 100e6;

        vm.prank(owner1);
        vm.expectRevert(AaveV3Module.InsufficientBalanceOnSafe.selector);
        aaveV3Module.supplyAdmin(address(safe), address(usdcScroll), amountToSupply);
    }

    // supplyWithSignature tests
    function test_supplyWithSignature_transfersTokensToPool() public {
        uint256 amountToSupply = 100e6;
        deal(address(usdcScroll), address(safe), amountToSupply);

        bytes32 digestHash = keccak256(abi.encode(aaveV3Module.SUPPLY_SIG(), block.chainid, address(aaveV3Module), aaveV3Module.getNonce(address(safe)), address(safe), address(usdcScroll), amountToSupply)).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 balanceBefore = usdcScroll.balanceOf(address(safe));

        aaveV3Module.supplyWithSignature(address(safe), address(usdcScroll), amountToSupply, owner1, signature);

        uint256 balanceAfter = usdcScroll.balanceOf(address(safe));

        assertEq(balanceBefore - balanceAfter, amountToSupply);
    }

    function test_supplyWithSignature_reverts_whenSafeHasInsufficientBalance() public {
        uint256 amountToSupply = 100e6;
        // Not providing any tokens to the safe

        bytes32 digestHash = keccak256(abi.encode(aaveV3Module.SUPPLY_SIG(), block.chainid, address(aaveV3Module), aaveV3Module.getNonce(address(safe)), address(safe), address(usdcScroll), amountToSupply)).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(AaveV3Module.InsufficientBalanceOnSafe.selector);
        aaveV3Module.supplyWithSignature(address(safe), address(usdcScroll), amountToSupply, owner1, signature);
    }

    function test_supplyWithSignature_reverts_whenSignerIsNotAdmin() public {
        uint256 amountToSupply = 100e6;
        deal(address(usdcScroll), address(safe), amountToSupply);

        bytes32 digestHash = keccak256(abi.encode(aaveV3Module.SUPPLY_SIG(), block.chainid, address(aaveV3Module), aaveV3Module.getNonce(address(safe)), address(safe), address(usdcScroll), amountToSupply)).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(notOwnerPk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleBase.OnlySafeAdmin.selector);
        aaveV3Module.supplyWithSignature(address(safe), address(usdcScroll), amountToSupply, notOwner, signature);
    }

    function test_supplyWithSignature_reverts_whenSignatureIsInvalid() public {
        uint256 amountToSupply = 100e6;
        deal(address(usdcScroll), address(safe), amountToSupply);

        bytes32 wrongDigestHash = keccak256("wrong message").toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, wrongDigestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        aaveV3Module.supplyWithSignature(address(safe), address(usdcScroll), amountToSupply, owner1, signature);
    }

    function test_supplyWithSignature_incrementsNonce() public {
        uint256 amountToSupply = 100e6;
        deal(address(usdcScroll), address(safe), amountToSupply * 2);

        uint256 nonceBefore = aaveV3Module.getNonce(address(safe));

        bytes32 digestHash = keccak256(abi.encode(aaveV3Module.SUPPLY_SIG(), block.chainid, address(aaveV3Module), nonceBefore, address(safe), address(usdcScroll), amountToSupply)).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        aaveV3Module.supplyWithSignature(address(safe), address(usdcScroll), amountToSupply, owner1, signature);

        uint256 nonceAfter = aaveV3Module.getNonce(address(safe));

        assertEq(nonceAfter, nonceBefore + 1);
    }

    function test_supplyWithSignature_reverts_whenReplayingSignature() public {
        uint256 amountToSupply = 100e6;
        deal(address(usdcScroll), address(safe), amountToSupply * 2);

        uint256 nonce = aaveV3Module.getNonce(address(safe));

        bytes32 digestHash = keccak256(abi.encode(aaveV3Module.SUPPLY_SIG(), block.chainid, address(aaveV3Module), nonce, address(safe), address(usdcScroll), amountToSupply)).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // First supply should succeed
        aaveV3Module.supplyWithSignature(address(safe), address(usdcScroll), amountToSupply, owner1, signature);

        // Second supply with same signature should fail
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        aaveV3Module.supplyWithSignature(address(safe), address(usdcScroll), amountToSupply, owner1, signature);
    }
}
