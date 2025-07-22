// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { SafeTestSetup, MessageHashUtils } from "../../SafeTestSetup.t.sol";
import { EtherFiStakeModule, ModuleCheckBalance } from "../../../../src/modules/etherfi/EtherFiStakeModule.sol";
import { ModuleBase } from "../../../../src/modules/ModuleBase.sol";
import { IL2SyncPool } from "../../../../src/interfaces/IL2SyncPool.sol";

contract EtherFiStakeModuleTest is SafeTestSetup {
    using MessageHashUtils for bytes32;

    EtherFiStakeModule public stakeModule;

    IERC20 weth = IERC20(0x5300000000000000000000000000000000000004);
    IERC20 weEth = IERC20(0x01f0a31698C4d065659b9bdC21B3610292a1c506);
    address syncPool = 0x750cf0fd3bc891D8D864B732BC4AD340096e5e68;
    address ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address randomERC20 = address(0x123); // Mock address for unsupported token
    
    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);

        stakeModule = new EtherFiStakeModule(address(dataProvider), syncPool, address(weth), address(weEth));

        address[] memory modules = new address[](1);
        modules[0] = address(stakeModule);
        
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;
        
        bytes[] memory moduleSetupData = new bytes[](1);
        moduleSetupData[0] = "";
        
        dataProvider.configureModules(modules, shouldWhitelist);
        _configureModules(modules, shouldWhitelist, moduleSetupData);

        vm.stopPrank();
    }

    function test_deposit_worksWithEth_mintsWeEthToTheSafe() public {
        uint256 amount = 1 ether;
        uint256 minReturn = 0.9 ether;
        deal(address(safe), amount);

        bytes32 digestHash = keccak256(abi.encodePacked(
            stakeModule.DEPOSIT_SIG(),
            block.chainid,
            address(stakeModule),
            stakeModule.getNonce(address(safe)),
            address(safe),
            abi.encode(ETH, amount, minReturn)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v); 

        uint256 ethBalBefore = address(safe).balance;
        uint256 weEthBalBefore = weEth.balanceOf(address(safe));
        
        stakeModule.deposit(address(safe), ETH, amount, minReturn, owner1, signature);
        
        uint256 ethBalAfter = address(safe).balance;
        uint256 weEthBalAfter = weEth.balanceOf(address(safe));

        assertEq(ethBalBefore - ethBalAfter, amount);
        assertGt(weEthBalAfter, weEthBalBefore);
    }

    function test_deposit_worksWithWeth_mintsWeEthToTheSafe() public {
        uint256 amount = 1 ether;
        uint256 minReturn = 0.9 ether;
        deal(address(weth), address(safe), amount);

        bytes32 digestHash = keccak256(abi.encodePacked(
            stakeModule.DEPOSIT_SIG(),
            block.chainid,
            address(stakeModule),
            stakeModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(weth), amount, minReturn)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v); 

        uint256 wethBalBefore = weth.balanceOf(address(safe));
        uint256 weEthBalBefore = weEth.balanceOf(address(safe));
        
        stakeModule.deposit(address(safe), address(weth), amount, minReturn, owner1, signature);
        
        uint256 wethBalAfter = weth.balanceOf(address(safe));
        uint256 weEthBalAfter = weEth.balanceOf(address(safe));

        assertEq(wethBalBefore - wethBalAfter, amount);
        assertGt(weEthBalAfter, weEthBalBefore);
    }

    // New tests start here
    
    function test_deposit_revertsOnUnsupportedAsset() public {
        uint256 amount = 1 ether;
        uint256 minReturn = 0.9 ether;
        
        // Create a mock ERC20 token
        vm.mockCall(
            randomERC20,
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(safe)),
            abi.encode(amount)
        );
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            stakeModule.DEPOSIT_SIG(),
            block.chainid,
            address(stakeModule),
            stakeModule.getNonce(address(safe)),
            address(safe),
            abi.encode(randomERC20, amount, minReturn)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(EtherFiStakeModule.UnsupportedAsset.selector);
        stakeModule.deposit(address(safe), randomERC20, amount, minReturn, owner1, signature);
    }
    
    function test_deposit_revertsOnZeroAmount() public {
        uint256 amount = 0;
        uint256 minReturn = 0.9 ether;
        deal(address(safe), 1 ether);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            stakeModule.DEPOSIT_SIG(),
            block.chainid,
            address(stakeModule),
            stakeModule.getNonce(address(safe)),
            address(safe),
            abi.encode(ETH, amount, minReturn)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        stakeModule.deposit(address(safe), ETH, amount, minReturn, owner1, signature);
    }
    
    function test_deposit_revertsOnZeroMinReturn() public {
        uint256 amount = 1 ether;
        uint256 minReturn = 0;
        deal(address(safe), amount);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            stakeModule.DEPOSIT_SIG(),
            block.chainid,
            address(stakeModule),
            stakeModule.getNonce(address(safe)),
            address(safe),
            abi.encode(ETH, amount, minReturn)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        stakeModule.deposit(address(safe), ETH, amount, minReturn, owner1, signature);
    }
    
    function test_deposit_revertsOnInsufficientBalance_ETH() public {
        uint256 amount = 2 ether;
        uint256 minReturn = 0.9 ether;
        deal(address(safe), 1 ether); // Only 1 ETH but trying to deposit 2 ETH
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            stakeModule.DEPOSIT_SIG(),
            block.chainid,
            address(stakeModule),
            stakeModule.getNonce(address(safe)),
            address(safe),
            abi.encode(ETH, amount, minReturn)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        stakeModule.deposit(address(safe), ETH, amount, minReturn, owner1, signature);
    }
    
    function test_deposit_revertsOnInsufficientBalance_WETH() public {
        uint256 amount = 2 ether;
        uint256 minReturn = 0.9 ether;
        deal(address(weth), address(safe), 1 ether); // Only 1 WETH but trying to deposit 2 WETH
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            stakeModule.DEPOSIT_SIG(),
            block.chainid,
            address(stakeModule),
            stakeModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(weth), amount, minReturn)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        stakeModule.deposit(address(safe), address(weth), amount, minReturn, owner1, signature);
    }
    
    function test_deposit_revertsOnInvalidSignature() public {
        uint256 amount = 1 ether;
        uint256 minReturn = 0.9 ether;
        deal(address(safe), amount);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            stakeModule.DEPOSIT_SIG(),
            block.chainid,
            address(stakeModule),
            stakeModule.getNonce(address(safe)),
            address(safe),
            abi.encode(ETH, amount, minReturn)
        )).toEthSignedMessageHash();

        // Sign with a different private key
        uint256 invalidPrivateKey = 0x2;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(invalidPrivateKey, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        stakeModule.deposit(address(safe), ETH, amount, minReturn, owner1, signature);
    }
    
    function test_deposit_revertsOnNonAdminSigner() public {
        uint256 amount = 1 ether;
        uint256 minReturn = 0.9 ether;
        deal(address(safe), amount);
        
        // Create a non-admin signer
        address nonAdmin = makeAddr("nonAdmin");
        uint256 nonAdminPk = 0x3;
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            stakeModule.DEPOSIT_SIG(),
            block.chainid,
            address(stakeModule),
            stakeModule.getNonce(address(safe)),
            address(safe),
            abi.encode(ETH, amount, minReturn)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(nonAdminPk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(ModuleBase.OnlySafeAdmin.selector);
        stakeModule.deposit(address(safe), ETH, amount, minReturn, nonAdmin, signature);
    }
    
    function test_deposit_revertsOnInsufficientReturnAmount() public {
        uint256 amount = 1 ether;
        uint256 minReturn = 0.9 ether;
        deal(address(safe), amount);
        
        // Mock the syncPool.deposit call to not mint enough weETH
        vm.mockCall(
            syncPool,
            abi.encodeWithSelector(IL2SyncPool.deposit.selector, ETH, amount, minReturn),
            abi.encode()
        );
        
        // Mock the weETH.balanceOf to return insufficient amounts
        vm.mockCall(
            address(weEth),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(safe)),
            abi.encode(0) // No weETH before
        );
        
        vm.mockCall(
            address(weEth),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(safe)),
            abi.encode(minReturn - 1) // Not enough weETH after
        );
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            stakeModule.DEPOSIT_SIG(),
            block.chainid,
            address(stakeModule),
            stakeModule.getNonce(address(safe)),
            address(safe),
            abi.encode(ETH, amount, minReturn)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(EtherFiStakeModule.InsufficientReturnAmount.selector);
        stakeModule.deposit(address(safe), ETH, amount, minReturn, owner1, signature);
    }
    
    function test_deposit_incrementsNonce() public {
        uint256 amount = 1 ether;
        uint256 minReturn = 0.9 ether;
        deal(address(safe), amount);
        
        uint256 nonceBefore = stakeModule.getNonce(address(safe));
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            stakeModule.DEPOSIT_SIG(),
            block.chainid,
            address(stakeModule),
            nonceBefore,
            address(safe),
            abi.encode(ETH, amount, minReturn)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        stakeModule.deposit(address(safe), ETH, amount, minReturn, owner1, signature);
        
        uint256 nonceAfter = stakeModule.getNonce(address(safe));
        assertEq(nonceAfter, nonceBefore + 1);
    }
    
    function test_deposit_preventsReplayAttack() public {
        uint256 amount = 1 ether;
        uint256 minReturn = 0.9 ether;
        deal(address(safe), amount * 2); // Give enough ETH for two deposits
        
        uint256 nonce = stakeModule.getNonce(address(safe));
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            stakeModule.DEPOSIT_SIG(),
            block.chainid,
            address(stakeModule),
            nonce,
            address(safe),
            abi.encode(ETH, amount, minReturn)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        // First deposit should succeed
        stakeModule.deposit(address(safe), ETH, amount, minReturn, owner1, signature);
        
        // Second deposit with the same signature should fail because nonce has increased
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        stakeModule.deposit(address(safe), ETH, amount, minReturn, owner1, signature);
    }
    
    function test_constructor_setsCorrectValues() public view {
        assertEq(address(stakeModule.syncPool()), syncPool);
        assertEq(stakeModule.weth(), address(weth));
        assertEq(stakeModule.weETH(), address(weEth));
    }
}