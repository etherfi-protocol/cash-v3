// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { ITradingSafeFactory } from "../../src/interfaces/ITradingSafeFactory.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUp } from "../../src/top-up/TopUp.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";

/// @dev Tests for the COR-733 redirect-to-trading-safe path. Exercises both layers:
///      TopUp.setSourceSafe / redirectToTradingSafe (owner-gated) and the public-facing
///      TopUpFactory.bindSourceSafe / redirectToTradingSafe entry points.
contract TopUpRedirectToTradingSafeTest is Test {
    TopUpFactory public factory;
    TopUp public implementation;
    TopUp public topUp;
    RoleRegistry public roleRegistry;
    MockERC20 public token;

    address public owner = makeAddr("owner");
    address public pauser = makeAddr("pauser");
    address public unpauser = makeAddr("unpauser");
    address public stranger = makeAddr("stranger");
    address public weth = makeAddr("weth");
    address public dataProvider = makeAddr("dataProvider");
    address public tradingSafeFactoryAddr = makeAddr("tradingSafeFactory");
    address public derivedTradingSafe = makeAddr("derivedTradingSafe");

    function setUp() public {
        vm.startPrank(owner);

        // Role registry
        address roleRegistryImpl = address(new RoleRegistry(dataProvider));
        roleRegistry = RoleRegistry(address(new UUPSProxy(
            roleRegistryImpl,
            abi.encodeWithSelector(RoleRegistry.initialize.selector, owner)
        )));
        roleRegistry.grantRole(roleRegistry.PAUSER(), pauser);
        roleRegistry.grantRole(roleRegistry.UNPAUSER(), unpauser);

        // TopUp impl + factory proxy
        implementation = new TopUp(weth);
        address factoryImpl = address(new TopUpFactory());
        factory = TopUpFactory(payable(address(new UUPSProxy(
            factoryImpl,
            abi.encodeWithSelector(TopUpFactory.initialize.selector, address(roleRegistry), address(implementation))
        ))));

        // Deploy a per-user TopUp via the factory.
        factory.deployTopUpContract(keccak256("user-salt-1"));
        address[] memory deployed = factory.getDeployedAddresses(0, 1);
        topUp = TopUp(payable(deployed[0]));

        factory.setTradingSafeFactory(tradingSafeFactoryAddr);

        vm.stopPrank();

        // Mock the TradingSafeFactory deterministic-derivation: salt seed is the TopUp's
        // own address.
        vm.mockCall(
            tradingSafeFactoryAddr,
            abi.encodeWithSelector(ITradingSafeFactory.getDeterministicAddress.selector, address(topUp)),
            abi.encode(derivedTradingSafe)
        );

        // Fund the TopUp with a misrouted token.
        token = new MockERC20("Misrouted", "MIS", 18);
        token.mint(address(topUp), 1_000e18);
    }

    // ---- Happy path ----

    function test_redirectToTradingSafe_transfersToDerivedAddress() public {
        uint256 amount = 250e18;
        uint256 beforeTopUp = token.balanceOf(address(topUp));
        uint256 beforeTradingSafe = token.balanceOf(derivedTradingSafe);

        vm.expectEmit(true, true, false, true, address(topUp));
        emit TopUp.RedirectedToTradingSafe(address(token), derivedTradingSafe, amount);
        vm.expectEmit(true, true, false, true, address(factory));
        emit TopUpFactory.RedirectToTradingSafe(address(topUp), address(token), amount);

        vm.prank(stranger);
        factory.redirectToTradingSafe(address(topUp), address(token), amount);

        assertEq(token.balanceOf(address(topUp)), beforeTopUp - amount, "topUp not debited");
        assertEq(token.balanceOf(derivedTradingSafe), beforeTradingSafe + amount, "tradingSafe not credited");
    }

    function test_redirectToTradingSafe_transfersEvenWhenTradingSafeNotYetDeployed() public {
        // The mock returns a deterministic address with no code; the transfer should still
        // succeed because ERC20 transfers don't require the recipient to exist.
        assertEq(derivedTradingSafe.code.length, 0, "precondition: no code at derived address");

        vm.prank(stranger);
        factory.redirectToTradingSafe(address(topUp), address(token), 100e18);

        assertEq(token.balanceOf(derivedTradingSafe), 100e18);
    }

    // ---- Factory entry-point role gating ----

    function test_factoryRedirect_anyCallerCanTrigger() public {
        // Permissionless: a random address can fire the redirect. Destination is forced to
        // the user's own TradingSafe by deterministic derivation, so there's no harm.
        vm.prank(stranger);
        factory.redirectToTradingSafe(address(topUp), address(token), 100e18);
        assertEq(token.balanceOf(derivedTradingSafe), 100e18);
    }

    function test_factoryRedirect_revertsForUnknownTopUp() public {
        address fakeTopUp = makeAddr("fakeTopUp");
        vm.prank(stranger);
        vm.expectRevert(TopUpFactory.InvalidTopUpAddress.selector);
        factory.redirectToTradingSafe(fakeTopUp, address(token), 100e18);
    }

    function test_factoryRedirect_revertsWhenPaused() public {
        vm.prank(pauser);
        factory.pause();
        vm.prank(stranger);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.redirectToTradingSafe(address(topUp), address(token), 100e18);
    }

    // ---- TopUp-level guard rails (reached via the factory) ----

    function test_topUp_revertsWhenTradingSafeFactoryNotSet() public {
        // Spin up an entirely new factory without ever calling setTradingSafeFactory.
        vm.startPrank(owner);
        address factoryImpl = address(new TopUpFactory());
        TopUpFactory bareFactory = TopUpFactory(payable(address(new UUPSProxy(
            factoryImpl,
            abi.encodeWithSelector(TopUpFactory.initialize.selector, address(roleRegistry), address(implementation))
        ))));
        bareFactory.deployTopUpContract(keccak256("bare"));
        address bareTopUp = bareFactory.getDeployedAddresses(0, 1)[0];
        vm.stopPrank();

        token.mint(bareTopUp, 100e18);

        vm.prank(stranger);
        vm.expectRevert(TopUpFactory.TradingSafeFactoryNotSet.selector);
        bareFactory.redirectToTradingSafe(bareTopUp, address(token), 50e18);
    }

    function test_topUp_revertsOnZeroAmount() public {
        vm.prank(stranger);
        vm.expectRevert(TopUp.InvalidAmount.selector);
        factory.redirectToTradingSafe(address(topUp), address(token), 0);
    }

    function test_topUp_directCall_revertsForNonOwner() public {
        // The TopUp's owner is the factory; calling redirectToTradingSafe directly from
        // anywhere else must revert OnlyOwner.
        vm.prank(stranger);
        vm.expectRevert(TopUp.OnlyOwner.selector);
        topUp.redirectToTradingSafe(address(token), 100e18);
    }

    // ---- batchRedirectToTradingSafe ----

    function test_batchRedirect_sameTopUpMultipleTokens() public {
        MockERC20 second = new MockERC20("Other", "OTH", 18);
        second.mint(address(topUp), 500e18);

        address[] memory topUps = new address[](2);
        topUps[0] = address(topUp);
        topUps[1] = address(topUp);
        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(second);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 250e18;

        vm.prank(stranger);
        factory.batchRedirectToTradingSafe(topUps, tokens, amounts);

        assertEq(token.balanceOf(derivedTradingSafe), 100e18);
        assertEq(second.balanceOf(derivedTradingSafe), 250e18);
    }

    function test_batchRedirect_acrossMultipleTopUps() public {
        // Spin up a second TopUp + funds + mock its derived TradingSafe.
        vm.prank(owner);
        factory.deployTopUpContract(keccak256("batch-2"));
        address secondTopUp = factory.getDeployedAddresses(0, 2)[1];
        token.mint(secondTopUp, 300e18);
        address secondDerived = makeAddr("secondDerived");
        vm.mockCall(
            tradingSafeFactoryAddr,
            abi.encodeWithSelector(ITradingSafeFactory.getDeterministicAddress.selector, secondTopUp),
            abi.encode(secondDerived)
        );

        address[] memory topUps = new address[](2);
        topUps[0] = address(topUp);
        topUps[1] = secondTopUp;
        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(token);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 200e18;

        vm.prank(stranger);
        factory.batchRedirectToTradingSafe(topUps, tokens, amounts);

        assertEq(token.balanceOf(derivedTradingSafe), 100e18);
        assertEq(token.balanceOf(secondDerived), 200e18);
    }

    function test_batchRedirect_revertsOnLengthMismatch() public {
        address[] memory topUps = new address[](2);
        topUps[0] = address(topUp);
        topUps[1] = address(topUp);
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 2;

        vm.prank(stranger);
        vm.expectRevert(TopUpFactory.ArrayLengthMismatch.selector);
        factory.batchRedirectToTradingSafe(topUps, tokens, amounts);
    }

    function test_batchRedirect_revertsForUnknownTopUp() public {
        address fakeTopUp = makeAddr("fakeTopUp");
        address[] memory topUps = new address[](2);
        topUps[0] = address(topUp);
        topUps[1] = fakeTopUp;
        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(token);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 1;

        vm.prank(stranger);
        vm.expectRevert(TopUpFactory.InvalidTopUpAddress.selector);
        factory.batchRedirectToTradingSafe(topUps, tokens, amounts);
    }

    function test_batchRedirect_anyCallerCanTrigger() public {
        address[] memory topUps = new address[](1);
        topUps[0] = address(topUp);
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.prank(stranger);
        factory.batchRedirectToTradingSafe(topUps, tokens, amounts);
        assertEq(token.balanceOf(derivedTradingSafe), 100e18);
    }

    function test_batchRedirect_revertsWhenPaused() public {
        vm.prank(pauser);
        factory.pause();

        address[] memory topUps = new address[](1);
        topUps[0] = address(topUp);
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.prank(stranger);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.batchRedirectToTradingSafe(topUps, tokens, amounts);
    }

    function test_batchRedirect_emptyArrays_isNoOp() public {
        address[] memory topUps = new address[](0);
        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        uint256 balBefore = token.balanceOf(derivedTradingSafe);
        vm.prank(stranger);
        factory.batchRedirectToTradingSafe(topUps, tokens, amounts);
        assertEq(token.balanceOf(derivedTradingSafe), balBefore, "no transfer should happen");
    }

    function test_batchRedirect_atomicAllOrNothing() public {
        // First entry valid, second invalid → entire tx reverts; first transfer is rolled
        // back.
        uint256 balBefore = token.balanceOf(derivedTradingSafe);

        address[] memory topUps = new address[](2);
        topUps[0] = address(topUp);
        topUps[1] = makeAddr("nonexistent");
        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(token);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 1;

        vm.prank(stranger);
        vm.expectRevert(TopUpFactory.InvalidTopUpAddress.selector);
        factory.batchRedirectToTradingSafe(topUps, tokens, amounts);

        assertEq(token.balanceOf(derivedTradingSafe), balBefore, "first transfer must roll back");
    }

    // ---- supported-token guard ----

    function test_redirect_revertsForTopupSupportedToken() public {
        // Make `token` topup-supported via setTokenConfig.
        _markTokenSupported(address(token));

        vm.prank(stranger);
        vm.expectRevert(TopUpFactory.OnlyUnsupportedTokens.selector);
        factory.redirectToTradingSafe(address(topUp), address(token), 100e18);
    }

    function test_batchRedirect_revertsIfAnyEntryIsSupportedToken() public {
        MockERC20 supported = new MockERC20("Supported", "SUP", 18);
        supported.mint(address(topUp), 100e18);
        _markTokenSupported(address(supported));

        address[] memory topUps = new address[](2);
        topUps[0] = address(topUp);
        topUps[1] = address(topUp);
        address[] memory tokens = new address[](2);
        tokens[0] = address(token); // unsupported, fine
        tokens[1] = address(supported); // supported → must revert
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 1;

        vm.prank(stranger);
        vm.expectRevert(TopUpFactory.OnlyUnsupportedTokens.selector);
        factory.batchRedirectToTradingSafe(topUps, tokens, amounts);
    }

    /// @dev Helper: register `token` as topup-supported by setting a dummy TokenConfig.
    function _markTokenSupported(address _token) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = _token;
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = 10;
        TopUpFactory.TokenConfig[] memory configs = new TopUpFactory.TokenConfig[](1);
        configs[0] = TopUpFactory.TokenConfig({
            bridgeAdapter: makeAddr("bridgeAdapter"),
            recipientOnDestChain: makeAddr("recipient"),
            maxSlippageInBps: 50,
            additionalData: ""
        });
        vm.prank(owner);
        factory.setTokenConfig(tokens, chainIds, configs);
    }

    // ---- redirectDestinationFor ----

    function test_redirectDestinationFor_returnsDerivedAddressFromTopUpItself() public view {
        assertEq(factory.redirectDestinationFor(address(topUp)), derivedTradingSafe);
    }

    // ---- setTradingSafeFactory ----

    function test_setTradingSafeFactory_revertsForNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        factory.setTradingSafeFactory(makeAddr("other"));
    }

    function test_setTradingSafeFactory_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(TopUpFactory.TradingSafeFactoryCannotBeZeroAddress.selector);
        factory.setTradingSafeFactory(address(0));
    }

    function test_setTradingSafeFactory_emitsEventAndUpdatesView() public {
        address newAddr = makeAddr("newTradingSafeFactory");

        vm.expectEmit(false, false, false, true, address(factory));
        emit TopUpFactory.TradingSafeFactorySet(tradingSafeFactoryAddr, newAddr);
        vm.prank(owner);
        factory.setTradingSafeFactory(newAddr);

        assertEq(factory.tradingSafeFactory(), newAddr);
    }
}
