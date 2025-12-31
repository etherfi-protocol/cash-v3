// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ICashModule, WithdrawalRequest } from "../../../../src/interfaces/ICashModule.sol";
import { IEtherFiDataProvider } from "../../../../src/interfaces/IEtherFiDataProvider.sol";
import { MessagingFee } from "../../../../src/interfaces/IFraxRemoteHop.sol";
import { ModuleBase } from "../../../../src/modules/ModuleBase.sol";
import { ModuleCheckBalance } from "../../../../src/modules/ModuleCheckBalance.sol";
import { FraxModule } from "../../../../src/modules/frax/FraxModule.sol";
import { MessageHashUtils, SafeTestSetup } from "../../SafeTestSetup.t.sol";

contract FraxModuleTest is SafeTestSetup {
    using MessageHashUtils for bytes32;

    FraxModule fraxModule;

    IERC20 usdc = IERC20(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
    IERC20 fraxusd = IERC20(0x397F939C3b91A74C321ea7129396492bA9Cdce82);
    address custodian = 0x05bF905356fbeA7E59500f904b908402dB7A53DD;
    address remoteHop = 0xF6f45CCB5E85D1400067ee66F9e168f83e86124E;

    address depositAddress = 0xBdeb781661142740328fDefc1D9ecd03778fd810; //Fetched from Frax API for testing

    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);

        fraxModule = new FraxModule(address(dataProvider), address(fraxusd), custodian, remoteHop);

        address[] memory modules = new address[](1);
        modules[0] = address(fraxModule);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        address[] memory assets = new address[](1);
        assets[0] = address(fraxusd);

        dataProvider.configureDefaultModules(modules, shouldWhitelist);

        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);

        cashModule.configureWithdrawAssets(assets, shouldWhitelist);

        vm.stopPrank();
    }

    //Success cases
    function test_deposit_successFraxUsd() public {
        uint256 amountToDeposit = 1000 * 10 ** 6; // 1000 USDC (6 decimals)
        uint256 minReturnAmount = 1000 * 10 ** 18;
        deal(address(usdc), address(safe), amountToDeposit);

        bytes32 digestHash = keccak256(
                abi.encodePacked(
                    fraxModule.DEPOSIT_SIG(),
                    block.chainid,
                    address(fraxModule),
                    fraxModule.getNonce(address(safe)), //nonce
                    address(safe),
                    abi.encode(address(usdc), amountToDeposit, minReturnAmount)
                )
            ).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 usdcBalBefore = usdc.balanceOf(address(safe));
        uint256 fraxUsdBalBefore = fraxusd.balanceOf(address(safe));

        uint256 fraxUsdExpected = amountToDeposit * 10 ** 12; // scaled for decimals difference

        vm.expectEmit(true, true, true, true);
        emit FraxModule.Deposit(address(safe), address(usdc), amountToDeposit, fraxUsdExpected);

        fraxModule.deposit(address(safe), address(usdc), amountToDeposit, minReturnAmount, owner1, signature);

        uint256 usdcBalAfter = usdc.balanceOf(address(safe));
        uint256 fraxUsdBalAfter = fraxusd.balanceOf(address(safe));

        assertEq(usdcBalAfter, usdcBalBefore - amountToDeposit);
        assertGt(fraxUsdBalAfter, fraxUsdBalBefore);
    }

    function test_withdraw_successFraxUsd() public {
        vm.prank(owner);

        uint128 amountToWithdraw = 1000 * 10 ** 18;
        uint128 minReceiveAmount = 1000 * 10 ** 6;
        deal(address(fraxusd), address(safe), amountToWithdraw);
        deal(address(usdc), address(custodian), amountToWithdraw);

        bytes32 digestHash = keccak256(
                abi.encodePacked(
                    fraxModule.WITHDRAW_SIG(),
                    block.chainid,
                    address(fraxModule),
                    fraxModule.getNonce(address(safe)), //nonce
                    address(safe),
                    abi.encode(amountToWithdraw, address(usdc), minReceiveAmount)
                )
            ).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 fraxUsdBalBefore = fraxusd.balanceOf(address(safe));
        uint256 assetBefore = usdc.balanceOf(address(safe));

        vm.expectEmit(true, true, true, true);
        emit FraxModule.Withdrawal(address(safe), address(usdc), amountToWithdraw, minReceiveAmount);

        fraxModule.withdraw(address(safe), amountToWithdraw, address(usdc), minReceiveAmount, owner1, signature);

        uint256 fraxUsdBalAfter = fraxusd.balanceOf(address(safe));
        uint256 assetAfter = usdc.balanceOf(address(safe));
        assertEq(fraxUsdBalAfter, fraxUsdBalBefore - amountToWithdraw);
        assertEq(minReceiveAmount, assetAfter - assetBefore);
    }

    function test_requestAsyncWithdrawAndExecuteAsyncWithdraw_success() public {
        vm.prank(owner);

        uint256 amountToWithdraw = 1 * 10 ** 18;
        deal(address(fraxusd), address(safe), amountToWithdraw);
        deal(address(safe), 1 ether);

        bytes32 digestHash = keccak256(
                abi.encodePacked(
                    fraxModule.REQUEST_ASYNC_WITHDRAW_SIG(),
                    block.chainid,
                    address(fraxModule),
                    fraxModule.getNonce(address(safe)), //nonce
                    safe,
                    abi.encode(fraxusd, depositAddress, amountToWithdraw)
                )
            ).toEthSignedMessageHash();

        MessagingFee memory fee = fraxModule.quoteAsyncWithdraw(depositAddress, amountToWithdraw);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);

        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 fraxUsdBalBefore = fraxusd.balanceOf(address(safe));

        vm.expectEmit(true, true, true, true);
        emit FraxModule.AsyncWithdrawalRequested(address(safe), amountToWithdraw, fraxModule.ETHEREUM_EID(), depositAddress);

        fraxModule.requestAsyncWithdraw(address(safe), depositAddress, amountToWithdraw, owner1, signature);

        (uint64 withdrawalDelay,,) = cashModule.getDelays();
        vm.warp(block.timestamp + withdrawalDelay);

        vm.expectEmit(true, true, true, true);
        emit FraxModule.AsyncWithdrawalExecuted(address(safe), amountToWithdraw, fraxModule.ETHEREUM_EID(), depositAddress);
        fraxModule.executeAsyncWithdraw{ value: fee.nativeFee }(address(safe));

        uint256 fraxUsdBalAfter = fraxusd.balanceOf(address(safe));
        assertEq(fraxUsdBalAfter, fraxUsdBalBefore - amountToWithdraw);
    }

    function test_requestAsyncWithdrawal_createsWithdrawal() public {
        vm.prank(owner);
        uint256 amount = 1000 * 10 ** 18;
        deal(address(fraxusd), address(safe), amount);

        uint256 fraxUsdBalBefore = fraxusd.balanceOf(address(safe));

        _requestAsyncWithdrawal(amount);

        uint256 fraxUsdBalAfter = fraxusd.balanceOf(address(safe));
        assertEq(fraxUsdBalAfter, fraxUsdBalBefore);

        // Check that a withdrawal request was created
        WithdrawalRequest memory request = cashModule.getData(address(safe)).pendingWithdrawalRequest;
        assertEq(request.tokens.length, 1);
        assertEq(request.tokens[0], address(fraxusd));
        assertEq(request.amounts[0], amount);
        assertEq(request.recipient, address(fraxModule));

        FraxModule.AsyncWithdrawal memory withdrawal = fraxModule.getPendingWithdrawal(address(safe));
        assertEq(withdrawal.amount, amount);
        assertEq(withdrawal.recipient, depositAddress);
    }

    function test_requestAsyncWithdrawal_executesAsyncWithdrawal_whenTheWithdrawDelayIsZero() public {
        // make withdraw delay 0
        vm.prank(owner);
        cashModule.setDelays(0, 0, 0);

        uint256 amount = 10 * 10 ** 18;
        deal(address(fraxusd), address(safe), amount);

        bytes32 digestHash = keccak256(
                abi.encodePacked(
                    fraxModule.REQUEST_ASYNC_WITHDRAW_SIG(),
                    block.chainid,
                    address(fraxModule),
                    safe.nonce(), //nonce
                    address(safe),
                    abi.encode(address(fraxusd), depositAddress, amount)
                )
            ).toEthSignedMessageHash();

        MessagingFee memory fee = fraxModule.quoteAsyncWithdraw(depositAddress, amount);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 liquidAssetBalBefore = fraxusd.balanceOf(address(safe));

        vm.expectEmit(true, true, true, true);
        emit FraxModule.AsyncWithdrawalRequested(address(safe), amount, fraxModule.ETHEREUM_EID(), depositAddress);
        vm.expectEmit(true, true, true, true);
        emit FraxModule.AsyncWithdrawalExecuted(address(safe), amount, fraxModule.ETHEREUM_EID(), depositAddress);
        fraxModule.requestAsyncWithdraw{ value: fee.nativeFee }(address(safe), depositAddress, amount, owner1, signature);

        uint256 liquidAssetBalAfter = fraxusd.balanceOf(address(safe));
        assertEq(liquidAssetBalAfter, liquidAssetBalBefore - amount);
    }

    //Revert cases

    function test_deposit_revertsWhenInvalidSignature() public {
        uint256 amountToDeposit = 1000 * 10 ** 6; // 1000 USDC (6 decimals)
        uint256 minReturnAmount = 1000 * 10 ** 18;
        deal(address(usdc), address(safe), amountToDeposit);

        bytes32 digestHash = keccak256(
                abi.encodePacked(
                    fraxModule.DEPOSIT_SIG(),
                    block.chainid,
                    address(fraxModule),
                    fraxModule.getNonce(address(safe)), //nonce
                    address(safe),
                    abi.encode(address(usdc), amountToDeposit, minReturnAmount)
                )
            ).toEthSignedMessageHash();

        // Sign with a different private key
        uint256 wrongPrivateKey = 0x54321;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, digestHash);
        bytes memory invalidSignature = abi.encodePacked(r, s, v);

        vm.expectRevert(); // Should revert due to ECDSA recovery failure
        fraxModule.deposit(address(safe), address(usdc), amountToDeposit, minReturnAmount, owner1, invalidSignature);
    }

    function test_deposit_revertsForNonAdminSigner() public {
        uint256 amountToDeposit = 1000 * 10 ** 6; // 1000 USDC (6 decimals)
        uint256 minReturnAmount = 1000 * 10 ** 18;
        deal(address(usdc), address(safe), amountToDeposit);

        // Create a non-admin address
        address nonAdmin = makeAddr("nonAdmin");

        bytes32 digestHash = keccak256(
                abi.encodePacked(
                    fraxModule.DEPOSIT_SIG(),
                    block.chainid,
                    address(fraxModule),
                    fraxModule.getNonce(address(safe)), //nonce
                    address(safe),
                    abi.encode(address(usdc), amountToDeposit, minReturnAmount)
                )
            ).toEthSignedMessageHash();

        // Sign with owner1's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory validSignature = abi.encodePacked(r, s, v);

        // Try to use a non-admin signer
        vm.expectRevert();
        fraxModule.deposit(address(safe), address(usdc), amountToDeposit, minReturnAmount, nonAdmin, validSignature);
    }

    function test_deposit_revertsWithZeroAmount() public {
        vm.prank(owner);

        uint128 amountToDeposit = 0;
        uint256 minReturnAmount = 1000 * 10 ** 18;

        bytes32 digestHash = keccak256(abi.encodePacked(fraxModule.DEPOSIT_SIG(), block.chainid, address(fraxModule), fraxModule.getNonce(address(safe)), address(safe), abi.encode(address(usdc), amountToDeposit, minReturnAmount))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        fraxModule.deposit(address(safe), address(usdc), amountToDeposit, minReturnAmount, owner1, signature);
    }

    function test_deposit_revertsWithInsufficientBalance() public {
        vm.prank(owner);

        // Ensure the safe has some balance, but less than we'll try to deposit
        uint256 safeBalance = 500 * 10 ** 6;
        uint128 amountToDeposit = 1000 * 10 ** 6; // More than balance
        uint128 minReturnAmount = 1000 * 10 ** 18;
        deal(address(fraxusd), address(safe), safeBalance);

        bytes32 digestHash = keccak256(abi.encodePacked(fraxModule.DEPOSIT_SIG(), block.chainid, address(fraxModule), fraxModule.getNonce(address(safe)), address(safe), abi.encode(address(usdc), amountToDeposit, minReturnAmount))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        fraxModule.deposit(address(safe), address(usdc), amountToDeposit, minReturnAmount, owner1, signature);
    }

    function test_withdraw_revertsWithZeroAmount() public {
        vm.prank(owner);

        uint128 amountToWithdraw = 0;
        uint256 minReceiveAmount = 1000 * 10 ** 6;

        bytes32 digestHash = keccak256(
                abi.encodePacked(
                    fraxModule.WITHDRAW_SIG(),
                    block.chainid,
                    address(fraxModule),
                    fraxModule.getNonce(address(safe)), //nonce
                    address(safe),
                    abi.encode(amountToWithdraw, address(usdc), minReceiveAmount)
                )
            ).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        fraxModule.withdraw(address(safe), amountToWithdraw, address(usdc), minReceiveAmount, owner1, signature);
    }

    function test_withdraw_revertsWithInsufficientBalance() public {
        vm.prank(owner);

        // Ensure the safe has some balance, but less than we'll try to withdraw
        uint256 safeBalance = 500 * 10 ** 18;
        uint128 amountToWithdraw = 1000 * 10 ** 18; // More than balance
        uint256 minReceiveAmount = 1000 * 10 ** 6;
        deal(address(fraxusd), address(safe), safeBalance);

        bytes32 digestHash = keccak256(
                abi.encodePacked(
                    fraxModule.WITHDRAW_SIG(),
                    block.chainid,
                    address(fraxModule),
                    fraxModule.getNonce(address(safe)), //nonce
                    address(safe),
                    abi.encode(amountToWithdraw, address(usdc), minReceiveAmount)
                )
            ).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        fraxModule.withdraw(address(safe), amountToWithdraw, address(usdc), minReceiveAmount, owner1, signature);
    }

    function test_withdraw_revertsWithInvalidSignature() public {
        vm.prank(owner);

        uint128 amountToWithdraw = 1000 * 10 ** 18;
        uint128 minReceiveAmount = 1000 * 10 ** 6;
        deal(address(fraxusd), address(safe), amountToWithdraw);

        bytes32 digestHash = keccak256(
                abi.encodePacked(
                    fraxModule.WITHDRAW_SIG(),
                    block.chainid,
                    address(fraxModule),
                    fraxModule.getNonce(address(safe)), //nonce
                    address(safe),
                    abi.encode(amountToWithdraw)
                )
            ).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner2Pk, digestHash);
        bytes memory invalidSignature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        fraxModule.withdraw(address(safe), amountToWithdraw, address(usdc), minReceiveAmount, owner1, invalidSignature);
    }

    function test_withdraw_revertsForNonAdminSigner() public {
        vm.prank(owner);

        address fakeSafe = makeAddr("fakeSafe");
        uint128 amountToWithdraw = 1000 * 10 ** 18;
        uint128 minReceiveAmount = 1000 * 10 ** 6;
        deal(address(fraxusd), address(fakeSafe), amountToWithdraw);

        bytes32 digestHash = keccak256(
                abi.encodePacked(
                    fraxModule.WITHDRAW_SIG(),
                    block.chainid,
                    address(fraxModule),
                    uint256(0), // nonce
                    fakeSafe,
                    abi.encode(amountToWithdraw, address(usdc), minReceiveAmount)
                )
            ).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory invalidSignature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleBase.OnlyEtherFiSafe.selector);
        fraxModule.withdraw(address(fakeSafe), amountToWithdraw, address(usdc), minReceiveAmount, owner1, invalidSignature);
    }

    function test_executeAsyncWithdrawal_reverts_ifWithdrawalDelayIsNotOver() public {
        uint256 amount = 1000 * 10 ** 18;
        deal(address(fraxusd), address(safe), amount);
        deal(address(safe), 1 ether);

        _requestAsyncWithdrawal(amount);

        vm.expectRevert(ICashModule.CannotWithdrawYet.selector);
        fraxModule.executeAsyncWithdraw{ value: 1 }(address(safe));
    }

    function test_executeAsyncWithdrawal_reverts_whenNoWithdrawalQueued() public {
        vm.expectRevert(FraxModule.NoAsyncWithdrawalQueued.selector);
        fraxModule.executeAsyncWithdraw{ value: 0 }(address(safe));
    }

    function test_requestAsyncWithdrawal_insufficientAmount() public {
        uint256 amount = 1000 * 10 ** 18;
        // deal less amount than required
        deal(address(fraxusd), address(safe), amount - 1);

        bytes32 digestHash = keccak256(abi.encodePacked(fraxModule.REQUEST_ASYNC_WITHDRAW_SIG(), block.chainid, address(fraxModule), fraxModule.getNonce(address(safe)), safe, abi.encode(fraxusd, depositAddress, amount))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ICashModule.InsufficientBalance.selector);
        fraxModule.requestAsyncWithdraw(address(safe), depositAddress, amount, owner1, signature);
    }

    function test_requestAsyncWithdrawal_invalidInput() public {
        uint256 amount = 1000 * 10 ** 18;
        deal(address(fraxusd), address(safe), amount);

        bytes32 digestHash = keccak256(abi.encodePacked(fraxModule.REQUEST_ASYNC_WITHDRAW_SIG(), block.chainid, address(fraxModule), fraxModule.getNonce(address(safe)), safe, abi.encode(fraxusd, address(0), amount))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        //Test with zero address for depositAddress
        fraxModule.requestAsyncWithdraw(address(safe), address(0), amount, owner1, signature);

        // Test with zero amount
        bytes32 digestHash1 = keccak256(abi.encodePacked(fraxModule.REQUEST_ASYNC_WITHDRAW_SIG(), block.chainid, address(fraxModule), fraxModule.getNonce(address(safe)), safe, abi.encode(fraxusd, depositAddress, 0))).toEthSignedMessageHash();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash1);
        bytes memory signature1 = abi.encodePacked(r1, s1, v1);

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        //Test with zero address for depositAddress
        fraxModule.requestAsyncWithdraw(address(safe), depositAddress, 0, owner1, signature1);
    }

    function _requestAsyncWithdrawal(uint256 amount) internal {
        bytes32 digestHash = keccak256(abi.encodePacked(fraxModule.REQUEST_ASYNC_WITHDRAW_SIG(), block.chainid, address(fraxModule), fraxModule.getNonce(address(safe)), safe, abi.encode(fraxusd, depositAddress, amount))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectEmit(true, true, true, true);
        emit FraxModule.AsyncWithdrawalRequested(address(safe), amount, 30_101, depositAddress);
        fraxModule.requestAsyncWithdraw(address(safe), depositAddress, amount, owner1, signature);
    }
}
