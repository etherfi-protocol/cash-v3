// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ICashModule } from "../../../../src/interfaces/ICashModule.sol";
import { IEtherFiDataProvider } from "../../../../src/interfaces/IEtherFiDataProvider.sol";
import { ModuleBase } from "../../../../src/modules/ModuleBase.sol";
import { ModuleCheckBalance } from "../../../../src/modules/ModuleCheckBalance.sol";
import { MidasModule } from "../../../../src/modules/midas/MidasModule.sol";
import { IAggregatorV3 } from "../../../../src/oracle/PriceProvider.sol";
import { EtherFiSafeErrors } from "../../../../src/safe/EtherFiSafeErrors.sol";
import { MessageHashUtils, SafeTestSetup } from "../../SafeTestSetup.t.sol";

contract MidasModuleTest is SafeTestSetup {
    using MessageHashUtils for bytes32;

    MidasModule midasModule;

    IERC20 midasToken = IERC20(0xb7Fb3768CAAC98354EaDF514b48f28F2fE822bF0);
    IERC20 usdc = IERC20(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
    IERC20 usdt = IERC20(0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df);

    address depositVault = 0xcA1C871f8ae2571Cb126A46861fc06cB9E645152;
    address redemptionVault = 0x904EA8d7FcaB7351758fAC82bDbc738E2010BC25;

    IAggregatorV3 usdtOracle = IAggregatorV3(0xf376A91Ae078927eb3686D6010a6f1482424954E);
    IAggregatorV3 usdcOracle = IAggregatorV3(0x43d12Fb3AfCAd5347fA764EeAB105478337b7200);
    IAggregatorV3 mTokenOracle = IAggregatorV3(0xB2a4eC4C9b95D7a87bA3989d0FD38dFfDd944A24);

    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);

        // Prepare arrays for Midas module deployment
        address[] memory midasTokens = new address[](1);
        midasTokens[0] = address(midasToken);

        address[] memory depositVaults = new address[](1);
        depositVaults[0] = depositVault;

        address[] memory redemptionVaults = new address[](1);
        redemptionVaults[0] = redemptionVault;

        midasModule = new MidasModule(address(dataProvider), midasTokens, depositVaults, redemptionVaults);

        address[] memory modules = new address[](1);
        modules[0] = address(midasModule);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        address[] memory assets = new address[](1);
        assets[0] = address(midasToken);

        dataProvider.configureDefaultModules(modules, shouldWhitelist);

        cashModule.configureModulesCanRequestWithdraw(modules, shouldWhitelist);

        cashModule.configureWithdrawAssets(assets, shouldWhitelist);

        vm.stopPrank();
    }

    //Success cases
    function test_deposit_usdc_successMidasVault() public {
        uint256 amount = 1000 * 10 ** 6; // 1000 USDC (6 decimals)
        deal(address(usdc), address(safe), amount);

        uint256 minReturnAmount = amount * 10 ** 12; //1:1 minting

        bytes32 digestHash = keccak256(abi.encodePacked(midasModule.DEPOSIT_SIG(), block.chainid, address(midasModule), midasModule.getNonce(address(safe)), address(safe), abi.encode(address(usdc), address(midasToken), amount, minReturnAmount))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 usdcBefore = usdc.balanceOf(address(safe));
        uint256 midasBefore = midasToken.balanceOf(address(safe));

        vm.expectEmit(true, true, true, true);
        emit MidasModule.Deposit(address(safe), address(usdc), amount, address(midasToken), minReturnAmount);

        midasModule.deposit(address(safe), address(usdc), address(midasToken), amount, minReturnAmount, owner1, signature);

        uint256 usdcAfter = usdc.balanceOf(address(safe));
        uint256 midasAfter = midasToken.balanceOf(address(safe));

        assertEq(usdcAfter, usdcBefore - amount);
        assertEq(minReturnAmount, midasAfter - midasBefore);
    }

    function test_deposit_usdt_successMidasVault() public {
        uint256 amount = 1000 * 10 ** 6; // 1000 USDT (6 decimals)
        deal(address(usdt), address(safe), amount);

        uint256 minReturnAmount = amount * 10 ** 12; //1:1 minting

        bytes32 digestHash = keccak256(abi.encodePacked(midasModule.DEPOSIT_SIG(), block.chainid, address(midasModule), midasModule.getNonce(address(safe)), address(safe), abi.encode(address(usdt), address(midasToken), amount, minReturnAmount))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 usdtBefore = usdt.balanceOf(address(safe));
        uint256 midasBefore = midasToken.balanceOf(address(safe));

        vm.expectEmit(true, true, true, true);
        emit MidasModule.Deposit(address(safe), address(usdt), amount, address(midasToken), minReturnAmount);

        midasModule.deposit(address(safe), address(usdt), address(midasToken), amount, minReturnAmount, owner1, signature);

        uint256 usdtAfter = usdt.balanceOf(address(safe));
        uint256 midasAfter = midasToken.balanceOf(address(safe));

        assertEq(usdtAfter, usdtBefore - amount);
        assertEq(minReturnAmount, midasAfter - midasBefore);
    }

    function test_withdraw_usdc_successMidasVault() public {
        vm.prank(owner);

        uint128 amount = 1000 * 10 ** 18;
        deal(address(midasToken), address(safe), amount);

        bytes32 digestHash = keccak256(abi.encodePacked(midasModule.WITHDRAW_SIG(), block.chainid, address(midasModule), midasModule.getNonce(address(safe)), address(safe), abi.encode(address(midasToken), amount, address(usdc)))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 midasBefore = midasToken.balanceOf(address(safe));

        vm.expectEmit(true, true, true, true);
        emit MidasModule.Withdrawal(address(safe), amount, address(usdc), address(midasToken));

        midasModule.withdraw(address(safe), address(midasToken), amount, address(usdc), owner1, signature);

        uint256 midasAfter = midasToken.balanceOf(address(safe));
        assertEq(midasAfter, midasBefore - amount);
    }

    function test_withdraw_usdt_successMidasVault() public {
        vm.prank(owner);

        uint128 amount = 1000 * 10 ** 18;
        deal(address(midasToken), address(safe), amount);

        bytes32 digestHash = keccak256(abi.encodePacked(midasModule.WITHDRAW_SIG(), block.chainid, address(midasModule), midasModule.getNonce(address(safe)), address(safe), abi.encode(address(midasToken), amount, address(usdt)))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 midasBefore = midasToken.balanceOf(address(safe));

        vm.expectEmit(true, true, true, true);
        emit MidasModule.Withdrawal(address(safe), amount, address(usdt), address(midasToken));

        midasModule.withdraw(address(safe), address(midasToken), amount, address(usdt), owner1, signature);

        uint256 midasAfter = midasToken.balanceOf(address(safe));
        assertEq(midasAfter, midasBefore - amount);
    }


    //Revert cases

    function test_deposit_revertsWhenInvalidSignature() public {
        uint256 amount = 1000 * 10 ** 6; // 1000 USDC (6 decimals)
        deal(address(usdc), address(safe), amount);

        uint256 minReturnAmount = amount * 10 ** 12;

        bytes32 digestHash = keccak256(abi.encodePacked(midasModule.DEPOSIT_SIG(), block.chainid, address(midasModule), midasModule.getNonce(address(safe)), address(safe), abi.encode(address(usdc), address(midasToken), amount, minReturnAmount))).toEthSignedMessageHash();

        // Sign with a different private key
        uint256 wrongPrivateKey = 0x54321;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, digestHash);
        bytes memory invalidSignature = abi.encodePacked(r, s, v);

        vm.expectRevert(); // Should revert due to ECDSA recovery failure
        midasModule.deposit(address(safe), address(usdc), address(midasToken), amount, minReturnAmount, owner1, invalidSignature);
    }

    function test_deposit_revertsForNonAdminSigner() public {
        uint256 amount = 1000 * 10 ** 6; // 1000 USDC (6 decimals)
        deal(address(usdc), address(safe), amount);

        uint256 minReturnAmount = amount * 10 ** 12;

        // Create a non-admin address
        address nonAdmin = makeAddr("nonAdmin");

        bytes32 digestHash = keccak256(
                abi.encodePacked(
                    midasModule.DEPOSIT_SIG(),
                    block.chainid,
                    address(midasModule),
                    midasModule.getNonce(address(safe)), //nonce
                    address(safe),
                    abi.encode(address(usdc), address(midasToken), amount, minReturnAmount)
                )
            ).toEthSignedMessageHash();

        // Sign with owner1's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory validSignature = abi.encodePacked(r, s, v);

        // Try to use a non-admin signer
        vm.expectRevert();
        midasModule.deposit(address(safe), address(usdc), address(midasToken), amount, minReturnAmount, nonAdmin, validSignature);
    }

    function test_deposit_revertsWithZeroAmount() public {
        vm.prank(owner);

        uint128 amount = 0;
        uint256 minReturnAmount = 1000 * 10 ** 12;

        bytes32 digestHash = keccak256(
                abi.encodePacked(
                    midasModule.DEPOSIT_SIG(),
                    block.chainid,
                    address(midasModule),
                    midasModule.getNonce(address(safe)), //nonce
                    address(safe),
                    abi.encode(address(usdc), address(midasToken), amount, minReturnAmount)
                )
            ).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        midasModule.deposit(address(safe), address(usdc), address(midasToken), amount, minReturnAmount, owner1, signature);
    }

    function test_deposit_revertsWithInsufficientBalance() public {
        vm.prank(owner);

        // Ensure the safe has some balance, but less than we'll try to deposit
        uint256 safeBalance = 500 * 10 ** 6;
        uint128 amount = 1000 * 10 ** 6; // More than balance
        deal(address(usdc), address(safe), safeBalance);

        uint256 minReturnAmount = amount * 10 ** 12;

        bytes32 digestHash = keccak256(
                abi.encodePacked(
                    midasModule.DEPOSIT_SIG(),
                    block.chainid,
                    address(midasModule),
                    midasModule.getNonce(address(safe)), //nonce
                    address(safe),
                    abi.encode(address(usdc), address(midasToken), amount, minReturnAmount)
                )
            ).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        midasModule.deposit(address(safe), address(usdc), address(midasToken), amount, minReturnAmount, owner1, signature);
    }

    function test_withdraw_revertsWithZeroAmount() public {
        vm.prank(owner);

        uint128 amount = 0;

        bytes32 digestHash = keccak256(abi.encodePacked(midasModule.WITHDRAW_SIG(), block.chainid, address(midasModule), midasModule.getNonce(address(safe)), address(safe), abi.encode(address(midasToken), amount, address(usdc)))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        midasModule.withdraw(address(safe), address(midasToken), amount, address(usdc), owner1, signature);
    }

    function test_withdraw_revertsWithInsufficientBalance() public {
        vm.prank(owner);

        // Ensure the safe has some balance, but less than we'll try to withdraw
        uint256 safeBalance = 500 * 10 ** 18;
        uint128 amount = 1000 * 10 ** 18; // More than balance
        deal(address(midasToken), address(safe), safeBalance);

        bytes32 digestHash = keccak256(
                abi.encodePacked(
                    midasModule.WITHDRAW_SIG(),
                    block.chainid,
                    address(midasModule),
                    midasModule.getNonce(address(safe)), //nonce
                    address(safe),
                    abi.encode(address(midasToken), amount, address(usdc))
                )
            ).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        midasModule.withdraw(address(safe), address(midasToken), amount, address(usdc), owner1, signature);
    }

    function test_withdraw_revertsWithInvalidSignature() public {
        vm.prank(owner);

        uint128 amount = 1000 * 10 ** 18;
        deal(address(midasToken), address(safe), amount);

        bytes32 digestHash = keccak256(
                abi.encodePacked(
                    midasModule.WITHDRAW_SIG(),
                    block.chainid,
                    address(midasModule),
                    midasModule.getNonce(address(safe)), //nonce
                    address(safe),
                    abi.encode(address(midasToken), amount, address(usdc))
                )
            ).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner2Pk, digestHash);
        bytes memory invalidSignature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        midasModule.withdraw(address(safe), address(midasToken), amount, address(usdc), owner1, invalidSignature);
    }

    function test_withdraw_revertsForNonAdminSigner() public {
        vm.prank(owner);

        address fakeSafe = makeAddr("fakeSafe");
        uint128 amount = 1000 * 10 ** 18;

        deal(address(midasToken), address(fakeSafe), amount);

        bytes32 digestHash = keccak256(
                abi.encodePacked(
                    midasModule.WITHDRAW_SIG(),
                    block.chainid,
                    address(midasModule),
                    uint256(0), // nonce
                    fakeSafe,
                    abi.encode(address(midasToken), amount, address(usdc))
                )
            ).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory invalidSignature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleBase.OnlyEtherFiSafe.selector);
        midasModule.withdraw(address(fakeSafe), address(midasToken), amount, address(usdc), owner1, invalidSignature);
    }


    function test_deposit_revertsWithUnsupportedMidasToken() public {
        uint256 amount = 1000 * 10 ** 6;
        deal(address(usdc), address(safe), amount);
        uint256 minReturnAmount = amount * 10 ** 12;

        address unsupportedMidasToken = makeAddr("unsupportedMidasToken");

        bytes32 digestHash = keccak256(abi.encodePacked(midasModule.DEPOSIT_SIG(), block.chainid, address(midasModule), midasModule.getNonce(address(safe)), address(safe), abi.encode(address(usdc), unsupportedMidasToken, amount, minReturnAmount))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(MidasModule.UnsupportedMidasToken.selector);
        midasModule.deposit(address(safe), address(usdc), unsupportedMidasToken, amount, minReturnAmount, owner1, signature);
    }

    function test_deposit_revertsWithInsufficientReturnAmount() public {
        uint256 amount = 1000 * 10 ** 6;
        deal(address(usdc), address(safe), amount);
        // Set minReturnAmount higher than what the vault will return
        // The vault will revert with CallFailed, not InsufficientReturnAmount
        uint256 minReturnAmount = amount * 10 ** 12 + 1;

        bytes32 digestHash = keccak256(abi.encodePacked(midasModule.DEPOSIT_SIG(), block.chainid, address(midasModule), midasModule.getNonce(address(safe)), address(safe), abi.encode(address(usdc), address(midasToken), amount, minReturnAmount))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // The vault call will fail first, causing CallFailed
        vm.expectRevert(abi.encodeWithSelector(EtherFiSafeErrors.CallFailed.selector, 1));
        midasModule.deposit(address(safe), address(usdc), address(midasToken), amount, minReturnAmount, owner1, signature);
    }

    function test_deposit_revertsWithZeroAddress() public {
        uint256 amount = 1000 * 10 ** 6;
        deal(address(usdc), address(safe), amount);
        uint256 minReturnAmount = amount * 10 ** 12;

        bytes32 digestHash = keccak256(abi.encodePacked(midasModule.DEPOSIT_SIG(), block.chainid, address(midasModule), midasModule.getNonce(address(safe)), address(safe), abi.encode(address(0), address(midasToken), amount, minReturnAmount))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        midasModule.deposit(address(safe), address(0), address(midasToken), amount, minReturnAmount, owner1, signature);
    }

    function test_withdraw_revertsWithUnsupportedMidasToken() public {
        uint128 amount = 1000 * 10 ** 18;
        // Use a real address that isn't a supported Midas token
        address unsupportedMidasToken = 0x397F939C3b91A74C321ea7129396492bA9Cdce82; //Frax USD
        deal(address(midasToken), address(safe), amount);

        bytes32 digestHash = keccak256(abi.encodePacked(midasModule.WITHDRAW_SIG(), block.chainid, address(midasModule), midasModule.getNonce(address(safe)), address(safe), abi.encode(unsupportedMidasToken, amount, address(usdc)))).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(MidasModule.UnsupportedMidasToken.selector);
        midasModule.withdraw(address(safe), unsupportedMidasToken, amount, address(usdc), owner1, signature);
    }


    // Admin function tests
    function test_addMidasVaults_success() public {
        vm.startPrank(owner);
        roleRegistry.grantRole(midasModule.MIDAS_MODULE_ADMIN(), owner);
        vm.stopPrank();

        address newMidasToken = makeAddr("newMidasToken");
        address newDepositVault = makeAddr("newDepositVault");
        address newRedemptionVault = makeAddr("newRedemptionVault");

        address[] memory midasTokens = new address[](1);
        midasTokens[0] = newMidasToken;

        address[] memory depositVaults = new address[](1);
        depositVaults[0] = newDepositVault;

        address[] memory redemptionVaults = new address[](1);
        redemptionVaults[0] = newRedemptionVault;

        vm.expectEmit(true, true, true, true);
        emit MidasModule.MidasVaultsAdded(midasTokens, depositVaults, redemptionVaults);

        vm.prank(owner);
        midasModule.addMidasVaults(midasTokens, depositVaults, redemptionVaults);

        (address depositVaultResult, address redemptionVaultResult) = midasModule.vaults(newMidasToken);
        assertEq(depositVaultResult, newDepositVault);
        assertEq(redemptionVaultResult, newRedemptionVault);
    }

    function test_addMidasVaults_revertsWhenUnauthorized() public {
        address newMidasToken = makeAddr("newMidasToken");
        address[] memory midasTokens = new address[](1);
        midasTokens[0] = newMidasToken;

        address[] memory depositVaults = new address[](1);
        depositVaults[0] = makeAddr("depositVault");

        address[] memory redemptionVaults = new address[](1);
        redemptionVaults[0] = makeAddr("redemptionVault");

        vm.expectRevert(MidasModule.Unauthorized.selector);
        vm.prank(owner1);
        midasModule.addMidasVaults(midasTokens, depositVaults, redemptionVaults);
    }

    function test_addMidasVaults_revertsWithArrayLengthMismatch() public {
        vm.startPrank(owner);
        roleRegistry.grantRole(midasModule.MIDAS_MODULE_ADMIN(), owner);
        vm.stopPrank();

        address[] memory midasTokens = new address[](1);
        midasTokens[0] = makeAddr("midasToken");

        address[] memory depositVaults = new address[](2); // Mismatch
        depositVaults[0] = makeAddr("depositVault1");
        depositVaults[1] = makeAddr("depositVault2");

        address[] memory redemptionVaults = new address[](1);
        redemptionVaults[0] = makeAddr("redemptionVault");

        vm.expectRevert(ModuleBase.ArrayLengthMismatch.selector);
        vm.prank(owner);
        midasModule.addMidasVaults(midasTokens, depositVaults, redemptionVaults);
    }

    function test_addMidasVaults_revertsWithZeroAddress() public {
        vm.startPrank(owner);
        roleRegistry.grantRole(midasModule.MIDAS_MODULE_ADMIN(), owner);
        vm.stopPrank();

        address[] memory midasTokens = new address[](1);
        midasTokens[0] = address(0); // Zero address

        address[] memory depositVaults = new address[](1);
        depositVaults[0] = makeAddr("depositVault");

        address[] memory redemptionVaults = new address[](1);
        redemptionVaults[0] = makeAddr("redemptionVault");

        vm.expectRevert(ModuleBase.InvalidInput.selector);
        vm.prank(owner);
        midasModule.addMidasVaults(midasTokens, depositVaults, redemptionVaults);
    }

    function test_removeMidasVaults_success() public {
        vm.startPrank(owner);
        roleRegistry.grantRole(midasModule.MIDAS_MODULE_ADMIN(), owner);
        vm.stopPrank();

        address[] memory midasTokens = new address[](1);
        midasTokens[0] = address(midasToken);

        vm.expectEmit(true, true, true, true);
        emit MidasModule.MidasVaultsRemoved(midasTokens);

        vm.prank(owner);
        midasModule.removeMidasVaults(midasTokens);

        (address depositVaultResult, address redemptionVaultResult) = midasModule.vaults(address(midasToken));
        assertEq(depositVaultResult, address(0));
        assertEq(redemptionVaultResult, address(0));
    }

    function test_removeMidasVaults_revertsWhenUnauthorized() public {
        address[] memory midasTokens = new address[](1);
        midasTokens[0] = address(midasToken);

        vm.expectRevert(MidasModule.Unauthorized.selector);
        vm.prank(owner1);
        midasModule.removeMidasVaults(midasTokens);
    }

}
