// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Test } from "forge-std/Test.sol";

import { StargateModule, ModuleBase } from "../../../../src/modules/stargate/StargateModule.sol";
import { ArrayDeDupLib, EtherFiDataProvider, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup, IDebtManager } from "../../SafeTestSetup.t.sol";

contract StargateModuleTest is SafeTestSetup {
    using MessageHashUtils for bytes32;

    StargateModule stargateModule;

    IERC20 weETH = IERC20(0x01f0a31698C4d065659b9bdC21B3610292a1c506);
    IERC20 usdc = IERC20(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
    address ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    
    address usdcStargatePool = 0x3Fc69CC4A842838bCDC9499178740226062b14E4;
    address ethStargatePool = 0xC2b638Cb5042c1B3c5d5C969361fB50569840583;

    uint32 mainnetDestEid = 30101;
    uint256 maxSlippage = 50; // 0.5%
    address destRecipientAddr = makeAddr("destRecipient");
    address sender = makeAddr("sender");

    function setUp() public override {
        super.setUp();

        deal(sender, 1 ether);
        
        address[] memory assets = new address[](3);
        assets[0] = address(usdc);
        assets[1] = address(weETH);
        assets[2] = address(ETH);

        StargateModule.AssetConfig[] memory assetConfigs = new StargateModule.AssetConfig[](3);
        assetConfigs[0] = StargateModule.AssetConfig({
            isOFT: false,
            pool: usdcStargatePool
        });
        assetConfigs[1] = StargateModule.AssetConfig({
            isOFT: true,
            pool: address(weETH)
        });
        assetConfigs[2] = StargateModule.AssetConfig({
            isOFT: false,
            pool: ethStargatePool
        });

        stargateModule = new StargateModule(assets, assetConfigs, address(dataProvider));

        address[] memory modules = new address[](1);
        modules[0] = address(stargateModule);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.prank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);

        bytes[] memory setupData = new bytes[](1);

        _configureModules(modules, shouldWhitelist, setupData);

        bytes32 role = stargateModule.STARGATE_MODULE_ADMIN_ROLE();
        vm.startPrank(owner);
        roleRegistry.grantRole(role, owner);
        vm.stopPrank();
    }

    function test_bridge_worksWithUsdc() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount); 

        uint256 usdcBalBefore = usdc.balanceOf(address(safe));

        _bridge(mainnetDestEid, address(usdc), amount, destRecipientAddr, maxSlippage);
        
        uint256 usdcBalAfter = usdc.balanceOf(address(safe));
        assertEq(usdcBalAfter, usdcBalBefore - amount);
    }

    function test_bridge_worksWithWeETHOft() public {
        uint256 amount = 1 ether;
        deal(address(weETH), address(safe), amount); 

        uint256 weETHBalBefore = weETH.balanceOf(address(safe));

        _bridge(mainnetDestEid, address(weETH), amount, destRecipientAddr, maxSlippage);

        uint256 weETHBalAfter = weETH.balanceOf(address(safe));
        assertEq(weETHBalAfter, weETHBalBefore - amount);
    }

    function test_bridge_worksWithETH() public {
        uint256 amount = 1 ether;
        deal(address(safe), amount); 

        uint256 ETHBalBefore = address(safe).balance;

        _bridge(mainnetDestEid, ETH, amount, destRecipientAddr, maxSlippage);

        uint256 ETHBalAfter = address(safe).balance;
        assertEq(ETHBalAfter, ETHBalBefore - amount);
    }

    function test_setAssetConfig_unauthorized() public {
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);

        StargateModule.AssetConfig[] memory assetConfigs = new StargateModule.AssetConfig[](1);
        assetConfigs[0] = StargateModule.AssetConfig({
            isOFT: true,
            pool: address(0x123)
        });

        vm.prank(notOwner);
        vm.expectRevert(StargateModule.Unauthorized.selector);
        stargateModule.setAssetConfig(assets, assetConfigs);
    }

    function test_setAssetConfig_authorized() public {
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);

        StargateModule.AssetConfig[] memory assetConfigs = new StargateModule.AssetConfig[](1);
        assetConfigs[0] = StargateModule.AssetConfig({
            isOFT: false,
            pool: usdcStargatePool
        });

        // Owner with admin role should be able to update asset config
        vm.prank(owner);
        stargateModule.setAssetConfig(assets, assetConfigs);

        // Verify config was updated
        StargateModule.AssetConfig memory config = stargateModule.getAssetConfig(address(usdc));
        assertEq(config.isOFT, false);
        assertEq(config.pool, usdcStargatePool);
    }

    function test_bridge_invalidSignatures() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);

        // Create invalid signatures
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        bytes32 fakeDigest = keccak256("fake");
        
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, fakeDigest.toEthSignedMessageHash());
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = signatures[0];

        (, uint256 bridgeFee) = stargateModule.getBridgeFee(mainnetDestEid, address(usdc), amount, destRecipientAddr, maxSlippage);

        vm.expectRevert(StargateModule.InvalidSignatures.selector);
        stargateModule.bridge{value: bridgeFee}(address(safe), mainnetDestEid, address(usdc), amount, destRecipientAddr, maxSlippage, signers, signatures);
    }

    function test_bridge_insufficientAmount() public {
        uint256 amount = 100e6;
        
        // Don't fund the safe
        
        (address[] memory signers, bytes[] memory signatures) = _getSignatures(mainnetDestEid, address(usdc), amount, destRecipientAddr, maxSlippage);
        
        (, uint256 bridgeFee) = stargateModule.getBridgeFee(mainnetDestEid, address(usdc), amount, destRecipientAddr, maxSlippage);

        // Should revert with InsufficientAmount
        vm.prank(sender);
        vm.expectRevert(StargateModule.InsufficientAmount.selector);
        stargateModule.bridge{value: bridgeFee}(address(safe), mainnetDestEid, address(usdc), amount, destRecipientAddr, maxSlippage, signers, signatures);
    }

    function test_bridge_insufficientNativeFee() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        
        (address[] memory signers, bytes[] memory signatures) = _getSignatures(mainnetDestEid, address(usdc), amount, destRecipientAddr, maxSlippage);
        
        (, uint256 bridgeFee) = stargateModule.getBridgeFee(mainnetDestEid, address(usdc), amount, destRecipientAddr, maxSlippage);

        // Provide insufficient fee
        vm.prank(sender);
        vm.expectRevert(StargateModule.InsufficientNativeFee.selector);
        stargateModule.bridge{value: bridgeFee - 1}(address(safe), mainnetDestEid, address(usdc), amount, destRecipientAddr, maxSlippage, signers, signatures);
    }

    function test_bridge_invalidInput() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        
        // Test with zero address for destRecipient
        (address[] memory signers1, bytes[] memory signatures1) = _getSignatures(mainnetDestEid, address(usdc), amount, address(0), maxSlippage);
        
        (, uint256 bridgeFee) = stargateModule.getBridgeFee(mainnetDestEid, address(usdc), amount, address(0), maxSlippage);

        vm.prank(sender);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        stargateModule.bridge{value: bridgeFee}(address(safe), mainnetDestEid, address(usdc), amount, address(0), maxSlippage, signers1, signatures1);

        // Test with zero address for asset
        (address[] memory signers2, bytes[] memory signatures2) = _getSignatures(mainnetDestEid, address(0), amount, destRecipientAddr, maxSlippage);
        
        vm.prank(sender);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        stargateModule.bridge{value: bridgeFee}(address(safe), mainnetDestEid, address(0), amount, destRecipientAddr, maxSlippage, signers2, signatures2);

        // Test with zero amount
        (address[] memory signers3, bytes[] memory signatures3) = _getSignatures(mainnetDestEid, address(usdc), 0, destRecipientAddr, maxSlippage);
        
        vm.prank(sender);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        stargateModule.bridge{value: bridgeFee}(address(safe), mainnetDestEid, address(usdc), 0, destRecipientAddr, maxSlippage, signers3, signatures3);
    }

    function test_bridge_highSlippage() public {
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        
        // Test with very high slippage which might lead to insufficient min amount
        uint256 highSlippage = 9000; // 90%
        
        (address[] memory signers, bytes[] memory signatures) = _getSignatures(mainnetDestEid, address(usdc), amount, destRecipientAddr, highSlippage);
        
        (, uint256 bridgeFee) = stargateModule.getBridgeFee(mainnetDestEid, address(usdc), amount, destRecipientAddr, highSlippage);

        // The expected behavior depends on the implementation - if the contract has a minimum
        // acceptable slippage check internally, this should revert with InsufficientMinAmount
        vm.prank(sender);
        stargateModule.bridge{value: bridgeFee}(address(safe), mainnetDestEid, address(usdc), amount, destRecipientAddr, highSlippage, signers, signatures);
        
        // If it doesn't revert, verify the bridge operation
        uint256 usdcBalAfter = usdc.balanceOf(address(safe));
        assertEq(usdcBalAfter, 0);
    }

    function test_setAssetConfig_invalidPool() public {
        // Add STARGATE_MODULE_ADMIN_ROLE to owner
        bytes32 role = stargateModule.STARGATE_MODULE_ADMIN_ROLE();
        vm.startPrank(owner);
        roleRegistry.grantRole(role, owner);
        vm.stopPrank();

        address[] memory assets = new address[](1);
        assets[0] = address(usdc);

        StargateModule.AssetConfig[] memory assetConfigs = new StargateModule.AssetConfig[](1);
        assetConfigs[0] = StargateModule.AssetConfig({
            isOFT: false,
            pool: ethStargatePool // Incorrect pool for USDC
        });

        // Should revert when trying to set an invalid pool for an asset
        vm.prank(owner);
        vm.expectRevert(StargateModule.InvalidStargatePool.selector);
        stargateModule.setAssetConfig(assets, assetConfigs);
    }

    function test_getBridgeFee_forAllAssetTypes() public view {
        // Test getting bridge fee for USDC (non-OFT)
        (address feeToken1, uint256 fee1) = stargateModule.getBridgeFee(mainnetDestEid, address(usdc), 100e6, destRecipientAddr, maxSlippage);
        assertEq(feeToken1, stargateModule.ETH());
        assertTrue(fee1 > 0, "Bridge fee should be greater than zero");

        // Test getting bridge fee for weETH (OFT)
        (address feeToken2, uint256 fee2) = stargateModule.getBridgeFee(mainnetDestEid, address(weETH), 1 ether, destRecipientAddr, maxSlippage);
        assertEq(feeToken2, stargateModule.ETH());
        assertTrue(fee2 > 0, "Bridge fee should be greater than zero");

        // Test getting bridge fee for native ETH
        (address feeToken3, uint256 fee3) = stargateModule.getBridgeFee(mainnetDestEid, ETH, 1 ether, destRecipientAddr, maxSlippage);
        assertEq(feeToken3, stargateModule.ETH());
        assertTrue(fee3 > 0, "Bridge fee should be greater than zero");
    }

    function test_prepareRideBus_insufficientMinAmount() public {
        uint256 amount = 100e6;
        
        // Set min amount very high (greater than what would be received after fees)
        uint256 minAmount = amount; // 100% of original, which is impossible after fees
        
        // Should revert with InsufficientMinAmount
        vm.expectRevert(StargateModule.InsufficientMinAmount.selector);
        stargateModule.prepareRideBus(mainnetDestEid, address(usdc), amount, destRecipientAddr, minAmount);
    }

    function _bridge(uint32 destEid, address asset, uint256 amount, address destRecipient, uint256 maxSlippageInBps) internal {
        (address[] memory signers, bytes[] memory signatures) = _getSignatures(destEid, asset, amount, destRecipient, maxSlippageInBps);

        ( , uint256 bridgeFee) = stargateModule.getBridgeFee(destEid, asset, amount, destRecipient, maxSlippageInBps);

        vm.prank(sender);
        stargateModule.bridge{value: bridgeFee}(address(safe), destEid, asset, amount, destRecipient, maxSlippageInBps, signers, signatures);
    }

    function _getSignatures(uint32 destEid, address asset, uint256 amount, address destRecipient, uint256 maxSlippageInBps) internal view returns (address[] memory, bytes[] memory) {
        bytes32 digestHash = keccak256(abi.encodePacked(
            stargateModule.BRIDGE_SIG(), 
            block.chainid, 
            address(stargateModule), 
            safe.nonce(), 
            address(safe), 
            abi.encode(destEid, asset, amount, destRecipient, maxSlippageInBps)
        )).toEthSignedMessageHash();

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        signatures[0] = abi.encodePacked(r1, s1, v1);

        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        return (signers, signatures);
    }
}