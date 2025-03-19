// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Test } from "forge-std/Test.sol";

import { OpenOceanSwapModule, ModuleBase } from "../../../../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { ArrayDeDupLib, EtherFiDataProvider, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup, IDebtManager } from "../../SafeTestSetup.t.sol";

contract OpenOceanSwapModuleTest is SafeTestSetup {
    using MessageHashUtils for bytes32;

    OpenOceanSwapModule public openOceanSwapModule;
    address public openOceanSwapRouter = 0x6352a56caadC4F1E25CD6c75970Fa768A3304e64;
    address public ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function setUp() public override {
        super.setUp();

        openOceanSwapModule = new OpenOceanSwapModule(openOceanSwapRouter, address(dataProvider));

        address[] memory modules = new address[](1);
        modules[0] = address(openOceanSwapModule);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.prank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);

        bytes[] memory setupData = new bytes[](1);

        _configureModules(modules, shouldWhitelist, setupData);
    }

    function test_swap_worksWithERC20toERC20() public {
        address fromAsset = address(usdcScroll);
        uint256 fromAssetAmount = 100e6;
        address toAsset = address(weETHScroll);
        uint256 minToAssetAmount = 1;
        uint256 guaranteedAmount = 1;
        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid), 
            address(safe), 
            address(safe), 
            fromAsset, 
            toAsset, 
            fromAssetAmount, 
            IERC20Metadata(fromAsset).decimals()
        );

        deal(address(usdcScroll), address(safe), fromAssetAmount);
        
        uint256 nonceBefore = openOceanSwapModule.getNonce(address(safe));

        bytes memory signature = _createSwapSignature(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData);

        uint256 balanceBefore = weETHScroll.balanceOf(address(safe));

        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData, owner1, signature);

        uint256 balanceAfter = weETHScroll.balanceOf(address(safe));

        assertGt(balanceAfter, balanceBefore);
    }

    function test_swap_worksWithERC20toNative() public {
        address fromAsset = address(usdcScroll);
        uint256 fromAssetAmount = 100e6;
        address toAsset = ETH;
        uint256 minToAssetAmount = 1;
        uint256 guaranteedAmount = 1;
        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid), 
            address(safe), 
            address(safe), 
            fromAsset, 
            toAsset, 
            fromAssetAmount, 
            IERC20Metadata(fromAsset).decimals()
        );

        deal(address(usdcScroll), address(safe), fromAssetAmount);
        
        uint256 nonceBefore = openOceanSwapModule.getNonce(address(safe));

        bytes memory signature = _createSwapSignature(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData);

        uint256 balanceBefore = address(safe).balance;

        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData, owner1, signature);

        uint256 balanceAfter = address(safe).balance;

        assertGt(balanceAfter, balanceBefore);
    }

    function test_swap_worksWithNativeToERC20() public {
        address fromAsset = ETH;
        uint256 fromAssetAmount = 1 ether;
        address toAsset = address(usdcScroll);
        uint256 minToAssetAmount = 1;
        uint256 guaranteedAmount = 1;
        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid), 
            address(safe), 
            address(safe), 
            fromAsset, 
            toAsset, 
            fromAssetAmount, 
            18
        );

        deal(address(safe), fromAssetAmount);
        
        uint256 nonceBefore = openOceanSwapModule.getNonce(address(safe));

        bytes memory signature = _createSwapSignature(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData);

        uint256 balanceBefore = usdcScroll.balanceOf(address(safe));

        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData, owner1, signature);

        uint256 balanceAfter = usdcScroll.balanceOf(address(safe));

        assertGt(balanceAfter, balanceBefore);
    }

    function test_swap_revertsWhenSwappingToSameAsset() public {
        address fromAsset = address(usdcScroll);
        uint256 fromAssetAmount = 100e6;
        address toAsset = address(usdcScroll); // Same asset
        uint256 minToAssetAmount = 1;
        uint256 guaranteedAmount = 1;
        bytes memory swapData = "";

        deal(address(usdcScroll), address(safe), fromAssetAmount);
        
        uint256 nonceBefore = openOceanSwapModule.getNonce(address(safe));

        bytes memory signature = _createSwapSignature(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData);

        vm.expectRevert(OpenOceanSwapModule.SwappingToSameAsset.selector);
        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData, owner1, signature);
    }

    function test_swap_revertsWhenInsufficientERC20Balance() public {
        address fromAsset = address(usdcScroll);
        uint256 fromAssetAmount = 100e6;
        address toAsset = address(weETHScroll);
        uint256 minToAssetAmount = 1;
        uint256 guaranteedAmount = 1;
        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid), 
            address(safe), 
            address(safe), 
            fromAsset, 
            toAsset, 
            fromAssetAmount, 
            IERC20Metadata(fromAsset).decimals()
        );

        // Not providing any balance to the safe
        
        uint256 nonceBefore = openOceanSwapModule.getNonce(address(safe));

        bytes memory signature = _createSwapSignature(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData);

        vm.expectRevert(OpenOceanSwapModule.InsufficientBalanceOnSafe.selector);
        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData, owner1, signature);
    }

    function test_swap_revertsWhenInsufficientNativeBalance() public {
        address fromAsset = ETH;
        uint256 fromAssetAmount = 1 ether;
        address toAsset = address(usdcScroll);
        uint256 minToAssetAmount = 1;
        uint256 guaranteedAmount = 1;
        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid), 
            address(safe), 
            address(safe), 
            fromAsset, 
            toAsset, 
            fromAssetAmount, 
            18
        );

        // Not providing any ETH to the safe
        
        uint256 nonceBefore = openOceanSwapModule.getNonce(address(safe));

        bytes memory signature = _createSwapSignature(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData);

        vm.expectRevert(OpenOceanSwapModule.InsufficientBalanceOnSafe.selector);
        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData, owner1, signature);
    }

    function test_swap_revertsWhenZeroMinimumOutput() public {
        address fromAsset = address(usdcScroll);
        uint256 fromAssetAmount = 100e6;
        address toAsset = address(weETHScroll);
        uint256 minToAssetAmount = 0; // Zero minimum output
        uint256 guaranteedAmount = 1;
        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid), 
            address(safe), 
            address(safe), 
            fromAsset, 
            toAsset, 
            fromAssetAmount, 
            IERC20Metadata(fromAsset).decimals()
        );

        deal(address(usdcScroll), address(safe), fromAssetAmount);
        
        uint256 nonceBefore = openOceanSwapModule.getNonce(address(safe));

        bytes memory signature = _createSwapSignature(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData);

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData, owner1, signature);
    }

    function test_swap_revertsWithInvalidSignature() public {
        address fromAsset = address(usdcScroll);
        uint256 fromAssetAmount = 100e6;
        address toAsset = address(weETHScroll);
        uint256 minToAssetAmount = 1;
        uint256 guaranteedAmount = 1;
        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid), 
            address(safe), 
            address(safe), 
            fromAsset, 
            toAsset, 
            fromAssetAmount, 
            IERC20Metadata(fromAsset).decimals()
        );

        deal(address(usdcScroll), address(safe), fromAssetAmount);
        
        uint256 nonceBefore = openOceanSwapModule.getNonce(address(safe));

        // Create signature with wrong parameters (different amount)
        bytes memory signature = _createSwapSignature(nonceBefore, fromAsset, toAsset, fromAssetAmount + 1, minToAssetAmount, guaranteedAmount, swapData);

        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData, owner1, signature);
    }

    function test_swap_revertsWhenNonAdminSigner() public {
        address fromAsset = address(usdcScroll);
        uint256 fromAssetAmount = 100e6;
        address toAsset = address(weETHScroll);
        uint256 minToAssetAmount = 1;
        uint256 guaranteedAmount = 1;
        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid), 
            address(safe), 
            address(safe), 
            fromAsset, 
            toAsset, 
            fromAssetAmount, 
            IERC20Metadata(fromAsset).decimals()
        );

        deal(address(usdcScroll), address(safe), fromAssetAmount);
        
        uint256 nonceBefore = openOceanSwapModule.getNonce(address(safe));

        bytes memory signature = _createSwapSignature(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData);

        // Try with non-admin signer
        address nonAdmin = makeAddr("nonAdmin");
        vm.expectRevert(ModuleBase.OnlySafeAdmin.selector);
        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData, nonAdmin, signature);
    }

    function test_swap_correctlyIncrementsNonce() public {
        address fromAsset = address(usdcScroll);
        uint256 fromAssetAmount = 100e6;
        address toAsset = address(weETHScroll);
        uint256 minToAssetAmount = 1;
        uint256 guaranteedAmount = 1;
        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid), 
            address(safe), 
            address(safe), 
            fromAsset, 
            toAsset, 
            fromAssetAmount, 
            IERC20Metadata(fromAsset).decimals()
        );

        deal(address(usdcScroll), address(safe), fromAssetAmount * 2);
        
        uint256 nonceBefore = openOceanSwapModule.getNonce(address(safe));

        bytes memory signature = _createSwapSignature(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData);

        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData, owner1, signature);

        uint256 nonceAfter = openOceanSwapModule.getNonce(address(safe));
        assertEq(nonceAfter, nonceBefore + 1);

        // Try to reuse the same signature (should fail)
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData, owner1, signature);

        // Create a new signature with updated nonce and try again
        bytes memory newSignature = _createSwapSignature(nonceAfter, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData);
        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData, owner1, newSignature);

        uint256 nonceFinal = openOceanSwapModule.getNonce(address(safe));
        assertEq(nonceFinal, nonceAfter + 1);
    }

    function test_swap_whenMinimumOutputExceeds() public {
        address fromAsset = address(usdcScroll);
        uint256 fromAssetAmount = 100e6;
        address toAsset = address(weETHScroll);
        // Set very high minimum output that can't be achieved
        uint256 minToAssetAmount = 1000 ether;
        uint256 guaranteedAmount = 1;
        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid), 
            address(safe), 
            address(safe), 
            fromAsset, 
            toAsset, 
            fromAssetAmount, 
            IERC20Metadata(fromAsset).decimals()
        );

        deal(address(usdcScroll), address(safe), fromAssetAmount);
        
        uint256 nonceBefore = openOceanSwapModule.getNonce(address(safe));

        bytes memory signature = _createSwapSignature(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData);

        vm.expectRevert();
        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData, owner1, signature);
    }

    function test_swap_reverts_whenUserCashPositionNotHealthy() public {
        vm.mockCallRevert(
            address(debtManager), 
            abi.encodeWithSelector(IDebtManager.ensureHealth.selector, address(safe)), 
            abi.encodeWithSelector(IDebtManager.AccountUnhealthy.selector)
        );

        address fromAsset = address(usdcScroll);
        uint256 fromAssetAmount = 100e6;
        address toAsset = address(weETHScroll);
        uint256 minToAssetAmount = 1;
        uint256 guaranteedAmount = 1;
        bytes memory swapData = getQuoteOpenOcean(
            vm.toString(block.chainid), 
            address(safe), 
            address(safe), 
            fromAsset, 
            toAsset, 
            fromAssetAmount, 
            IERC20Metadata(fromAsset).decimals()
        );

        deal(address(usdcScroll), address(safe), fromAssetAmount);
        
        uint256 nonceBefore = openOceanSwapModule.getNonce(address(safe));

        bytes memory signature = _createSwapSignature(nonceBefore, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData);

        vm.expectRevert(IDebtManager.AccountUnhealthy.selector);
        openOceanSwapModule.swap(address(safe), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData, owner1, signature);
    }

    
    function _createSwapSignature(
        uint256 nonceBefore, 
        address fromAsset, 
        address toAsset, 
        uint256 fromAssetAmount, 
        uint256 minToAssetAmount, 
        uint256 guaranteedAmount, 
        bytes memory swapData
    ) internal view returns (bytes memory) {
        bytes32 digestHash = keccak256(abi.encodePacked(
            openOceanSwapModule.SWAP_SIG(), 
            block.chainid, 
            address(openOceanSwapModule), 
            nonceBefore, 
            address(safe), 
            abi.encode(fromAsset, toAsset, fromAssetAmount, minToAssetAmount, guaranteedAmount, swapData)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        return signature;
    }

    function getQuoteOpenOcean(
        string memory chainId,
        address from,
        address to,
        address srcToken,
        address dstToken,
        uint256 amount,
        uint8 srcTokenDecimals
    ) internal returns (bytes memory data) {
        string[] memory inputs = new string[](10);
        inputs[0] = "npx";
        inputs[1] = "ts-node";
        inputs[2] = "test/getQuoteOpenOcean.ts";
        inputs[3] = chainId;
        inputs[4] = vm.toString(from);
        inputs[5] = vm.toString(to);
        inputs[6] = vm.toString(srcToken);
        inputs[7] = vm.toString(dstToken);
        inputs[8] = vm.toString(amount);
        inputs[9] = vm.toString(srcTokenDecimals);

        return vm.ffi(inputs);
    }
}
