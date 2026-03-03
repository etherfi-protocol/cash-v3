// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { SafeTestSetup, MessageHashUtils } from "../../SafeTestSetup.t.sol";
import { EtherFiLiquidModuleWithReferrer, ModuleCheckBalance } from "../../../../src/modules/etherfi/EtherFiLiquidModuleWithReferrer.sol";
import { ModuleBase } from "../../../../src/modules/ModuleBase.sol";
import { IBoringOnChainQueue } from "../../../../src/interfaces/IBoringOnChainQueue.sol";
import { IDebtManager } from "../../../../src/interfaces/IDebtManager.sol";
import { ILayerZeroTeller } from "../../../../src/interfaces/ILayerZeroTeller.sol";
import { IEtherFiSafe } from "../../../../src/interfaces/IEtherFiSafe.sol";
import { IEtherFiDataProvider } from "../../../../src/interfaces/IEtherFiDataProvider.sol";
import { ICashModule, WithdrawalRequest } from "../../../../src/interfaces/ICashModule.sol";
import { CashVerificationLib } from "../../../../src/libraries/CashVerificationLib.sol";
import { EtherFiSafeErrors } from "../../../../src/safe/EtherFiSafeErrors.sol";

contract EtherFiLiquidModuleWithReferrerTest is SafeTestSetup {
    using MessageHashUtils for bytes32;

    EtherFiLiquidModuleWithReferrer public liquidModule;

    IERC20 public weth = IERC20(0x5300000000000000000000000000000000000004);

    uint32 mainnetEid = 30101;
    
    IERC20 public ethfi = IERC20(0x056A5FA5da84ceb7f93d36e545C5905607D8bD81);

    IERC20 public sethfi = IERC20(0x86B5780b606940Eb59A062aA85a07959518c0161);
    address public sethfiTeller = 0x35dD2463fA7a335b721400C5Ad8Ba40bD85c179b;
    
    IBoringOnChainQueue public sETHFIBoringQueue = IBoringOnChainQueue(0xF03352da1536F31172A7F7cB092D4717DeDDd3CB);

    address sETHFIAssetOut = address(ethfi);
    
    uint16 discount = 1; 
    uint24 secondsToDeadline = 3 days;

    address public ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    
    
    function setUp() public override {
        super.setUp();
        
        vm.startPrank(owner);

        address[] memory assets = new address[](1);
        assets[0] = address(sethfi);
        
        address[] memory tellers = new address[](1);
        tellers[0] = sethfiTeller;

        bool[] memory isWithdrawAsset = new bool[](1);
        isWithdrawAsset[0] = true;

        liquidModule = new EtherFiLiquidModuleWithReferrer(assets, tellers, address(dataProvider), address(weth));
        
        cashModule.configureWithdrawAssets(assets, isWithdrawAsset);

        address[] memory modules = new address[](1);
        modules[0] = address(liquidModule);
        
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;
        
        bytes[] memory moduleSetupData = new bytes[](1);
        moduleSetupData[0] = "";
        
        dataProvider.configureModules(modules, shouldWhitelist);
        _configureModules(modules, shouldWhitelist, moduleSetupData);

        roleRegistry.grantRole(liquidModule.ETHERFI_LIQUID_MODULE_ADMIN(), owner);

        liquidModule.setLiquidAssetWithdrawQueue(address(sethfi), address(sETHFIBoringQueue));

        address[] memory ethfiArray = new address[](1);
        ethfiArray[0] = address(ethfi);

        bool[] memory isWithdrawAssetArray = new bool[](1);
        isWithdrawAssetArray[0] = true;

        cashModule.configureWithdrawAssets(ethfiArray, isWithdrawAssetArray);
        
        vm.stopPrank();
    }

    function test_requestBridgeAndExecuteBridge_worksforSEthFi() public {
        address[] memory modules = new address[](1);
        modules[0] = address(liquidModule);
        
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.prank(owner);
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);

        uint256 amountToBridge = 1 ether;
        deal(address(sethfi), address(safe), amountToBridge);

        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.REQUEST_BRIDGE_SIG(),
            block.chainid,
            address(liquidModule),
            safe.nonce(),
            address(safe),
            abi.encode(address(sethfi), mainnetEid, owner, amountToBridge)
        )).toEthSignedMessageHash();

        uint256 fee = liquidModule.getBridgeFee(address(sethfi), mainnetEid, owner, amountToBridge);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature1 = abi.encodePacked(r, s, v); 
        
        (v, r, s) = vm.sign(owner2Pk, digestHash);
        bytes memory signature2 = abi.encodePacked(r, s, v); 

        uint256 liquidAssetBalBefore = sethfi.balanceOf(address(safe));
        _bridgeLiquid(address(sethfi), mainnetEid, amountToBridge, signature1, signature2, fee);
        uint256 liquidAssetBalAfter = sethfi.balanceOf(address(safe));
        assertEq(liquidAssetBalAfter, liquidAssetBalBefore - amountToBridge);
    }

    function test_executeBridge_reverts_ifWithdrawalDelayIsNotOver() public {
        address[] memory modules = new address[](1);
        modules[0] = address(liquidModule);
        
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.prank(owner);
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);

        uint256 amount = 100e6;
        deal(address(sethfi), address(safe), amount); 

        _requestBridge(address(sethfi), mainnetEid, amount);

        vm.expectRevert(ICashModule.CannotWithdrawYet.selector);
        liquidModule.executeBridge{value: 1}(address(safe));
    }

    function test_executeBridge_reverts_whenNoWithdrawalQueued() public {
        vm.expectRevert(EtherFiLiquidModuleWithReferrer.NoWithdrawalQueuedForLiquid.selector);
        liquidModule.executeBridge{value: 0}(address(safe));
    }

    function test_requestWithdrawal_cancelsTheCurrentBridgeTx() public {
        address[] memory modules = new address[](1);
        modules[0] = address(liquidModule);
        
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.prank(owner);
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);

        uint256 amount = 100e6;
        deal(address(sethfi), address(safe), amount); 

        _requestBridge(address(sethfi), mainnetEid, amount);

        // Remove the withdrawal request from CashModule by overriding it
        address[] memory tokens = new address[](1);
        tokens[0] = address(sethfi);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        _requestWithdrawal(tokens, amounts, address(1));
        
        EtherFiLiquidModuleWithReferrer.LiquidCrossChainWithdrawal memory withdrawal = liquidModule.getPendingBridge(address(safe));
        assertEq(withdrawal.destEid, 0);
        assertEq(withdrawal.asset, address(0));
        assertEq(withdrawal.amount, 0);
        assertEq(withdrawal.destRecipient, address(0)); 
    }

    function test_cancelBridge_works() public {
        address[] memory modules = new address[](1);
        modules[0] = address(liquidModule);
        
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.prank(owner);
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);

        uint256 amount = 100e6;
        deal(address(sethfi), address(safe), amount); 

        _requestBridge(address(sethfi), mainnetEid, amount);

        (address[] memory signers, bytes[] memory signatures) = _getCancelSignatures();

        vm.expectEmit(true, true, true, true);
        emit EtherFiLiquidModuleWithReferrer.LiquidBridgeCancelled(address(safe), address(sethfi), mainnetEid, owner, amount);
        liquidModule.cancelBridge(address(safe), signers, signatures);

        EtherFiLiquidModuleWithReferrer.LiquidCrossChainWithdrawal memory withdrawal = liquidModule.getPendingBridge(address(safe));
        assertEq(withdrawal.destEid, 0);
        assertEq(withdrawal.asset, address(0));
        assertEq(withdrawal.amount, 0);
        assertEq(withdrawal.destRecipient, address(0));

        WithdrawalRequest memory request = cashModule.getData(address(safe)).pendingWithdrawalRequest;
        assertEq(request.tokens.length, 0);
    }

    function test_cancelBridge_reverts_whenNoWithdrawalQueued() public {
        (address[] memory signers, bytes[] memory signatures) = _getCancelSignatures();

        vm.expectRevert(EtherFiLiquidModuleWithReferrer.NoWithdrawalQueuedForLiquid.selector);
        liquidModule.cancelBridge(address(safe), signers, signatures);
    }

    function test_cancelBridge_reverts_whenInvalidSignatures() public {
        address[] memory modules = new address[](1);
        modules[0] = address(liquidModule);
        
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.prank(owner);
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);

        uint256 amount = 100e6;
        deal(address(sethfi), address(safe), amount); 

        _requestBridge(address(sethfi), mainnetEid, amount);

        (address[] memory signers, bytes[] memory signatures) = _getCancelSignatures();
        signatures[1] = signatures[0]; // Invalid signature

        vm.expectRevert(EtherFiLiquidModuleWithReferrer.InvalidSignatures.selector);
        liquidModule.cancelBridge(address(safe), signers, signatures);
    }

    function test_cancelBridge_reverts_ifQuorumIsNotMet() public {
        address[] memory modules = new address[](1);
        modules[0] = address(liquidModule);
        
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.prank(owner);
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);

        uint256 amount = 100e6;
        deal(address(sethfi), address(safe), amount);
        _requestBridge(address(sethfi), mainnetEid, amount);

        (address[] memory signers, bytes[] memory signatures) = _getCancelSignatures();

        address[] memory newSigners = new address[](1);  
        bytes[] memory newSignatures = new bytes[](1);
        newSigners[0] = signers[0];
        newSignatures[0] = signatures[0];

        vm.expectRevert(EtherFiSafeErrors.InsufficientSigners.selector);
        liquidModule.cancelBridge(address(safe), newSigners, newSignatures);
    }

    function test_requestBridge_insufficientAmount() public {
        address[] memory modules = new address[](1);
        modules[0] = address(liquidModule);
        
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.prank(owner);
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);

        uint256 amount = 100e6;
        // deal less amount than required
        deal(address(sethfi), address(safe), amount - 1);

        (address[] memory signers, bytes[] memory signatures) = _getSignaturesForRequestBridging(address(sethfi), mainnetEid, amount, owner);

        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        liquidModule.requestBridge(address(safe), mainnetEid, address(sethfi), amount, owner, signers, signatures);
    }

    function test_requestBridge_invalidInput() public {
        uint256 amount = 100e6;
        deal(address(sethfi), address(safe), amount);
        
        // Test with zero address for destRecipient
        (address[] memory signers1, bytes[] memory signatures1) = _getSignaturesForRequestBridging(address(sethfi), mainnetEid, amount, address(0));
        
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        liquidModule.requestBridge(address(safe), mainnetEid, address(sethfi), amount, address(0), signers1, signatures1);

        // Test with zero address for asset
        (address[] memory signers2, bytes[] memory signatures2) = _getSignaturesForRequestBridging(address(0), mainnetEid, amount, owner);
        
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        liquidModule.requestBridge(address(safe), mainnetEid, address(0), amount, owner, signers2, signatures2);

        // Test with zero amount
        (address[] memory signers3, bytes[] memory signatures3) = _getSignaturesForRequestBridging(address(sethfi), mainnetEid, 0, owner);
        
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        liquidModule.requestBridge(address(safe), mainnetEid, address(sethfi), 0, owner, signers3, signatures3);
    }

    function _requestBridge(address liquidAsset, uint32 destEid, uint256 amountToBridge) internal {
        (address[] memory signers, bytes[] memory signatures) = _getSignaturesForRequestBridging(liquidAsset, destEid, amountToBridge, owner);
        vm.expectEmit(true, true, true, true);
        emit EtherFiLiquidModuleWithReferrer.LiquidBridgeRequested(address(safe), address(liquidAsset), destEid, owner, amountToBridge);
        liquidModule.requestBridge(address(safe), destEid, address(liquidAsset), amountToBridge, owner, signers, signatures);
    }

    function _bridgeLiquid(address liquidAsset, uint32 destEid, uint256 amountToBridge, bytes memory signature1, bytes memory signature2, uint256 fee) internal {
        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = owner2;
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = signature1;
        signatures[1] = signature2;

        vm.expectEmit(true, true, true, true);
        emit EtherFiLiquidModuleWithReferrer.LiquidBridgeRequested(address(safe), address(liquidAsset), destEid, owner, amountToBridge);
        liquidModule.requestBridge(address(safe), destEid, address(liquidAsset), amountToBridge, owner, owners, signatures);

        (uint64 withdrawalDelay, , ) = cashModule.getDelays();
        vm.warp(block.timestamp + withdrawalDelay);

        vm.expectEmit(true, true, true, true);
        emit EtherFiLiquidModuleWithReferrer.LiquidBridgeExecuted(address(safe), address(liquidAsset), owner, destEid, amountToBridge, fee);
        liquidModule.executeBridge{value: fee}(address(safe));
    }

    function _getSignaturesForRequestBridging(address liquidAsset, uint32 destEid, uint256 amountToBridge, address destRecipient) internal view returns (address[] memory owners, bytes[] memory signatures) {
        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.REQUEST_BRIDGE_SIG(),
            block.chainid,
            address(liquidModule),
            safe.nonce(),
            address(safe),
            abi.encode(address(liquidAsset), destEid, destRecipient, amountToBridge)
        )).toEthSignedMessageHash();

        owners = new address[](2);
        owners[0] = owner1;
        owners[1] = owner2;

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature1 = abi.encodePacked(r, s, v); 
        
        (v, r, s) = vm.sign(owner2Pk, digestHash);
        bytes memory signature2 = abi.encodePacked(r, s, v); 

        signatures = new bytes[](2);
        signatures[0] = signature1;
        signatures[1] = signature2;

        return (owners, signatures);
    }

    function _getCancelSignatures() internal view returns (address[] memory, bytes[] memory) {
        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.CANCEL_BRIDGE_SIG(), 
            block.chainid, 
            address(liquidModule),
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

    function test_deposit_reverts_ifPendingWithdrawalBlocksIt() public {
        uint256 amountToDeposit = 10e6;
        uint256 minReturn = 0.50e6; 
        deal(address(ethfi), address(safe), amountToDeposit);

        address[] memory tokens = new address[](1);
        tokens[0] = address(ethfi);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountToDeposit - 1;
        _requestWithdrawal(tokens, amounts, address(1));

        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.DEPOSIT_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(ethfi), address(sethfi), amountToDeposit, minReturn)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v); 

        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        liquidModule.deposit(address(safe), address(ethfi), address(sethfi), amountToDeposit, minReturn, owner1, signature);
    }

    function test_deposit_worksWithEthfi_forSEthfi() public {
        uint256 amountToDeposit = 1 ether;
        uint256 minReturn = 0.5 ether; 
        deal(address(ethfi), address(safe), amountToDeposit);

        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.DEPOSIT_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(ethfi), address(sethfi), amountToDeposit, minReturn)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v); 

        uint256 ethfiBalBefore = ethfi.balanceOf(address(safe));
        uint256 sethfiBalBefore = sethfi.balanceOf(address(safe));

        liquidModule.deposit(address(safe), address(ethfi), address(sethfi), amountToDeposit, minReturn, owner1, signature);
        
        uint256 ethfiBalAfter = ethfi.balanceOf(address(safe));
        uint256 sethfiBalAfter = sethfi.balanceOf(address(safe));

        assertEq(ethfiBalAfter, ethfiBalBefore - amountToDeposit);
        assertGt(sethfiBalAfter, sethfiBalBefore);
    }

    function test_deposit_revertsWithInsufficientBalance_forSEthfi() public {
        uint256 amountToDeposit = 2 ether;
        uint256 minReturn = 1 ether;
        
        // Give the safe only 1 ETHFI, but try to deposit 2 ETHFI
        uint256 actualBalance = 1 ether;
        deal(address(ethfi), address(safe), actualBalance);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.DEPOSIT_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(ethfi), address(sethfi), amountToDeposit, minReturn)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        liquidModule.deposit(address(safe), address(ethfi), address(sethfi), amountToDeposit, minReturn, owner1, signature);
    }
    
    // function test_withdraw_succeeds_forSEthfi() public {    
    //     vm.prank(owner);
    //     liquidModule.setLiquidAssetWithdrawQueue(address(sethfi), address(sETHFIBoringQueue));
        
    //     uint128 amountToWithdraw = 1 ether; 
    //     uint128 amountOut = sETHFIBoringQueue.previewAssetsOut(address(sETHFIAssetOut), amountToWithdraw, discount);
    //     deal(address(sethfi), address(safe), amountToWithdraw);
        
    //     bytes32 digestHash = keccak256(abi.encodePacked(
    //         liquidModule.WITHDRAW_SIG(),
    //         block.chainid,
    //         address(liquidModule),
    //         liquidModule.getNonce(address(safe)),
    //         address(safe),
    //         abi.encode(address(sethfi), address(sETHFIAssetOut), amountToWithdraw, amountToWithdraw, discount, secondsToDeadline)
    //     )).toEthSignedMessageHash();
        
    //     (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
    //     bytes memory signature = abi.encodePacked(r, s, v);
        
    //     uint256 sethfiBalBefore = sethfi.balanceOf(address(safe));
        
    //     vm.expectEmit(true, true, true, true);
    //     emit EtherFiLiquidModuleWithReferrer.LiquidWithdrawal(address(safe), address(sethfi), amountToWithdraw, amountOut);
        
    //     liquidModule.withdraw(address(safe), address(sethfi), address(ethfi), amountToWithdraw, amountToWithdraw, discount, secondsToDeadline, owner1, signature);
        
    //     uint256 sethfiBalAfter = sethfi.balanceOf(address(safe));
    //     assertEq(sethfiBalAfter, sethfiBalBefore - amountToWithdraw);
    // }
    
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
