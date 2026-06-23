// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import { ITopUpFactory } from "../../src/interfaces/ITopUpFactory.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { TradingSafe } from "../../src/trading-safe/TradingSafe.sol";
import { TradingSafeFactory } from "../../src/trading-safe/TradingSafeFactory.sol";
import { TradingSafeTestBase } from "./TradingSafeTestBase.t.sol";

/// @dev Tests for the Safe → TopUp redirect path. The factory carries the backend-role
///      check, the topup-supported-asset guard, and emits the single canonical
///      `RedirectToTopUp` event; `TradingSafe.redirectToTopUp` is the factory-gated
///      transfer executor. Mirror of the TopUp → TradingSafe redirect.
contract TradingSafeRedirectToTopUpTest is TradingSafeTestBase {
    TradingSafeFactory public factory;
    TradingSafe public safe;
    MockERC20 public token;

    address public bridgeReceiver = makeAddr("bridgeReceiver");
    address public ownerA = makeAddr("ownerA");
    address public backend = makeAddr("backend");
    address public stranger = makeAddr("stranger");
    address public pauser = makeAddr("pauser");
    address public topUpFactory = makeAddr("topUpFactory");

    // The TradingSafe's TopUp destination is the sourceSafe it was derived from.
    address public sourceSafe = makeAddr("sourceSafe");

    function setUp() public {
        _setupCore();

        vm.startPrank(owner);
        factory = _deployFactory(bridgeReceiver);
        _initDataProvider(address(factory));
        roleRegistry.grantRole(factory.TRADING_SAFE_FACTORY_ADMIN_ROLE(), owner);
        roleRegistry.grantRole(factory.TRADING_SAFE_REDIRECT_ROLE(), backend);
        roleRegistry.grantRole(roleRegistry.PAUSER(), pauser);

        address[] memory initialOwners = new address[](1);
        initialOwners[0] = ownerA;
        safe = _deployTradingSafe(factory, sourceSafe, initialOwners, 1);

        factory.setTopUpFactory(topUpFactory);
        vm.stopPrank();

        // The destination TopUp == the recorded sourceSafe.
        assertEq(factory.getTopUpAddress(address(safe)), sourceSafe, "precondition: topUp == sourceSafe");

        // Mark `token` as topup-supported by default.
        token = new MockERC20("Supported", "SUP", 18);
        token.mint(address(safe), 1_000e18);
        _setTokenSupported(address(token), true);
    }

    // ---- Happy path ----

    function test_redirectToTopUp_transfersToTopUpAndEmits() public {
        uint256 amount = 250e18;
        uint256 beforeSafe = token.balanceOf(address(safe));
        uint256 beforeTopUp = token.balanceOf(sourceSafe);

        vm.expectEmit(true, true, true, true, address(factory));
        emit TradingSafeFactory.RedirectFunds(address(safe), sourceSafe, address(token), amount);

        vm.prank(backend);
        factory.redirectToTopUp(address(safe), address(token), amount);

        assertEq(token.balanceOf(address(safe)), beforeSafe - amount, "safe not debited");
        assertEq(token.balanceOf(sourceSafe), beforeTopUp + amount, "topUp not credited");
    }

    // ---- Factory entry-point validation ----

    function test_redirectToTopUp_revertsForNonRole() public {
        vm.prank(stranger);
        vm.expectRevert(TradingSafeFactory.OnlyRedirectRole.selector);
        factory.redirectToTopUp(address(safe), address(token), 100e18);
    }

    function test_redirectToTopUp_revertsOnZeroAmount() public {
        vm.prank(backend);
        vm.expectRevert(TradingSafeFactory.InvalidAmount.selector);
        factory.redirectToTopUp(address(safe), address(token), 0);
    }

    function test_redirectToTopUp_revertsForUnknownSafe() public {
        vm.prank(backend);
        vm.expectRevert(TradingSafeFactory.InvalidTradingSafe.selector);
        factory.redirectToTopUp(makeAddr("notASafe"), address(token), 100e18);
    }

    function test_redirectToTopUp_revertsForUnsupportedToken() public {
        _setTokenSupported(address(token), false);
        vm.prank(backend);
        vm.expectRevert(TradingSafeFactory.UnsupportedTopUpAsset.selector);
        factory.redirectToTopUp(address(safe), address(token), 100e18);
    }

    function test_redirectToTopUp_revertsWhenTopUpFactoryNotSet() public {
        // Build an independent stack that never configures a TopUpFactory. The guard is
        // checked after the safe-existence check, so the safe must be a registered one.
        _setupCore();
        vm.startPrank(owner);
        TradingSafeFactory bareFactory = _deployFactory(bridgeReceiver);
        _initDataProvider(address(bareFactory));
        roleRegistry.grantRole(bareFactory.TRADING_SAFE_FACTORY_ADMIN_ROLE(), owner);
        roleRegistry.grantRole(bareFactory.TRADING_SAFE_REDIRECT_ROLE(), backend);
        address[] memory owners = new address[](1);
        owners[0] = ownerA;
        TradingSafe bareSafe = _deployTradingSafe(bareFactory, sourceSafe, owners, 1);
        vm.stopPrank();

        assertEq(bareFactory.topUpFactory(), address(0), "precondition: no topUpFactory");

        vm.prank(backend);
        vm.expectRevert(TradingSafeFactory.TopUpFactoryNotSet.selector);
        bareFactory.redirectToTopUp(address(bareSafe), address(token), 100e18);
    }

    function test_redirectToTopUp_revertsWhenPaused() public {
        vm.prank(pauser);
        factory.pause();
        vm.prank(backend);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.redirectToTopUp(address(safe), address(token), 100e18);
    }

    // ---- TradingSafe-level guard ----

    function test_safeRedirectToTopUp_revertsForNonFactory() public {
        vm.prank(stranger);
        vm.expectRevert(TradingSafe.OnlyTradingSafeFactory.selector);
        safe.redirectToTopUp(address(token), sourceSafe, 100e18);
    }

    // ---- setTopUpFactory ----

    function test_setTopUpFactory_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        factory.setTopUpFactory(makeAddr("other"));
    }

    function test_setTopUpFactory_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(TradingSafeFactory.TopUpFactoryCannotBeZeroAddress.selector);
        factory.setTopUpFactory(address(0));
    }

    function test_setTopUpFactory_emitsEventAndUpdatesView() public {
        address newAddr = makeAddr("newTopUpFactory");
        vm.expectEmit(false, false, false, true, address(factory));
        emit TradingSafeFactory.TopUpFactorySet(topUpFactory, newAddr);
        vm.prank(owner);
        factory.setTopUpFactory(newAddr);
        assertEq(factory.topUpFactory(), newAddr);
    }

    /// @dev Mock the configured TopUpFactory's `isTokenSupported` for `_token`.
    function _setTokenSupported(address _token, bool supported) internal {
        vm.mockCall(
            topUpFactory,
            abi.encodeWithSelector(ITopUpFactory.isTokenSupported.selector, _token),
            abi.encode(supported)
        );
    }
}
