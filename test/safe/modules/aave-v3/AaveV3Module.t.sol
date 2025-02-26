// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { Test } from "forge-std/Test.sol";

import { AaveV3Module, ModuleBase } from "../../../../src/modules/aave-v3/AaveV3Module.sol";
import { ArrayDeDupLib, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup } from "../../SafeTestSetup.t.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract AaveV3ModuleTest is SafeTestSetup {
    using MessageHashUtils for bytes32;

    AaveV3Module public aaveV3Module;
    uint256 public moduleAdminPk;
    address public moduleAdmin;
    uint256 public nonAdminPk;
    address public nonAdmin;
    address public aaveV3PoolScroll = 0x11fCfe756c05AD438e312a7fd934381537D3cFfe;
    IERC20 public usdcScroll = IERC20(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);

    function setUp() public override {
        vm.createSelectFork("https://rpc.scroll.io");

        super.setUp();

        (moduleAdmin, moduleAdminPk) = makeAddrAndKey("moduleAdmin");
        (nonAdmin, nonAdminPk) = makeAddrAndKey("nonAdmin");

        aaveV3Module = new AaveV3Module(aaveV3PoolScroll);

        address[] memory modules = new address[](1);
        modules[0] = address(aaveV3Module);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.prank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);

        _configureModules(modules, shouldWhitelist, owner1Pk, owner2Pk);
        
        // Add module admin
        address[] memory accounts = new address[](1);
        accounts[0] = moduleAdmin;

        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;

        _configureModuleAdmin(address(aaveV3Module), accounts, shouldAdd, owner1Pk, owner2Pk);
    }

    // Module configuration tests
    function test_isModule_returnsTrue_whenModuleIsWhitelisted() public view {
        assertTrue(safe.isModule(address(aaveV3Module)));
    }

    function test_hasAdminRole_returnsTrue_whenAccountIsAdmin() public view {
        assertTrue(aaveV3Module.hasAdminRole(address(safe), moduleAdmin));
    }

    function test_hasAdminRole_returnsFalse_whenAccountIsNotAdmin() public view {
        assertFalse(aaveV3Module.hasAdminRole(address(safe), nonAdmin));
    }

    // supplyAdmin tests
    function test_supplyAdmin_transfersTokensToPool() public {
        uint256 amountToSupply = 100e6;
        deal(address(usdcScroll), address(safe), amountToSupply);

        uint256 balanceBefore = usdcScroll.balanceOf(address(safe));
        
        vm.prank(moduleAdmin);
        aaveV3Module.supplyAdmin(address(safe), address(usdcScroll), amountToSupply);
        
        uint256 balanceAfter = usdcScroll.balanceOf(address(safe));
        
        assertEq(balanceBefore - balanceAfter, amountToSupply);
    }

    function test_supplyAdmin_reverts_whenCallerIsNotAdmin() public {
        uint256 amountToSupply = 100e6;
        deal(address(usdcScroll), address(safe), amountToSupply);
        
        vm.prank(nonAdmin);
        vm.expectRevert(ModuleBase.OnlyAdmin.selector); // Exact error message may vary based on implementation
        aaveV3Module.supplyAdmin(address(safe), address(usdcScroll), amountToSupply);
    }

    function test_supplyAdmin_reverts_whenSafeHasInsufficientBalance() public {
        uint256 amountToSupply = 100e6;
        // Not providing any tokens to the safe
        
        vm.prank(moduleAdmin);
        vm.expectRevert(AaveV3Module.InsufficientBalanceOnSafe.selector);
        aaveV3Module.supplyAdmin(address(safe), address(usdcScroll), amountToSupply);
    }

    // supplyWithSignature tests
    function test_supplyWithSignature_transfersTokensToPool() public {
        uint256 amountToSupply = 100e6;
        deal(address(usdcScroll), address(safe), amountToSupply);

        bytes32 digestHash = keccak256(abi.encode(
            aaveV3Module.SUPPLY_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            address(usdcScroll), 
            amountToSupply
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(moduleAdminPk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 balanceBefore = usdcScroll.balanceOf(address(safe));
        
        aaveV3Module.supplyWithSignature(address(safe), address(usdcScroll), amountToSupply, moduleAdmin, signature);
        
        uint256 balanceAfter = usdcScroll.balanceOf(address(safe));
        
        assertEq(balanceBefore - balanceAfter, amountToSupply);
    }

    function test_supplyWithSignature_reverts_whenSafeHasInsufficientBalance() public {
        uint256 amountToSupply = 100e6;
        // Not providing any tokens to the safe
        
        bytes32 digestHash = keccak256(abi.encode(
            aaveV3Module.SUPPLY_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            address(usdcScroll), 
            amountToSupply
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(moduleAdminPk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(AaveV3Module.InsufficientBalanceOnSafe.selector);
        aaveV3Module.supplyWithSignature(address(safe), address(usdcScroll), amountToSupply, moduleAdmin, signature);
    }

    function test_supplyWithSignature_reverts_whenSignerIsNotAdmin() public {
        uint256 amountToSupply = 100e6;
        deal(address(usdcScroll), address(safe), amountToSupply);
        
        bytes32 digestHash = keccak256(abi.encode(
            aaveV3Module.SUPPLY_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            address(usdcScroll), 
            amountToSupply
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(nonAdminPk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(); // Exact error may vary based on implementation
        aaveV3Module.supplyWithSignature(address(safe), address(usdcScroll), amountToSupply, nonAdmin, signature);
    }

    function test_supplyWithSignature_reverts_whenSignatureIsInvalid() public {
        uint256 amountToSupply = 100e6;
        deal(address(usdcScroll), address(safe), amountToSupply);
                
        bytes32 wrongDigestHash = keccak256("wrong message").toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(moduleAdminPk, wrongDigestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(); // Exact error may vary based on implementation
        aaveV3Module.supplyWithSignature(address(safe), address(usdcScroll), amountToSupply, moduleAdmin, signature);
    }

    function test_supplyWithSignature_incrementsNonce() public {
        uint256 amountToSupply = 100e6;
        deal(address(usdcScroll), address(safe), amountToSupply * 2);

        uint256 nonceBefore = aaveV3Module.getNonce(address(safe));
        
        bytes32 digestHash = keccak256(abi.encode(
            aaveV3Module.SUPPLY_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            nonceBefore, 
            address(safe), 
            address(usdcScroll), 
            amountToSupply
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(moduleAdminPk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        aaveV3Module.supplyWithSignature(address(safe), address(usdcScroll), amountToSupply, moduleAdmin, signature);
        
        uint256 nonceAfter = aaveV3Module.getNonce(address(safe));
        
        assertEq(nonceAfter, nonceBefore + 1);
    }

    function test_supplyWithSignature_reverts_whenReplayingSignature() public {
        uint256 amountToSupply = 100e6;
        deal(address(usdcScroll), address(safe), amountToSupply * 2);

        uint256 nonce = aaveV3Module.getNonce(address(safe));
        
        bytes32 digestHash = keccak256(abi.encode(
            aaveV3Module.SUPPLY_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            nonce, 
            address(safe), 
            address(usdcScroll), 
            amountToSupply
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(moduleAdminPk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        // First supply should succeed
        aaveV3Module.supplyWithSignature(address(safe), address(usdcScroll), amountToSupply, moduleAdmin, signature);
        
        // Second supply with same signature should fail
        vm.expectRevert(); // Exact error may vary based on implementation
        aaveV3Module.supplyWithSignature(address(safe), address(usdcScroll), amountToSupply, moduleAdmin, signature);
    }

    // Admin configuration tests
    function test_configureModuleAdmin_addsAdmin() public {
        address[] memory accounts = new address[](1);
        accounts[0] = nonAdmin;

        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;

        _configureModuleAdmin(address(aaveV3Module), accounts, shouldAdd, owner1Pk, owner2Pk);
        
        assertTrue(aaveV3Module.hasAdminRole(address(safe), nonAdmin));
    }

    function test_configureModuleAdmin_removesAdmin() public {
        address[] memory accounts = new address[](1);
        accounts[0] = moduleAdmin;

        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = false;

        _configureModuleAdmin(address(aaveV3Module), accounts, shouldAdd, owner1Pk, owner2Pk);
        
        assertFalse(aaveV3Module.hasAdminRole(address(safe), moduleAdmin));
    }

    function test_configureModuleAdmin_reverts_whenSignatureIsInvalid() public {
        address[] memory accounts = new address[](1);
        accounts[0] = nonAdmin;

        bool[] memory shouldAdd = new bool[](1);
        shouldAdd[0] = true;

        bytes32 configModuleAdminHash = keccak256(abi.encode(
            aaveV3Module.CONFIG_ADMIN(),
            block.chainid,
            address(aaveV3Module),
            aaveV3Module.getNonce(address(safe)),
            address(safe),
            accounts,
            shouldAdd
        ));
        
        bytes32 digestHash = configModuleAdminHash.toEthSignedMessageHash();
        
        // Sign with incorrect private key
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(nonAdminPk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(moduleAdminPk, digestHash);
        
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        
        address[] memory signers = new address[](2);
        signers[0] = nonAdmin;
        signers[1] = moduleAdmin;
        
        vm.expectRevert(); // Exact error may vary based on implementation
        aaveV3Module.configureAdmins(address(safe), accounts, shouldAdd, signers, signatures);
    }
}