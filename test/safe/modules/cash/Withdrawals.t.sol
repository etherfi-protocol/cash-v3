// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Mode, BinSponsor, Cashback } from "../../../../src/interfaces/ICashModule.sol";
import { ArrayDeDupLib } from "../../../../src/libraries/ArrayDeDupLib.sol";
import { ModuleBase } from "../../../../src/modules/ModuleBase.sol";
import { CashEventEmitter, CashModuleTestSetup, CashVerificationLib, ICashModule, IDebtManager, MessageHashUtils } from "./CashModuleTestSetup.t.sol";
import { EnumerableAddressWhitelistLib } from "../../../../src/libraries/EnumerableAddressWhitelistLib.sol";
import { ArrayDeDupLib } from "../../../../src/libraries/ArrayDeDupLib.sol";
import { EtherFiSafeErrors } from "../../../../src/safe/EtherFiSafeErrors.sol";
import { WithdrawalRequest } from "../../../../src/interfaces/ICashModule.sol";
import { IBridgeModule } from "../../../../src/interfaces/IBridgeModule.sol";
import { IEtherFiDataProvider } from "../../../../src/interfaces/IEtherFiDataProvider.sol";

contract CashModuleWithdrawalTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;

    function test_configureWithdrawAssets_configuresWithdrawAssets() public {
        address[] memory asset = new address[](3);
        asset[0] = address(usdcScroll);
        asset[1] = address(weETHScroll);
        asset[2] = address(scrToken);

        bool[] memory whitelist = new bool[](3);
        whitelist[0] = true;
        whitelist[1] = false;
        whitelist[2] = false;

        address[] memory whitelistedAssets = cashModule.getWhitelistedWithdrawAssets();
        assertEq(whitelistedAssets.length, 3);
        assertEq(whitelistedAssets[0], asset[0]);
        assertEq(whitelistedAssets[1], asset[1]);
        assertEq(whitelistedAssets[2], asset[2]);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.WithdrawTokensConfigured(asset, whitelist);
        cashModule.configureWithdrawAssets(asset, whitelist);

        whitelistedAssets = cashModule.getWhitelistedWithdrawAssets();
        assertEq(whitelistedAssets.length, 1);
        assertEq(whitelistedAssets[0], asset[0]);
    }

    function test_configureWithdrawAssets_fails_whenCallerIsNotCashController() public {
        address[] memory asset = new address[](2);
        asset[0] = address(1);
        asset[1] = address(usdcScroll);

        bool[] memory whitelist = new bool[](2);
        whitelist[0] = true;
        whitelist[1] = false;

        address alice = makeAddr("alice");

        vm.prank(alice);
        vm.expectRevert(ICashModule.OnlyCashModuleController.selector);
        cashModule.configureWithdrawAssets(asset, whitelist);
    }

    function test_configureWithdrawAssets_fails_whenArrayLengthMismatch() public {
        address[] memory asset = new address[](2);
        asset[0] = address(1);
        asset[1] = address(usdcScroll);

        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;

        vm.prank(owner);
        vm.expectRevert(EnumerableAddressWhitelistLib.ArrayLengthMismatch.selector);
        cashModule.configureWithdrawAssets(asset, whitelist);
    }

    function test_configureWithdrawAssets_fails_whenAssetArrayIsEmpty() public {
        address[] memory asset = new address[](0);
        bool[] memory whitelist = new bool[](0);

        vm.prank(owner);
        vm.expectRevert(EnumerableAddressWhitelistLib.InvalidInput.selector);
        cashModule.configureWithdrawAssets(asset, whitelist);
    }

    function test_configureWithdrawAssets_fails_whenAssetIsAddressZero() public {
        address[] memory asset = new address[](1);
        asset[0] = address(0);

        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EnumerableAddressWhitelistLib.InvalidAddress.selector, 0));
        cashModule.configureWithdrawAssets(asset, whitelist);
    }
    
    function test_configureWithdrawAssets_fails_whenAssetIsDuplicate() public {
        address[] memory asset = new address[](2);
        asset[0] = address(usdcScroll);
        asset[1] = address(usdcScroll);

        bool[] memory whitelist = new bool[](2);
        whitelist[0] = true;
        whitelist[1] = true;

        vm.prank(owner);
        vm.expectRevert(ArrayDeDupLib.DuplicateElementFound.selector);
        cashModule.configureWithdrawAssets(asset, whitelist);
    }

    function test_requestWithdrawal_works() public {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // Verify pending withdrawal was set up correctly
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), withdrawalAmount);
    }

    function test_requestWithdrawal_fails_forUnsupportedAsset() public {
        uint256 withdrawalAmount = 50e6;

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, address(safe), safe.nonce(), abi.encode(tokens, amounts, withdrawRecipient))).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        vm.expectRevert(abi.encodeWithSelector(ICashModule.InvalidWithdrawAsset.selector, tokens[0]));
        cashModule.requestWithdrawal(address(safe), tokens, amounts, withdrawRecipient, signers, signatures);
    }

    function test_processWithdrawals_works() external {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // Verify pending withdrawal was set up correctly
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), withdrawalAmount);

        uint256 balBeforeSafe = usdcScroll.balanceOf(address(safe));
        uint256 balBeforeWithdrawRecipient = usdcScroll.balanceOf(address(withdrawRecipient));

        (uint64 withdrawalDelay,,) = cashModule.getDelays();
        vm.warp(block.timestamp + withdrawalDelay); // withdraw delay is 60 secs

        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.WithdrawalProcessed(address(safe), tokens, amounts, withdrawRecipient);
        cashModule.processWithdrawal(address(safe));

        uint256 balAfterSafe = usdcScroll.balanceOf(address(safe));
        uint256 balAfterWithdrawRecipient = usdcScroll.balanceOf(address(withdrawRecipient));

        assertEq(balBeforeSafe, withdrawalAmount);
        assertEq(balAfterSafe, 0);
        assertEq(balBeforeWithdrawRecipient, 0);
        assertEq(balAfterWithdrawRecipient, withdrawalAmount);

        // Verify pending withdrawal is 0
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), 0);
    }

    function test_processWithdrawals_fails_whenAssetIsNotWhitelistedWithdrawAsset() external {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // Verify pending withdrawal was set up correctly
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), withdrawalAmount);

        (uint64 withdrawalDelay,,) = cashModule.getDelays();
        vm.warp(block.timestamp + withdrawalDelay); // withdraw delay is 60 secs

        bool[] memory whitelist = new bool[](1);
        whitelist[0] = false;

        vm.prank(owner);
        cashModule.configureWithdrawAssets(tokens, whitelist);

        vm.expectRevert(abi.encodeWithSelector(ICashModule.InvalidWithdrawAsset.selector, tokens[0]));
        cashModule.processWithdrawal(address(safe));
    }

    function test_processWithdrawals_fails_ifPositionUnhealthyAfterWithdrawal() external {
        uint256 totalSafeBalance = 100e6;
        deal(address(usdcScroll), address(safe), totalSafeBalance);
        deal(address(weETHScroll), address(safe), 0);

        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        uint256 amount = 10e6;

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = address(usdcScroll);
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;

        Cashback[] memory cashbacks;

        vm.prank(etherFiWallet);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.Spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, spendAmounts, spendAmounts[0], Mode.Credit);
        cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);

        uint256 withdrawalAmount = 50e6;
        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // Verify pending withdrawal was set up correctly
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), withdrawalAmount);

        (uint64 withdrawalDelay,,) = cashModule.getDelays();
        vm.warp(block.timestamp + withdrawalDelay); // withdraw delay is 60 secs

        // change the safe balance to withdraw amount so the position become unhealthy for withdrawal
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        vm.expectRevert(IDebtManager.AccountUnhealthy.selector);
        cashModule.processWithdrawal(address(safe));
    }


    function test_processWithdrawals_fails_whenTheDelayIsNotOver() external {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // Verify pending withdrawal was set up correctly
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), withdrawalAmount);

        vm.expectRevert(ICashModule.CannotWithdrawYet.selector);
        cashModule.processWithdrawal(address(safe));
    }

    function test_requestWithdrawal_fails_whenAccountBecomesUnhealthy() external {
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdcScroll);
        tokens[1] = address(weETHScroll);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e6;
        amounts[1] = 1 ether;

        deal(tokens[0], address(safe), amounts[0]);
        deal(tokens[1], address(safe), amounts[1]);
        deal(address(usdcScroll), address(debtManager), 1 ether);

        _setMode(Mode.Credit);
        vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);

        {
            address[] memory spendTokens = new address[](1);
            spendTokens[0] = address(usdcScroll);
            uint256[] memory spendAmounts = new uint256[](1);
            spendAmounts[0] = 10e6;

            Cashback[] memory cashbacks;

            vm.prank(etherFiWallet);
            cashModule.spend(address(safe), txId, BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
        }

        {
            uint256 nonce = safe.nonce();

            bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, address(safe), nonce, abi.encode(tokens, amounts, withdrawRecipient))).toEthSignedMessageHash();

            (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
            (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

            address[] memory signers = new address[](2);
            signers[0] = owner1;
            signers[1] = owner2;

            bytes[] memory signatures = new bytes[](2);
            signatures[0] = abi.encodePacked(r1, s1, v1);
            signatures[1] = abi.encodePacked(r2, s2, v2);

            vm.expectRevert(IDebtManager.AccountUnhealthy.selector);
            cashModule.requestWithdrawal(address(safe), tokens, amounts, withdrawRecipient, signers, signatures);
        }
    }

    function test_requestWithdrawal_resetWithdrawalWithNewRequest() public {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), 1000e6);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // Verify pending withdrawal was set up correctly
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), withdrawalAmount);

        uint256 newWithdrawalAmt = 100e6;
        amounts[0] = newWithdrawalAmt;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), newWithdrawalAmt);
    }
    
    function test_requestWithdrawal_fails_whenFundsAreInsufficient() public {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount - 1);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        uint256 nonce = safe.nonce();

        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, address(safe), nonce, abi.encode(tokens, amounts, withdrawRecipient))).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        cashModule.requestWithdrawal(address(safe), tokens, amounts, withdrawRecipient, signers, signatures);
    }

    function test_requestWithdrawal_fails_whenRecipientIsNull() public {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        uint256 nonce = safe.nonce();

        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, address(safe), nonce, abi.encode(tokens, amounts, address(0)))).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        vm.expectRevert(ICashModule.RecipientCannotBeAddressZero.selector);
        cashModule.requestWithdrawal(address(safe), tokens, amounts, address(0), signers, signatures);
    }

    function test_requestWithdrawal_fails_whenArrayLengthMismatch() public {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = withdrawalAmount;

        uint256 nonce = safe.nonce();

        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, address(safe), nonce, abi.encode(tokens, amounts, withdrawRecipient))).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        vm.expectRevert(ModuleBase.ArrayLengthMismatch.selector);
        cashModule.requestWithdrawal(address(safe), tokens, amounts, withdrawRecipient, signers, signatures);
    }

    function test_requestWithdrawal_fails_whenDuplicateTokens() public {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), 2 * withdrawalAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdcScroll);
        tokens[1] = address(usdcScroll);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = withdrawalAmount;
        amounts[1] = withdrawalAmount;

        uint256 nonce = safe.nonce();

        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, address(safe), nonce, abi.encode(tokens, amounts, withdrawRecipient))).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        vm.expectRevert(ArrayDeDupLib.DuplicateElementFound.selector);
        cashModule.requestWithdrawal(address(safe), tokens, amounts, withdrawRecipient, signers, signatures);
    }

    function test_requestWithdrawal_fails_whenInvalidSignature() public {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        uint256 nonce = safe.nonce();

        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.REQUEST_WITHDRAWAL_METHOD, block.chainid, address(safe), nonce, abi.encode(tokens, amounts, withdrawRecipient))).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);

        // use the signature from owner1 itself for owner2 so its a wrong signature
        signatures[1] = abi.encodePacked(r1, s1, v1);

        vm.expectRevert(CashVerificationLib.InvalidSignatures.selector);
        cashModule.requestWithdrawal(address(safe), tokens, amounts, withdrawRecipient, signers, signatures);
    }

    function test_requestWithdrawalByModule_worksAndSetsRecipientAsModule() public {
        address module = makeAddr("module");
        address[] memory modules = new address[](1);
        modules[0] = module;
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;
        
        vm.startPrank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);
        vm.stopPrank();

        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        vm.prank(module);
        cashModule.requestWithdrawalByModule(address(safe), address(usdcScroll), withdrawalAmount);

        WithdrawalRequest memory request = cashModule.getData(address(safe)).pendingWithdrawalRequest;
        assertEq(request.tokens.length, 1);
        assertEq(request.tokens[0], address(usdcScroll));
        assertEq(request.amounts[0], withdrawalAmount);
        assertEq(request.recipient, module);
    }

    function test_cancelWithdrawalByModule_works() public {
        address module = makeAddr("module");
        address[] memory modules = new address[](1);
        modules[0] = module;
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;
        
        vm.startPrank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);
        vm.stopPrank();

        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        vm.prank(module);
        cashModule.requestWithdrawalByModule(address(safe), address(usdcScroll), withdrawalAmount);

        WithdrawalRequest memory request = cashModule.getData(address(safe)).pendingWithdrawalRequest;
        assertEq(request.tokens.length, 1);
        assertEq(request.tokens[0], address(usdcScroll));
        assertEq(request.amounts[0], withdrawalAmount);
        assertEq(request.recipient, module);

        vm.mockCall(module, abi.encodeWithSelector(IBridgeModule.cancelBridgeByCashModule.selector, address(safe)), abi.encode(""));

        vm.prank(module);
        cashModule.cancelWithdrawalByModule(address(safe));

        request = cashModule.getData(address(safe)).pendingWithdrawalRequest;
        assertEq(request.tokens.length, 0);
    }

    function test_cancelWithdrawalByModule_reverts_whenPendingWithdrawalDoesNotExist() public {
        vm.prank(address(1));
        vm.expectRevert(ICashModule.WithdrawalDoesNotExist.selector);
        cashModule.cancelWithdrawalByModule(address(safe));
    }

    function test_cancelWithdrawalByModule_reverts_whenCalledByADifferentModule() public {
        address module = makeAddr("module");
        address[] memory modules = new address[](1);
        modules[0] = module;
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;
        
        vm.startPrank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);
        vm.stopPrank();

        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        vm.prank(module);
        cashModule.requestWithdrawalByModule(address(safe), address(usdcScroll), withdrawalAmount);

        WithdrawalRequest memory request = cashModule.getData(address(safe)).pendingWithdrawalRequest;
        assertEq(request.tokens.length, 1);
        assertEq(request.tokens[0], address(usdcScroll));
        assertEq(request.amounts[0], withdrawalAmount);
        assertEq(request.recipient, module);

        vm.prank(address(1));
        vm.expectRevert(ICashModule.OnlyModuleThatRequestedCanCancel.selector);
        cashModule.cancelWithdrawalByModule(address(safe));
    }
    
    function test_cancelWithdrawalByModule_reverts_whenCreatedByNonModule() public {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // Verify pending withdrawal was set up correctly
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), withdrawalAmount);

        address module = makeAddr("module");
        address[] memory modules = new address[](1);
        modules[0] = module;
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;
        
        vm.startPrank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);
        vm.stopPrank();
        
        vm.prank(module);
        vm.expectRevert(ICashModule.InvalidWithdrawRequest.selector);
        cashModule.cancelWithdrawalByModule(address(safe));
    }

    function test_cancelWithdrawalByModule_reverts_whenCalledByModuleRemovedFromDataProviderWhitelist() public {
        address module = makeAddr("module");
        address[] memory modules = new address[](1);
        modules[0] = module;
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;
        
        vm.startPrank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);
        vm.stopPrank();

        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        vm.prank(module);
        cashModule.requestWithdrawalByModule(address(safe), address(usdcScroll), withdrawalAmount);

        WithdrawalRequest memory request = cashModule.getData(address(safe)).pendingWithdrawalRequest;
        assertEq(request.tokens.length, 1);
        assertEq(request.tokens[0], address(usdcScroll));
        assertEq(request.amounts[0], withdrawalAmount);
        assertEq(request.recipient, module);

        // Remove from data provider whitelist after requesting withdrawal
        vm.startPrank(owner);
        shouldWhitelist[0] = false;
        dataProvider.configureModules(modules, shouldWhitelist);
        vm.stopPrank();

        vm.prank(address(module));
        vm.expectRevert(ICashModule.ModuleNotWhitelistedOnDataProvider.selector);
        cashModule.cancelWithdrawalByModule(address(safe));
    }

    function test_cancelWithdrawalByModule_reverts_whenModuleIsNotTheCaller() public {
        
    }

    function test_requestWithdrawalByModule_revertsIfModuleIsNotWhitelistedOnDataProvider() public {
        address module = makeAddr("module");
        address[] memory modules = new address[](1);
        modules[0] = module;
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;
        
        vm.startPrank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);

        // Remove from data provider whitelist after whitelisting on Cash
        shouldWhitelist[0] = false;
        dataProvider.configureModules(modules, shouldWhitelist);
        vm.stopPrank();

        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        vm.prank(module);
        vm.expectRevert(ICashModule.ModuleNotWhitelistedOnDataProvider.selector);
        cashModule.requestWithdrawalByModule(address(safe), address(usdcScroll), withdrawalAmount);
    }

    function test_requestWithdrawalByModule_revertsIfNotCalledByWhitelistedWithdrawModule() public {
        address module = makeAddr("module");
        address[] memory modules = new address[](1);
        modules[0] = module;
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;
        
        // only whitelist on data provider, not on cash module
        vm.prank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);

        vm.prank(module);
        vm.expectRevert(ICashModule.OnlyWhitelistedModuleCanRequestWithdraw.selector);
        cashModule.requestWithdrawalByModule(address(safe), address(usdcScroll), 1e6);
    }

    function test_configureModulesCanRequestWithdraw_canOnlyBeCalledByCashController() public {
        address module = makeAddr("module");
        address[] memory modules = new address[](1);
        modules[0] = module;
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        address alice = makeAddr("alice");

        vm.prank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);

        vm.prank(alice);
        vm.expectRevert(ICashModule.OnlyCashModuleController.selector);
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.ModulesCanRequestWithdrawConfigured(modules, shouldWhitelist);
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);

        address[] memory whitelistedModules = cashModule.getWhitelistedModulesCanRequestWithdraw();
        assertEq(whitelistedModules.length, 1);
        assertEq(whitelistedModules[0], module);
    }

    function test_configureModulesCanRequestWithdraw_fails_whenArrayLengthMismatch() public {
        address module = makeAddr("module");
        address[] memory modules = new address[](2);
        modules[0] = module;
        modules[1] = address(0);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.prank(owner);
        vm.expectRevert(EnumerableAddressWhitelistLib.ArrayLengthMismatch.selector);
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);
    }

    function test_configureModulesCanRequestWithdraw_fails_whenModuleNotWhitelistedOnDataProvider() public {
        address module = makeAddr("module");
        address[] memory modules = new address[](2);
        modules[0] = address(cashModule);
        modules[1] = module;

        bool[] memory shouldWhitelist = new bool[](2);
        shouldWhitelist[0] = true;
        shouldWhitelist[1] = true;

        vm.prank(owner);
        vm.expectRevert(ICashModule.ModuleNotWhitelistedOnDataProvider.selector);
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);
    }

    function test_configureModulesCanRequestWithdraw_doesNotCheckIfModuleIsWhitelistedOnDataProviderIfRemoving() public {
        address module = makeAddr("module");
        address[] memory modules = new address[](1);
        modules[0] = module;

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.startPrank(owner);    
        dataProvider.configureModules(modules, shouldWhitelist);
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);
        vm.stopPrank();

        shouldWhitelist[0] = false;
        
        vm.startPrank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);

        // Doesnt care if module is whitelisted on data provider if removing the module from whitelist
        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.ModulesCanRequestWithdrawConfigured(modules, shouldWhitelist);
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);
        vm.stopPrank();
    }

    function test_configureModulesCanRequestWithdraw_fails_whenModuleIsAddressZero() public {
        address[] memory modules = new address[](1);
        modules[0] = address(0);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.mockCall(address(dataProvider), abi.encodeWithSelector(IEtherFiDataProvider.isWhitelistedModule.selector, address(0)), abi.encode(true));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EnumerableAddressWhitelistLib.InvalidAddress.selector, 0));
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);
    }

    function test_cancelWithdrawal_works() public {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // Verify pending withdrawal was set up correctly
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), withdrawalAmount);

        _cancelWithdrawal(tokens, amounts, withdrawRecipient);

        // Verify pending withdrawal is 0
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), 0);
    }
    
    function test_cancelWithdrawal_reverts_whenNoWithdrawalQueued() public {
        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.CANCEL_WITHDRAWAL_METHOD, block.chainid, address(safe), safe.nonce())).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        
        vm.expectRevert(ICashModule.WithdrawalDoesNotExist.selector);
        cashModule.cancelWithdrawal(address(safe), signers, signatures);
    }

    function test_cancelWithdrawal_reverts_whenQueuedByWhitelistedModule() public {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        // Making withdraw recipient a whitelisted module to simulate the scenario
        address[] memory modules = new address[](1);
        modules[0] = address(withdrawRecipient);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.startPrank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);
        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);
        vm.stopPrank();

        // Verify pending withdrawal was set up correctly
        assertEq(cashModule.getPendingWithdrawalAmount(address(safe), address(usdcScroll)), withdrawalAmount);

        vm.expectRevert(ICashModule.InvalidWithdrawRequest.selector);
        cashModule.cancelWithdrawal(address(safe), new address[](0), new bytes[](0));
    }

    function test_cancelWithdraw_reverts_whenInvalidSignature() public {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.CANCEL_WITHDRAWAL_METHOD, block.chainid, address(safe), safe.nonce())).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = signatures[0]; // use the signature from owner1 itself for owner2 so its a wrong signature

        vm.expectRevert(CashVerificationLib.InvalidSignatures.selector);
        cashModule.cancelWithdrawal(address(safe), signers, signatures);
    }

    function test_cancelWithdraw_reverts_whenNoQuorum() public {
        uint256 withdrawalAmount = 50e6;
        deal(address(usdcScroll), address(safe), withdrawalAmount);

        // Setup a pending withdrawal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdcScroll);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = withdrawalAmount;

        _requestWithdrawal(tokens, amounts, withdrawRecipient);

        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.CANCEL_WITHDRAWAL_METHOD, block.chainid, address(safe), safe.nonce())).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);

        address[] memory signers = new address[](1);
        signers[0] = owner1;

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = abi.encodePacked(r1, s1, v1);

        vm.expectRevert(EtherFiSafeErrors.InsufficientSigners.selector);
        cashModule.cancelWithdrawal(address(safe), signers, signatures);
    }
}
