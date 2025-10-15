// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Test } from "forge-std/Test.sol";

import { ArrayDeDupLib, ICashModule, EtherFiDataProvider, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup, IDebtManager } from "../../SafeTestSetup.t.sol";
import { WithdrawalRequest } from "../../../../src/interfaces/ICashModule.sol";
import { CashVerificationLib } from "../../../../src/libraries/CashVerificationLib.sol";
import { WormholeModule, ModuleBase } from "../../../../src/modules/wormhole/WormholeModule.sol";
contract WormholeModuleTest is SafeTestSetup {
    using MessageHashUtils for bytes32;

    WormholeModule wormholeModule;

    address ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    
    IERC20 ethfi = IERC20(0x056A5FA5da84ceb7f93d36e545C5905607D8bD81);
    address nttManager = 0x552c09b224ec9146442767C0092C2928b61f62A1;
    uint8 dustDecimals = 10;

    uint16 mainnetDestEid = 2;
    address destRecipientAddr = makeAddr("destRecipient");
    address sender = makeAddr("sender");

    function setUp() public override {
        super.setUp();

        deal(sender, 1 ether);
        
        address[] memory assets = new address[](1);
        assets[0] = address(ethfi);

        WormholeModule.AssetConfig[] memory assetConfigs = new WormholeModule.AssetConfig[](1);
        assetConfigs[0] = WormholeModule.AssetConfig({
            nttManager: nttManager,
            dustDecimals: dustDecimals
        });


        wormholeModule = new WormholeModule(assets, assetConfigs, address(dataProvider));

        address[] memory modules = new address[](1);
        modules[0] = address(wormholeModule);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.startPrank(owner);
        dataProvider.configureDefaultModules(modules, shouldWhitelist);
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);
        cashModule.configureWithdrawAssets(assets, shouldWhitelist);

        bytes32 role = wormholeModule.WORMHOLE_MODULE_ADMIN_ROLE();
        roleRegistry.grantRole(role, owner);
        vm.stopPrank();
    }

    function test_requestBridge_failsWhenInvalidInput() public {
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        wormholeModule.requestBridge(address(safe), mainnetDestEid, address(0), 100e6, destRecipientAddr, new address[](0), new bytes[](0));
        
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        wormholeModule.requestBridge(address(safe), mainnetDestEid, address(1), 0, destRecipientAddr, new address[](0), new bytes[](0));
        
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        wormholeModule.requestBridge(address(safe), mainnetDestEid, address(1), 100e6, address(0), new address[](0), new bytes[](0));
    }

    function test_requestBridge_worksWithEthfi() public {
        uint256 amount = 100e10;
        deal(address(ethfi), address(safe), amount); 

        uint256 ethfiBalBefore = ethfi.balanceOf(address(safe));

        _bridge(mainnetDestEid, address(ethfi), amount, destRecipientAddr);
        
        uint256 ethfiBalAfter = ethfi.balanceOf(address(safe));
        assertEq(ethfiBalAfter, ethfiBalBefore - amount);
    }

    function test_requestBridge_createsWithdrawal() public {
        uint256 amount = 100e6;
        deal(address(ethfi), address(safe), amount); 

        uint256 ethfiBalBefore = ethfi.balanceOf(address(safe));

        (address[] memory signers, bytes[] memory signatures) = _getSignatures(mainnetDestEid, address(ethfi), amount, destRecipientAddr);

        vm.expectEmit(true, true, true, true);
        emit WormholeModule.RequestBridgeWithWormhole(address(safe), mainnetDestEid, address(ethfi), amount, destRecipientAddr);
        wormholeModule.requestBridge(address(safe), mainnetDestEid, address(ethfi), amount, destRecipientAddr, signers, signatures);

        uint256 ethfiBalAfter = ethfi.balanceOf(address(safe));
        assertEq(ethfiBalAfter, ethfiBalBefore);

        // Check that a withdrawal request was created
        WithdrawalRequest memory request = cashModule.getData(address(safe)).pendingWithdrawalRequest;
        assertEq(request.tokens.length, 1);
        assertEq(request.tokens[0], address(ethfi));
        assertEq(request.amounts[0], amount);
        assertEq(request.recipient, address(wormholeModule));
        
        WormholeModule.CrossChainWithdrawal memory withdrawal = wormholeModule.getPendingBridge(address(safe));
        assertEq(withdrawal.destEid, mainnetDestEid);
        assertEq(withdrawal.asset, address(ethfi));
        assertEq(withdrawal.amount, amount);   
        assertEq(withdrawal.destRecipient, destRecipientAddr);
    }

    function test_requestBridge_executesBridge_whenTheWithdrawDelayIsZero() public {
        // make withdraw delay 0
        vm.prank(owner);
        cashModule.setDelays(0, 0, 0);

        uint256 amount = 100e10;
        deal(address(ethfi), address(safe), amount); 

        (, uint256 fee) = wormholeModule.getBridgeFee(mainnetDestEid, address(ethfi));

        uint256 ethfiBalBefore = ethfi.balanceOf(address(safe));

        (address[] memory signers, bytes[] memory signatures) = _getSignatures(mainnetDestEid, address(ethfi), amount, destRecipientAddr);

        vm.expectEmit(true, true, true, true);
        emit WormholeModule.RequestBridgeWithWormhole(address(safe), mainnetDestEid, address(ethfi), amount, destRecipientAddr);
        vm.expectEmit(true, true, true, true);
        emit WormholeModule.BridgeWithWormhole(address(safe), mainnetDestEid, address(ethfi), amount, destRecipientAddr);
        wormholeModule.requestBridge{value: fee}(address(safe), mainnetDestEid, address(ethfi), amount, destRecipientAddr, signers, signatures);

        uint256 ethfiBalAfter = ethfi.balanceOf(address(safe));
        assertEq(ethfiBalAfter, ethfiBalBefore - amount);
    }

    function test_executeBridge_worksWithEthfi() public {
        uint256 amount = 100e10;
        deal(address(ethfi), address(safe), amount); 

        uint256 ethfiBalBefore = ethfi.balanceOf(address(safe));

        (address[] memory signers, bytes[] memory signatures) = _getSignatures(mainnetDestEid, address(ethfi), amount, destRecipientAddr);

        vm.expectEmit(true, true, true, true);
        emit WormholeModule.RequestBridgeWithWormhole(address(safe), mainnetDestEid, address(ethfi), amount, destRecipientAddr);
        wormholeModule.requestBridge(address(safe), mainnetDestEid, address(ethfi), amount, destRecipientAddr, signers, signatures);

        uint256 ethfiBalAfter = ethfi.balanceOf(address(safe));
        assertEq(ethfiBalAfter, ethfiBalBefore);

        (uint64 withdrawalDelay, , ) = cashModule.getDelays();
        vm.warp(block.timestamp + withdrawalDelay);
        ( , uint256 bridgeFee) = wormholeModule.getBridgeFee(mainnetDestEid, address(ethfi));
        
        vm.expectEmit(true, true, true, true);
        emit WormholeModule.BridgeWithWormhole(address(safe), mainnetDestEid, address(ethfi), amount, destRecipientAddr);
        wormholeModule.executeBridge{value: bridgeFee}(address(safe));

        uint256 ethfiBalAfterExecution = ethfi.balanceOf(address(safe));
        assertEq(ethfiBalAfterExecution, ethfiBalBefore - amount);
    }

    function test_executeBridge_reverts_ifWithdrawalDelayIsNotOver() public {
        uint256 amount = 100e6;
        deal(address(ethfi), address(safe), amount); 

        (address[] memory signers, bytes[] memory signatures) = _getSignatures(mainnetDestEid, address(ethfi), amount, destRecipientAddr);

        wormholeModule.requestBridge(address(safe), mainnetDestEid, address(ethfi), amount, destRecipientAddr, signers, signatures);

        // Should revert if we try to execute before withdrawal delay
        vm.expectRevert(ICashModule.CannotWithdrawYet.selector);
        wormholeModule.executeBridge{value: 0}(address(safe));
    }

    function test_executeBridge_reverts_whenNoWithdrawalQueued() public {
        vm.expectRevert(WormholeModule.NoWithdrawalQueuedForWormhole.selector);
        wormholeModule.executeBridge{value: 0}(address(safe));
    }

    function test_requestWithdrawal_cancelsTheCurrentBridgeTx() public {
        uint256 amount = 100e6;
        deal(address(ethfi), address(safe), amount); 

        (address[] memory signers, bytes[] memory signatures) = _getSignatures(mainnetDestEid, address(ethfi), amount, destRecipientAddr);

        wormholeModule.requestBridge(address(safe), mainnetDestEid, address(ethfi), amount, destRecipientAddr, signers, signatures);

        // Remove the withdrawal request from CashModule by overriding it
        address[] memory tokens = new address[](1);
        tokens[0] = address(ethfi);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        _requestWithdrawal(tokens, amounts, address(1));
        
        WormholeModule.CrossChainWithdrawal memory withdrawal = wormholeModule.getPendingBridge(address(safe));
        assertEq(withdrawal.destEid, 0);
        assertEq(withdrawal.asset, address(0));
        assertEq(withdrawal.amount, 0);
        assertEq(withdrawal.destRecipient, address(0)); 
    }

    function test_cancelBridge_works() public {
        uint256 amount = 100e6;
        deal(address(ethfi), address(safe), amount); 

        (address[] memory signers, bytes[] memory signatures) = _getSignatures(mainnetDestEid, address(ethfi), amount, destRecipientAddr);

        wormholeModule.requestBridge(address(safe), mainnetDestEid, address(ethfi), amount, destRecipientAddr, signers, signatures);

        (signers, signatures) = _getCancelSignatures();

        vm.expectEmit(true, true, true, true);
        emit WormholeModule.BridgeCancelled(address(safe), mainnetDestEid, address(ethfi), amount, destRecipientAddr);
        wormholeModule.cancelBridge(address(safe), signers, signatures);

        WormholeModule.CrossChainWithdrawal memory withdrawal = wormholeModule.getPendingBridge(address(safe));
        assertEq(withdrawal.destEid, 0);
        assertEq(withdrawal.asset, address(0));
        assertEq(withdrawal.amount, 0);
        assertEq(withdrawal.destRecipient, address(0));

        WithdrawalRequest memory request = cashModule.getData(address(safe)).pendingWithdrawalRequest;
        assertEq(request.tokens.length, 0);
    }

    function test_cancelBridge_reverts_whenNoWithdrawalQueued() public {
        (address[] memory signers, bytes[] memory signatures) = _getCancelSignatures();

        vm.expectRevert(WormholeModule.NoWithdrawalQueuedForWormhole.selector);
        wormholeModule.cancelBridge(address(safe), signers, signatures);
    }

    function test_cancelBridge_reverts_whenInvalidSignatures() public {
        uint256 amount = 100e6;
        deal(address(ethfi), address(safe), amount); 

        (address[] memory signers, bytes[] memory signatures) = _getSignatures(mainnetDestEid, address(ethfi), amount, destRecipientAddr);

        wormholeModule.requestBridge(address(safe), mainnetDestEid, address(ethfi), amount, destRecipientAddr, signers, signatures);

        (signers, signatures) = _getCancelSignatures();
        signatures[1] = signatures[0]; // Invalid signature

        vm.expectRevert(WormholeModule.InvalidSignatures.selector);
        wormholeModule.cancelBridge(address(safe), signers, signatures);
    }

    function test_cancelBridge_reverts_ifQuorumIsNotMet() public {
        uint256 amount = 100e6;
        deal(address(ethfi), address(safe), amount);

        (address[] memory signers, bytes[] memory signatures) = _getSignatures(mainnetDestEid, address(ethfi), amount, destRecipientAddr);

        wormholeModule.requestBridge(address(safe), mainnetDestEid, address(ethfi), amount, destRecipientAddr, signers, signatures);

        (signers, signatures) = _getCancelSignatures();
        signatures[0] = new bytes(0); // Invalid signature

        address[] memory newSigners = new address[](1);  
        bytes[] memory newSignatures = new bytes[](1);
        newSigners[0] = signers[0];
        newSignatures[0] = signatures[0];

        vm.expectRevert(EtherFiSafeErrors.InsufficientSigners.selector);
        wormholeModule.cancelBridge(address(safe), newSigners, newSignatures);
    }

    function test_setAssetConfig_unauthorized() public {
        address[] memory assets = new address[](1);
        assets[0] = address(ethfi);

        WormholeModule.AssetConfig[] memory assetConfigs = new WormholeModule.AssetConfig[](1);
        assetConfigs[0] = WormholeModule.AssetConfig({
            nttManager: address(0),
            dustDecimals: 0
        });

        vm.prank(notOwner);
        vm.expectRevert(WormholeModule.Unauthorized.selector);
        wormholeModule.setAssetConfig(assets, assetConfigs);
    }

    function test_setAssetConfig_authorized() public {
        address[] memory assets = new address[](1);
        assets[0] = address(ethfi);

        WormholeModule.AssetConfig[] memory assetConfigs = new WormholeModule.AssetConfig[](1);
        assetConfigs[0] = WormholeModule.AssetConfig({
            nttManager: nttManager,
            dustDecimals: dustDecimals
        });

        // Owner with admin role should be able to update asset config
        vm.prank(owner);
        wormholeModule.setAssetConfig(assets, assetConfigs);

        // Verify config was updated
        WormholeModule.AssetConfig memory config = wormholeModule.getAssetConfig(address(ethfi));
        assertEq(config.nttManager, nttManager);
        assertEq(config.dustDecimals, dustDecimals);
    }

    function test_requestBridge_reverts_whenInvalidSignatures() public {
        uint256 amount = 100e6;
        deal(address(ethfi), address(safe), amount);

        // Create invalid signatures
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        bytes32 fakeDigest = keccak256("fake");
        
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, fakeDigest.toEthSignedMessageHash());
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = signatures[0];

        vm.expectRevert(WormholeModule.InvalidSignatures.selector);
        wormholeModule.requestBridge(address(safe), mainnetDestEid, address(ethfi), amount, destRecipientAddr, signers, signatures);
    }

    function test_requestBridge_insufficientAmount() public {
        uint256 amount = 100e6;
        
        // Don't fund the safe
        (address[] memory signers, bytes[] memory signatures) = _getSignatures(mainnetDestEid, address(ethfi), amount, destRecipientAddr);
        
        // Should revert with InsufficientBalance
        vm.prank(sender);
        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        wormholeModule.requestBridge(address(safe), mainnetDestEid, address(ethfi), amount, destRecipientAddr, signers, signatures);
    }

    function test_executeBridge_insufficientNativeFee() public {
        uint256 amount = 100e6;
        deal(address(ethfi), address(safe), amount);
        
        (address[] memory signers, bytes[] memory signatures) = _getSignatures(mainnetDestEid, address(ethfi), amount, destRecipientAddr);
        
        (, uint256 bridgeFee) = wormholeModule.getBridgeFee(mainnetDestEid, address(ethfi));

        wormholeModule.requestBridge(address(safe), mainnetDestEid, address(ethfi), amount, destRecipientAddr, signers, signatures);

        (uint64 withdrawalDelay , , ) = cashModule.getDelays();
        vm.warp(block.timestamp + withdrawalDelay);

        // Provide insufficient fee
        vm.prank(sender);
        vm.expectRevert(WormholeModule.InsufficientNativeFee.selector);
        wormholeModule.executeBridge{value: bridgeFee - 1}(address(safe));
    }

    function test_requestBridge_invalidInput() public {
        uint256 amount = 100e10;
        deal(address(ethfi), address(safe), amount);
        
        // Test with zero address for destRecipient
        (address[] memory signers1, bytes[] memory signatures1) = _getSignatures(mainnetDestEid, address(ethfi), amount, address(0));
        
        vm.prank(sender);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        wormholeModule.requestBridge(address(safe), mainnetDestEid, address(ethfi), amount, address(0), signers1, signatures1);

        // Test with zero address for asset
        (address[] memory signers2, bytes[] memory signatures2) = _getSignatures(mainnetDestEid, address(ethfi), amount, destRecipientAddr);
        
        vm.prank(sender);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        wormholeModule.requestBridge(address(safe), mainnetDestEid, address(0), amount, destRecipientAddr, signers2, signatures2);

        // Test with zero amount
        (address[] memory signers3, bytes[] memory signatures3) = _getSignatures(mainnetDestEid, address(ethfi), 0, destRecipientAddr);
        
        vm.prank(sender);       
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        wormholeModule.requestBridge(address(safe), mainnetDestEid, address(ethfi), 0, destRecipientAddr, signers3, signatures3);
        
        // Test with invalid slippage
        (address[] memory signers4, bytes[] memory signatures4) = _getSignatures(mainnetDestEid, address(ethfi), 0, destRecipientAddr);
        
        vm.prank(sender);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        wormholeModule.requestBridge(address(safe), mainnetDestEid, address(ethfi), 0, destRecipientAddr, signers4, signatures4);
    }

    function test_setAssetConfig_invalidInput() public {
        // Add STARGATE_MODULE_ADMIN_ROLE to owner
        bytes32 role = wormholeModule.WORMHOLE_MODULE_ADMIN_ROLE();
        vm.startPrank(owner);
        roleRegistry.grantRole(role, owner);
        vm.stopPrank();

        address[] memory assets = new address[](1);
        assets[0] = address(ethfi);

        WormholeModule.AssetConfig[] memory assetConfigs = new WormholeModule.AssetConfig[](1);
        assetConfigs[0] = WormholeModule.AssetConfig({
            nttManager: address(0),
            dustDecimals: dustDecimals
        });

        // Should revert when trying to set an invalid pool for an asset
        vm.prank(owner);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        wormholeModule.setAssetConfig(assets, assetConfigs);

        assetConfigs[0] = WormholeModule.AssetConfig({
            nttManager: nttManager,
            dustDecimals: 0
        });

        vm.prank(owner);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        wormholeModule.setAssetConfig(assets, assetConfigs);
    }
    
    function test_executeBridge_noWithdrawalsQueuedUp() public {
        vm.expectRevert(WormholeModule.NoWithdrawalQueuedForWormhole.selector);
        wormholeModule.executeBridge{value: 0}(address(safe));
    }

    function test_getBridgeFee() public view {
        (address feeToken1, uint256 fee1) = wormholeModule.getBridgeFee(mainnetDestEid, address(ethfi));
        assertEq(feeToken1, wormholeModule.ETH());
        assertTrue(fee1 > 0, "Bridge fee should be greater than zero");
    }

    function _bridge(uint16 destEid, address asset, uint256 amount, address destRecipient) internal {
        (address[] memory signers, bytes[] memory signatures) = _getSignatures(destEid, asset, amount, destRecipient);

        wormholeModule.requestBridge(address(safe), destEid, asset, amount, destRecipient, signers, signatures);

        (uint64 withdrawalDelay, , ) = cashModule.getDelays();
        vm.warp(block.timestamp + withdrawalDelay);

        ( , uint256 bridgeFee) = wormholeModule.getBridgeFee(destEid, asset);

        vm.prank(sender);
        wormholeModule.executeBridge{value: bridgeFee}(address(safe));
    }

    function _getSignatures(uint32 destEid, address asset, uint256 amount, address destRecipient) internal view returns (address[] memory, bytes[] memory) {
        bytes32 digestHash = keccak256(abi.encodePacked(
            wormholeModule.REQUEST_BRIDGE_SIG(), 
            block.chainid, 
            address(wormholeModule), 
            safe.nonce(), 
            address(safe), 
            abi.encode(destEid, asset, amount, destRecipient)
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

    function _getCancelSignatures() internal view returns (address[] memory, bytes[] memory) {
        bytes32 digestHash = keccak256(abi.encodePacked(
            wormholeModule.CANCEL_BRIDGE_SIG(), 
            block.chainid, 
            address(wormholeModule),
            safe.nonce(),
            address(safe) 
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

    function _requestWithdrawal(address[] memory tokens, uint256[] memory amounts, address recipient) internal {
        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, address(safe), safe.nonce(), abi.encode(tokens, amounts, recipient))).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        cashModule.requestWithdrawal(address(safe), tokens, amounts, recipient, signers, signatures);
    }
}