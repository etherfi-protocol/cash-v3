// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUp } from "../../src/top-up/TopUp.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { MockWrappedToken, NoOpDepositVault } from "./TopUpRedirectToTradingSafe.t.sol";

/// @dev Tests for `TopUpFactory.wrapStocks` — the in-place wrap of a raw Backed xStock sitting at
///      a TopUp into the ERC-4626 wrapper registered for it. Nothing leaves the TopUp: it is the
///      recipient of the shares, which is what separates this from the redirect path and why the
///      entry point needs no role and no TradingSafeFactory.
contract TopUpWrapStocksTest is Test {
    TopUpFactory public factory;
    TopUp public implementation;
    TopUp public topUp;
    RoleRegistry public roleRegistry;
    MockERC20 public stock;

    address public owner = makeAddr("owner");
    address public pauser = makeAddr("pauser");
    address public unpauser = makeAddr("unpauser");
    address public stranger = makeAddr("stranger");
    address public weth = makeAddr("weth");
    address public dataProvider = makeAddr("dataProvider");

    function setUp() public {
        vm.startPrank(owner);

        address roleRegistryImpl = address(new RoleRegistry(dataProvider));
        roleRegistry = RoleRegistry(address(new UUPSProxy(
            roleRegistryImpl,
            abi.encodeWithSelector(RoleRegistry.initialize.selector, owner)
        )));
        roleRegistry.grantRole(roleRegistry.PAUSER(), pauser);
        roleRegistry.grantRole(roleRegistry.UNPAUSER(), unpauser);

        implementation = new TopUp(weth);
        address factoryImpl = address(new TopUpFactory());
        factory = TopUpFactory(payable(address(new UUPSProxy(
            factoryImpl,
            abi.encodeWithSelector(TopUpFactory.initialize.selector, address(roleRegistry), address(implementation))
        ))));

        factory.deployTopUpContract(keccak256("wrap-user-1"));
        topUp = TopUp(payable(factory.getDeployedAddresses(0, 1)[0]));

        vm.stopPrank();

        // A raw xStock the user sent to their TopUp address: trading-supported in no form of its
        // own, topup-supported in none either, so it sits there until it is wrapped.
        stock = new MockERC20("Tesla xStock", "TSLAx", 18);
        stock.mint(address(topUp), 1_000e18);
    }

    // ---- Happy path ----

    function test_wrapStocks_wrapsWholeBalanceInPlace() public {
        MockWrappedToken wrapper = _registerWrapper(stock);

        vm.expectEmit(true, true, true, true, address(factory));
        emit TopUpFactory.WrapStock(address(topUp), address(wrapper), address(stock), 1_000e18, 1_000e18);

        vm.prank(stranger);
        factory.wrapStocks(address(topUp), _arr(address(stock)));

        assertEq(stock.balanceOf(address(topUp)), 0, "raw stock left behind");
        assertEq(wrapper.balanceOf(address(topUp)), 1_000e18, "TopUp not credited with shares");
        assertEq(wrapper.balanceOf(address(factory)), 0, "shares must not reach the factory");
        assertEq(stock.allowance(address(topUp), address(wrapper)), 0, "standing approval left behind");
    }

    function test_wrapStocks_isPermissionless() public {
        _registerWrapper(stock);
        address anyone = makeAddr("anyone");

        // No role of any kind, and nothing gained: the shares land at the TopUp either way.
        assertFalse(roleRegistry.hasRole(factory.TOPUP_FACTORY_REDIRECT_ROLE(), anyone));
        assertFalse(roleRegistry.hasRole(factory.TOPUP_FACTORY_BRIDGER_ROLE(), anyone));

        vm.prank(anyone);
        factory.wrapStocks(address(topUp), _arr(address(stock)));

        assertEq(stock.balanceOf(address(topUp)), 0, "wrap did not happen for an unprivileged caller");
    }

    function test_wrapStocks_worksWithoutTradingSafeFactory() public {
        // The wrap has no trading leg, so a factory that has never had `setTradingSafeFactory`
        // called on it must still be able to run it.
        vm.startPrank(owner);
        address factoryImpl = address(new TopUpFactory());
        TopUpFactory bareFactory = TopUpFactory(payable(address(new UUPSProxy(
            factoryImpl,
            abi.encodeWithSelector(TopUpFactory.initialize.selector, address(roleRegistry), address(implementation))
        ))));
        bareFactory.deployTopUpContract(keccak256("bare"));
        address bareTopUp = bareFactory.getDeployedAddresses(0, 1)[0];
        vm.stopPrank();

        stock.mint(bareTopUp, 400e18);
        MockWrappedToken wrapper = new MockWrappedToken(IERC20(address(stock)));
        vm.prank(owner);
        _setRedirectWrapper(bareFactory, address(stock), address(wrapper));

        assertEq(bareFactory.tradingSafeFactory(), address(0), "precondition: no TradingSafeFactory");

        vm.prank(stranger);
        bareFactory.wrapStocks(bareTopUp, _arr(address(stock)));

        assertEq(wrapper.balanceOf(bareTopUp), 400e18, "wrap needs the TradingSafeFactory it shouldn't");
    }

    function test_wrapStocks_multipleTokens() public {
        MockWrappedToken wrapperA = _registerWrapper(stock);

        MockERC20 second = new MockERC20("Nvidia xStock", "NVDAx", 18);
        second.mint(address(topUp), 250e18);
        MockWrappedToken wrapperB = _registerWrapper(second);

        address[] memory tokens = new address[](2);
        tokens[0] = address(stock);
        tokens[1] = address(second);

        vm.prank(stranger);
        factory.wrapStocks(address(topUp), tokens);

        assertEq(wrapperA.balanceOf(address(topUp)), 1_000e18);
        assertEq(wrapperB.balanceOf(address(topUp)), 250e18);
        assertEq(stock.balanceOf(address(topUp)), 0);
        assertEq(second.balanceOf(address(topUp)), 0);
    }

    function test_wrapStocks_honoursVaultRate() public {
        MockWrappedToken wrapper = _registerWrapper(stock);
        wrapper.setRate(2e18); // one share costs two assets

        vm.expectEmit(true, true, true, true, address(factory));
        emit TopUpFactory.WrapStock(address(topUp), address(wrapper), address(stock), 1_000e18, 500e18);

        vm.prank(stranger);
        factory.wrapStocks(address(topUp), _arr(address(stock)));

        assertEq(wrapper.balanceOf(address(topUp)), 500e18, "shares must be what the vault minted");
    }

    function test_wrapStocks_skipsZeroBalanceEntries() public {
        MockWrappedToken wrapperA = _registerWrapper(stock);

        // Registered, but this user never received any of it — the caller can pass a whole stock
        // list without knowing which ones actually arrived.
        MockERC20 unheld = new MockERC20("Apple xStock", "AAPLx", 18);
        MockWrappedToken wrapperB = _registerWrapper(unheld);

        address[] memory tokens = new address[](2);
        tokens[0] = address(unheld);
        tokens[1] = address(stock);

        vm.prank(stranger);
        factory.wrapStocks(address(topUp), tokens);

        assertEq(wrapperB.totalSupply(), 0, "zero-balance entry minted shares");
        assertEq(wrapperA.balanceOf(address(topUp)), 1_000e18, "held stock not wrapped alongside it");
    }

    function test_wrapStocks_emptyArrayIsNoOp() public {
        _registerWrapper(stock);

        vm.prank(stranger);
        factory.wrapStocks(address(topUp), new address[](0));

        assertEq(stock.balanceOf(address(topUp)), 1_000e18, "no-op call moved funds");
    }

    // ---- Guard rails ----

    function test_wrapStocks_revertsForUnknownTopUp() public {
        _registerWrapper(stock);

        vm.prank(stranger);
        vm.expectRevert(TopUpFactory.InvalidTopUpAddress.selector);
        factory.wrapStocks(makeAddr("fakeTopUp"), _arr(address(stock)));
    }

    function test_wrapStocks_revertsWhenWrapperNotRegistered() public {
        // No `setRedirectWrappers` entry → nothing to deposit into. Loud, because it means the
        // listing is half-configured.
        vm.prank(stranger);
        vm.expectRevert(TopUpFactory.RedirectWrapperNotSet.selector);
        factory.wrapStocks(address(topUp), _arr(address(stock)));
    }

    function test_wrapStocks_revertsForTopupSupportedToken() public {
        _registerWrapper(stock);
        _markTokenSupported(address(stock));

        vm.prank(stranger);
        vm.expectRevert(TopUpFactory.OnlyUnsupportedTokens.selector);
        factory.wrapStocks(address(topUp), _arr(address(stock)));
    }

    function test_wrapStocks_revertsWhenPaused() public {
        _registerWrapper(stock);

        vm.prank(pauser);
        factory.pause();

        vm.prank(stranger);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.wrapStocks(address(topUp), _arr(address(stock)));
    }

    function test_wrapStocks_revertsWhenVaultMintsNothing() public {
        // Shares are the TopUp's own balance delta, so a vault that takes the assets and mints
        // nothing can't pass for a wrap.
        NoOpDepositVault vault = new NoOpDepositVault(address(stock));
        vm.prank(owner);
        _setRedirectWrapper(factory, address(stock), address(vault));

        vm.prank(stranger);
        vm.expectRevert(TopUpFactory.WrapMintedNothing.selector);
        factory.wrapStocks(address(topUp), _arr(address(stock)));

        assertEq(stock.balanceOf(address(topUp)), 1_000e18, "assets must be rolled back");
    }

    function test_wrapStocks_isAtomicAcrossEntries() public {
        MockWrappedToken wrapper = _registerWrapper(stock);

        MockERC20 unregistered = new MockERC20("Meta xStock", "METAx", 18);
        unregistered.mint(address(topUp), 100e18);

        address[] memory tokens = new address[](2);
        tokens[0] = address(stock); // would wrap fine
        tokens[1] = address(unregistered); // no wrapper → whole call reverts

        vm.prank(stranger);
        vm.expectRevert(TopUpFactory.RedirectWrapperNotSet.selector);
        factory.wrapStocks(address(topUp), tokens);

        assertEq(wrapper.balanceOf(address(topUp)), 0, "first wrap must roll back");
        assertEq(stock.balanceOf(address(topUp)), 1_000e18, "first wrap must roll back");
    }

    // ---- TopUp.wrap directly ----

    function test_topUpWrap_revertsForNonOwner() public {
        _registerWrapper(stock);

        // The TopUp's owner is the factory; the wrap is reachable from nowhere else.
        vm.prank(stranger);
        vm.expectRevert(TopUp.OnlyOwner.selector);
        topUp.wrap(address(stock), 100e18);
    }

    function test_topUpWrap_revertsOnZeroAmount() public {
        _registerWrapper(stock);

        vm.prank(address(factory));
        vm.expectRevert(TopUp.InvalidAmount.selector);
        topUp.wrap(address(stock), 0);
    }

    function test_topUpWrap_revertsWhenWrapperNotSet() public {
        // The factory guards this too, so reach the TopUp's own check by calling as the factory.
        vm.prank(address(factory));
        vm.expectRevert(TopUp.WrapperNotSet.selector);
        topUp.wrap(address(stock), 100e18);
    }

    function test_topUpWrap_creditsItselfOnly() public {
        // No recipient parameter exists, so even the owner cannot route the shares elsewhere.
        MockWrappedToken wrapper = _registerWrapper(stock);

        vm.prank(address(factory));
        topUp.wrap(address(stock), 400e18);

        assertEq(wrapper.balanceOf(address(topUp)), 400e18);
        assertEq(stock.balanceOf(address(topUp)), 600e18, "only the requested amount is wrapped");
        assertEq(stock.allowance(address(topUp), address(wrapper)), 0, "standing approval left behind");
    }

    // ---- What the wrap is for ----

    function test_wrapStocks_handsTheStockBackToTheSweepRail() public {
        // The raw stock can't be swept (`OnlySupportedTokens`); once wrapped, the form the topup
        // catalog does list can be, which is the whole point of converting in place.
        MockWrappedToken wrapper = _registerWrapper(stock);
        _markTokenSupported(address(wrapper));

        address[] memory topUpContracts = new address[](1);
        topUpContracts[0] = address(topUp);

        vm.prank(stranger);
        vm.expectRevert(TopUpFactory.OnlySupportedTokens.selector);
        factory.processTopUpFromContracts(_arr(address(stock)), topUpContracts);

        vm.prank(stranger);
        factory.wrapStocks(address(topUp), _arr(address(stock)));

        vm.prank(stranger);
        factory.processTopUpFromContracts(_arr(address(wrapper)), topUpContracts);

        assertEq(wrapper.balanceOf(address(factory)), 1_000e18, "wrapped stock not sweepable");
        assertEq(wrapper.balanceOf(address(topUp)), 0);
    }

    // ---- Helpers ----

    function _arr(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _registerWrapper(MockERC20 _token) internal returns (MockWrappedToken wrapper) {
        wrapper = new MockWrappedToken(IERC20(address(_token)));
        vm.prank(owner);
        _setRedirectWrapper(factory, address(_token), address(wrapper));
    }

    function _setRedirectWrapper(TopUpFactory _factory, address _token, address _wrapper) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = _token;
        address[] memory wrappers = new address[](1);
        wrappers[0] = _wrapper;
        _factory.setRedirectWrappers(tokens, wrappers);
    }

    /// @dev Registers `_token` as topup-supported by giving it a dummy bridge config.
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
}
