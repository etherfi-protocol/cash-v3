// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Test, console } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUp } from "../../src/top-up/TopUp.sol";
import { BeaconFactory, TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { EtherFiOFTBridgeAdapter } from "../../src/top-up/bridge/EtherFiOFTBridgeAdapter.sol";
import { StargateAdapter } from "../../src/top-up/bridge/StargateAdapter.sol";
import { Constants } from "../../src/utils/Constants.sol";

contract TopUpFactoryTest is Test, Constants {
    TopUpFactory public factory;
    TopUp public implementation;
    address public owner;
    address public admin;
    address public alice;
    address public user;
    address public pauser;
    address public unpauser;
    RoleRegistry public roleRegistry;
    EtherFiOFTBridgeAdapter oftBridgeAdapter;
    StargateAdapter stargateAdapter;

    uint96 maxSlippage = 100;

    IERC20 weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 weETH = IERC20(0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee);
    IERC20 usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    address weETHOftAddress = 0xcd2eb13D6831d4602D80E5db9230A57596CDCA63;
    address usdcStargatePool = 0xc026395860Db2d07ee33e05fE50ed7bD583189C7;

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");

        owner = makeAddr("owner");
        admin = makeAddr("admin");
        user = makeAddr("user");
        alice = makeAddr("alice");
        pauser = makeAddr("pauser");
        unpauser = makeAddr("unpauser");

        vm.startPrank(owner);

        stargateAdapter = new StargateAdapter();
        oftBridgeAdapter = new EtherFiOFTBridgeAdapter();

        address roleRegistryImpl = address(new RoleRegistry());
        roleRegistry = RoleRegistry(address(new UUPSProxy(roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));
        roleRegistry.grantRole(roleRegistry.PAUSER(), pauser);
        roleRegistry.grantRole(roleRegistry.UNPAUSER(), unpauser);

        implementation = new TopUp();
        address factoryImpl = address(new TopUpFactory());
        factory = TopUpFactory(payable(address(new UUPSProxy(factoryImpl, abi.encodeWithSelector(TopUpFactory.initialize.selector, address(roleRegistry), implementation)))));
        roleRegistry.grantRole(factory.TOPUP_FACTORY_ADMIN_ROLE(), admin);

        vm.stopPrank();

        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weETH);

        TopUpFactory.TokenConfig[] memory tokenConfigs = new TopUpFactory.TokenConfig[](2);
        tokenConfigs[0] = TopUpFactory.TokenConfig({ bridgeAdapter: address(stargateAdapter), recipientOnDestChain: alice, maxSlippageInBps: maxSlippage, additionalData: abi.encode(usdcStargatePool) });

        tokenConfigs[1] = TopUpFactory.TokenConfig({ bridgeAdapter: address(oftBridgeAdapter), recipientOnDestChain: alice, maxSlippageInBps: maxSlippage, additionalData: abi.encode(weETHOftAddress) });

        vm.prank(admin);
        factory.setTokenConfig(tokens, tokenConfigs);
    }

    /// @dev Test deployment of TopUp contract
    function test_deployTopUpContract_succeeds_whenCalledByAdmin() public {
        vm.startPrank(admin);

        bytes32 salt = bytes32(uint256(1));

        vm.expectEmit(true, true, true, true);
        emit BeaconFactory.BeaconProxyDeployed(factory.getDeterministicAddress(salt));
        factory.deployTopUpContract(salt);
        vm.stopPrank();
    }

    /// @dev Test bridge initialization
    function test_deployTopUpContract_setsFactoryAsOwner() public {
        vm.prank(admin);
        bytes32 salt = bytes32(uint256(1));
        factory.deployTopUpContract(salt);

        address topUpAddr = factory.getDeterministicAddress(salt);
        TopUp topUp = TopUp(topUpAddr);

        assertEq(topUp.owner(), address(factory), "Factory should be bridge owner");
    }

    /// @dev Test non-admin cannot deploy
    function test_deployTopUpContract_reverts_whenCalledByNonAdmin() public {
        vm.prank(user);
        vm.expectRevert(TopUpFactory.OnlyAdmin.selector);
        factory.deployTopUpContract(bytes32(uint256(1)));
    }

    /// @dev Test cannot deploy with same salt
    function test_deployTopUpContract_reverts_whenSaltAlreadyUsed() public {
        vm.startPrank(admin);

        bytes32 salt = bytes32(uint256(1));
        factory.deployTopUpContract(salt);

        vm.expectRevert();
        factory.deployTopUpContract(salt);

        vm.stopPrank();
    }

    /// @dev Test recovery wallet functionality
    function test_setRecoveryWallet_succeeds() public {
        address newWallet = makeAddr("recovery");

        vm.startPrank(admin);
        vm.expectEmit(true, true, true, true);
        emit TopUpFactory.RecoveryWalletSet(address(0), newWallet);
        factory.setRecoveryWallet(newWallet);
        assertEq(factory.getRecoveryWallet(), newWallet, "Recovery wallet not set correctly");
        vm.stopPrank();
    }

    function test_setRecoveryWallet_reverts_whenCalledByNonAdmin() public {
        vm.prank(user);
        vm.expectRevert(TopUpFactory.OnlyAdmin.selector);
        factory.setRecoveryWallet(makeAddr("recovery"));
    }

    function test_setRecoveryWallet_reverts_whenZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(TopUpFactory.RecoveryWalletCannotBeZeroAddress.selector);
        factory.setRecoveryWallet(address(0));
    }

    /// @dev Test recovery functionality
    function test_recoverFunds_succeeds() public {
        address recoveryWallet = makeAddr("recovery");
        MockERC20 unsupportedToken = new MockERC20("Unsupported", "UNS");

        vm.startPrank(admin);
        factory.setRecoveryWallet(recoveryWallet);

        // Send tokens to factory
        unsupportedToken.mint(address(factory), 100);

        vm.expectEmit(true, true, true, true);
        emit TopUpFactory.Recovery(recoveryWallet, address(unsupportedToken), 100);
        factory.recoverFunds(address(unsupportedToken), 100);

        assertEq(unsupportedToken.balanceOf(recoveryWallet), 100, "Funds not recovered correctly");
        vm.stopPrank();
    }

    function test_recoverFunds_reverts_whenZeroAmount() public {
        address recoveryWallet = makeAddr("recovery");
        MockERC20 unsupportedToken = new MockERC20("Unsupported", "UNS");

        vm.startPrank(admin);
        factory.setRecoveryWallet(recoveryWallet);

        unsupportedToken.mint(address(factory), 100);
        factory.recoverFunds(address(unsupportedToken), 0);
        // Should succeed with zero amount
    }

    function test_recoverFunds_reverts_whenNoRecoveryWallet() public {
        MockERC20 unsupportedToken = new MockERC20("Unsupported", "UNS");

        vm.prank(admin);
        vm.expectRevert(TopUpFactory.RecoveryWalletNotSet.selector);
        factory.recoverFunds(address(unsupportedToken), 100);
    }

    function test_recoverFunds_reverts_whenSupportedToken() public {
        address recoveryWallet = makeAddr("recovery");

        vm.startPrank(admin);
        factory.setRecoveryWallet(recoveryWallet);

        vm.expectRevert(TopUpFactory.OnlyUnsupportedTokens.selector);
        factory.recoverFunds(address(usdc), 100);
        vm.stopPrank();
    }

    /// @dev Test getters
    function test_getDeployedAddresses_succeeds() public {
        // Deploy multiple TopUp contracts
        vm.startPrank(admin);
        for (uint256 i = 0; i < 3; i++) {
            factory.deployTopUpContract(bytes32(i));
        }
        vm.stopPrank();

        // Test getting subset of addresses
        address[] memory addresses = factory.getDeployedAddresses(1, 2);
        assertEq(addresses.length, 2, "Wrong number of addresses returned");

        // Test getting addresses with overflow
        addresses = factory.getDeployedAddresses(2, 2);
        assertEq(addresses.length, 1, "Should return only available addresses");
    }

    /// @dev Test processTopUp
    function test_processTopUp_transfersFundsToFactory() public {
        // Deploy TopUp through factory
        vm.prank(admin);
        bytes32 salt = bytes32(uint256(1));
        factory.deployTopUpContract(salt);

        // Get deployed topUp contract address
        address topUpAddr = factory.getDeterministicAddress(salt);

        // Test topUp contract functionality
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weETH);

        // Send some tokens and ETH to topUp contract
        deal(address(usdc), topUpAddr, 100);
        deal(address(weETH), topUpAddr, 1 ether);

        // Test processTopUp
        factory.processTopUp(tokens, 0, 1);

        // Verify balances
        assertEq(usdc.balanceOf(topUpAddr), 0, "TopUp contract should have 0 USDC");
        assertEq(weETH.balanceOf(topUpAddr), 0, "TopUp contract should have 0 weETH");
        assertEq(usdc.balanceOf(address(factory)), 100, "Factory should have received USDC");
        assertEq(weETH.balanceOf(address(factory)), 1 ether, "Factory should have received weETH");
    }

    /// @dev Test processTopUp with invalid inputs
    function test_processTopUpFromContracts_reverts_whenInvalidAddress() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        address[] memory topUpContracts = new address[](1);
        topUpContracts[0] = makeAddr("invalid");

        vm.expectRevert(TopUpFactory.InvalidTopUpAddress.selector);
        factory.processTopUpFromContracts(tokens, topUpContracts);
    }

    function test_processTopUpFromContracts_succeeds() public {
        // Deploy TopUp through factory
        vm.startPrank(admin);
        bytes32 salt1 = bytes32(uint256(1));
        bytes32 salt2 = bytes32(uint256(2));
        factory.deployTopUpContract(salt1);
        factory.deployTopUpContract(salt2);
        vm.stopPrank();

        // Get deployed topUp contract address
        address topUpAddr1 = factory.getDeterministicAddress(salt1);
        address topUpAddr2 = factory.getDeterministicAddress(salt2);

        // Test topUp contract functionality
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weETH);

        uint256 usdcBalTopUp1 = 100;
        uint256 usdcBalTopUp2 = 500;
        uint256 weETHBalTopUp1 = 1 ether;
        uint256 weETHBalTopUp2 = 2 ether;

        // Send some tokens and ETH to topUp contract
        deal(address(usdc), topUpAddr1, usdcBalTopUp1);
        deal(address(weETH), topUpAddr1, weETHBalTopUp1);
        deal(address(usdc), topUpAddr2, usdcBalTopUp2);
        deal(address(weETH), topUpAddr2, weETHBalTopUp2);

        address[] memory topUpContracts = new address[](2);
        topUpContracts[0] = topUpAddr1;
        topUpContracts[1] = topUpAddr2;

        // Test processTopUpFromContracts
        factory.processTopUpFromContracts(tokens, topUpContracts);

        // Verify balances
        assertEq(usdc.balanceOf(topUpAddr1), 0, "TopUp contract 1 should have 0 USDC");
        assertEq(weETH.balanceOf(topUpAddr1), 0, "TopUp contract 1 should have 0 weETH");
        assertEq(usdc.balanceOf(topUpAddr2), 0, "TopUp contract 2 should have 0 USDC");
        assertEq(weETH.balanceOf(topUpAddr2), 0, "TopUp contract 2 should have 0 weETH");
        assertEq(usdc.balanceOf(address(factory)), usdcBalTopUp1 + usdcBalTopUp2, "Factory should have received USDC");
        assertEq(weETH.balanceOf(address(factory)), weETHBalTopUp1 + weETHBalTopUp2, "Factory should have received weETH");
    }

    function test_processTopUp_reverts_whenStartTooHigh() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        vm.expectRevert(TopUpFactory.InvalidStartIndex.selector);
        factory.processTopUp(tokens, 100, 1);
    }

    /// @dev Test token configuration validation
    function test_setTokenConfig_succeeds_whenCalledByAdmin() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth); // Using a new token not configured in setup

        TopUpFactory.TokenConfig[] memory configs = new TopUpFactory.TokenConfig[](1);
        configs[0] = TopUpFactory.TokenConfig({ bridgeAdapter: address(oftBridgeAdapter), recipientOnDestChain: alice, maxSlippageInBps: maxSlippage, additionalData: abi.encode(weETHOftAddress) });

        vm.prank(admin);
        factory.setTokenConfig(tokens, configs);

        assertTrue(factory.isTokenSupported(address(weth)), "Token should be supported after config");
        TopUpFactory.TokenConfig memory config = factory.getTokenConfig(address(weth));
        assertEq(config.bridgeAdapter, address(oftBridgeAdapter), "Bridge adapter not set correctly");
        assertEq(config.recipientOnDestChain, alice, "Recipient not set correctly");
        assertEq(config.maxSlippageInBps, maxSlippage, "Slippage not set correctly");
    }

    function test_setTokenConfig_reverts_whenCalledByNonAdmin() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weETH);

        TopUpFactory.TokenConfig[] memory configs = new TopUpFactory.TokenConfig[](1);
        configs[0] = TopUpFactory.TokenConfig({ bridgeAdapter: address(oftBridgeAdapter), recipientOnDestChain: alice, maxSlippageInBps: maxSlippage, additionalData: abi.encode(weETHOftAddress) });

        vm.prank(user);
        vm.expectRevert(TopUpFactory.OnlyAdmin.selector);
        factory.setTokenConfig(tokens, configs);
    }

    function test_setTokenConfig_reverts_whenInvalidSlippage() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weETH);

        TopUpFactory.TokenConfig[] memory configs = new TopUpFactory.TokenConfig[](1);
        configs[0] = TopUpFactory.TokenConfig({
            bridgeAdapter: address(oftBridgeAdapter),
            recipientOnDestChain: alice,
            maxSlippageInBps: 201, // MAX_ALLOWED_SLIPPAGE is 200
            additionalData: abi.encode(weETHOftAddress)
        });

        vm.prank(admin);
        vm.expectRevert(TopUpFactory.InvalidConfig.selector);
        factory.setTokenConfig(tokens, configs);
    }

    function test_setTokenConfig_reverts_whenZeroBridgeAdapter() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weETH);

        TopUpFactory.TokenConfig[] memory configs = new TopUpFactory.TokenConfig[](1);
        configs[0] = TopUpFactory.TokenConfig({ bridgeAdapter: address(0), recipientOnDestChain: alice, maxSlippageInBps: maxSlippage, additionalData: abi.encode(weETHOftAddress) });

        vm.prank(admin);
        vm.expectRevert(TopUpFactory.InvalidConfig.selector);
        factory.setTokenConfig(tokens, configs);
    }

    function test_setTokenConfig_reverts_whenZeroRecipient() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weETH);

        TopUpFactory.TokenConfig[] memory configs = new TopUpFactory.TokenConfig[](1);
        configs[0] = TopUpFactory.TokenConfig({ bridgeAdapter: address(oftBridgeAdapter), recipientOnDestChain: address(0), maxSlippageInBps: maxSlippage, additionalData: abi.encode(weETHOftAddress) });

        vm.prank(admin);
        vm.expectRevert(TopUpFactory.InvalidConfig.selector);
        factory.setTokenConfig(tokens, configs);
    }

    /// @dev Test bridging functionality
    function test_bridge_reverts_whenZeroBalance() public {
        vm.expectRevert(TopUpFactory.ZeroBalance.selector);
        factory.bridge(address(weETH));
    }

    function test_bridge_reverts_whenUnsupportedToken() public {
        MockERC20 unsupportedToken = new MockERC20("Unsupported", "UNS");
        vm.expectRevert(TopUpFactory.TokenConfigNotSet.selector);
        factory.bridge(address(unsupportedToken));
    }

    function test_getBridgeFee_reverts_whenZeroBalance() public {
        vm.expectRevert(TopUpFactory.ZeroBalance.selector);
        factory.getBridgeFee(address(weETH));
    }

    function test_getBridgeFee_reverts_whenUnsupportedToken() public {
        MockERC20 unsupportedToken = new MockERC20("Unsupported", "UNS");
        vm.expectRevert(TopUpFactory.TokenConfigNotSet.selector);
        factory.getBridgeFee(address(unsupportedToken));
    }

    /// @dev Test token support checks
    function test_isTokenSupported_returnsCorrectValue() public {
        assertTrue(factory.isTokenSupported(address(weETH)), "weETH should be supported");
        assertTrue(factory.isTokenSupported(address(usdc)), "USDC should be supported");

        MockERC20 unsupportedToken = new MockERC20("Unsupported", "UNS");
        assertFalse(factory.isTokenSupported(address(unsupportedToken)), "Unsupported token should return false");
    }

    /// @dev Test token config getters
    function test_getTokenConfig_returnsCorrectConfig() public view {
        TopUpFactory.TokenConfig memory config = factory.getTokenConfig(address(weETH));

        assertEq(config.bridgeAdapter, address(oftBridgeAdapter), "Wrong bridge adapter");
        assertEq(config.recipientOnDestChain, alice, "Wrong recipient");
        assertEq(config.maxSlippageInBps, maxSlippage, "Wrong slippage");
        assertEq(abi.decode(config.additionalData, (address)), weETHOftAddress, "Wrong additional data");
    }

    function test_bridge_succeeds_withUsdc() public {
        address token = address(usdc);
        uint256 amount = 100e6;
        deal(token, address(factory), amount);
        (, uint256 fee) = factory.getBridgeFee(token);

        vm.expectEmit(true, true, true, true);
        emit TopUpFactory.Bridge(token, amount);
        factory.bridge{ value: fee }(token);
    }

    function test_bridge_succeeds_withWeEth() public {
        address token = address(weETH);
        uint256 amount = 1 ether;
        deal(token, address(factory), amount);
        (, uint256 fee) = factory.getBridgeFee(token);

        vm.expectEmit(true, true, true, true);
        emit TopUpFactory.Bridge(token, amount);
        factory.bridge{ value: fee }(token);
    }

    function test_bridge_fails_withInsufficientNativeFee() public {
        address token = address(usdc);
        uint256 amount = 100e6;
        deal(token, address(factory), amount);
        (, uint256 fee) = factory.getBridgeFee(token);

        vm.expectRevert();
        factory.bridge{ value: fee - 1 }(token);
    }

    /// @dev Test bridging when paused
    function test_bridge_reverts_whenPaused() public {
        address token = address(usdc);
        uint256 amount = 100e6;
        deal(token, address(factory), amount);
        (, uint256 fee) = factory.getBridgeFee(token);

        vm.prank(pauser);
        factory.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.bridge{ value: fee }(token);
    }

    /// @dev Test pausing functionality
    function test_pause_succeeds() public {
        vm.prank(pauser);
        factory.pause();

        // Try to bridge tokens while paused
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.bridge(address(usdc));
    }

    function test_unpause_succeeds() public {
        vm.prank(pauser);
        factory.pause();
        vm.prank(unpauser);
        factory.unpause();

        assertTrue(!factory.paused(), "Contract should be unpaused");
    }

    function test_pause_reverts_whenCalledByNonPauser() public {
        vm.prank(user);
        vm.expectRevert(RoleRegistry.OnlyPauser.selector);
        factory.pause();
    }

    function test_unpause_reverts_whenCalledByNonUnpauser() public {
        vm.prank(pauser);
        factory.pause();

        vm.prank(user);
        vm.expectRevert(RoleRegistry.OnlyUnpauser.selector);
        factory.unpause();
    }
}
