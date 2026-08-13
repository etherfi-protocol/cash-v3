// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { ITradingSafeFactory } from "../../src/interfaces/ITradingSafeFactory.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUp } from "../../src/top-up/TopUp.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";

/// @dev Stand-in for the `WrappedBackedToken` ERC-4626 vaults the trading catalog lists (wTSLAx
///      over TSLAx): `deposit` escrows the underlying and mints shares at a rate the real vault
///      moves as the rebasing xStock underneath it accrues.
contract MockWrappedToken is ERC20 {
    IERC20 public immutable underlying;
    /// @dev Assets per 1e18 shares.
    uint256 public rate = 1e18;

    constructor(IERC20 _underlying) ERC20("Wrapped Mock", "wMOCK") { underlying = _underlying; }

    function asset() external view returns (address) {
        return address(underlying);
    }

    function setRate(uint256 newRate) external {
        rate = newRate;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        underlying.transferFrom(msg.sender, address(this), assets);
        shares = (assets * 1e18) / rate;
        _mint(receiver, shares);
    }
}

/// @dev ERC-4626-shaped vault that takes the assets and mints nothing, to prove the balance-delta
///      check catches a wrap that credited the TradingSafe nothing.
contract NoOpDepositVault {
    address public immutable asset;

    constructor(address _asset) { asset = _asset; }

    function deposit(uint256 assets, address) external returns (uint256) {
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

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
        roleRegistry.grantRole(factory.TOPUP_FACTORY_REDIRECT_ROLE(), stranger);

        vm.stopPrank();

        // Mock the TradingSafeFactory deterministic-derivation: salt seed is the TopUp's
        // own address.
        vm.mockCall(
            tradingSafeFactoryAddr,
            abi.encodeWithSelector(ITradingSafeFactory.getDeterministicAddress.selector, address(topUp)),
            abi.encode(derivedTradingSafe)
        );

        // Default every token to trading-supported (4-byte selector match = any args). Tests
        // that need an unsupported token override this with a token-specific mock.
        vm.mockCall(
            tradingSafeFactoryAddr,
            abi.encodeWithSelector(ITradingSafeFactory.isSupportedToken.selector),
            abi.encode(true)
        );

        // Default every resolved TradingSafe to deployed/registered. Tests that need an
        // undeployed destination override this.
        vm.mockCall(
            tradingSafeFactoryAddr,
            abi.encodeWithSelector(ITradingSafeFactory.isEtherFiSafe.selector),
            abi.encode(true)
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

        vm.expectEmit(true, true, true, true, address(factory));
        emit TopUpFactory.RedirectFunds(address(topUp), derivedTradingSafe, address(token), amount);

        vm.prank(stranger);
        factory.redirectToTradingSafe(address(topUp), address(token), amount);

        assertEq(token.balanceOf(address(topUp)), beforeTopUp - amount, "topUp not debited");
        assertEq(token.balanceOf(derivedTradingSafe), beforeTradingSafe + amount, "tradingSafe not credited");
    }

    function test_redirectToTradingSafe_revertsWhenTradingSafeNotDeployed() public {
        // Destination resolves but isn't a deployed/registered TradingSafe → reject rather
        // than send funds to a codeless address.
        vm.mockCall(
            tradingSafeFactoryAddr,
            abi.encodeWithSelector(ITradingSafeFactory.isEtherFiSafe.selector, derivedTradingSafe),
            abi.encode(false)
        );
        vm.prank(stranger);
        vm.expectRevert(TopUpFactory.TradingSafeNotDeployed.selector);
        factory.redirectToTradingSafe(address(topUp), address(token), 100e18);
    }

    // ---- Factory entry-point role gating ----

    function test_factoryRedirect_revertsForNonRole() public {
        vm.prank(makeAddr("nonRole"));
        vm.expectRevert(TopUpFactory.OnlyRedirectRole.selector);
        factory.redirectToTradingSafe(address(topUp), address(token), 100e18);
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
        topUp.redirectToTradingSafe(address(token), derivedTradingSafe, 100e18);
    }

    function test_redirect_revertsForNonTradingSupportedToken() public {
        // Not topup-supported (passes OnlyUnsupportedTokens) but not trading-supported.
        vm.mockCall(
            tradingSafeFactoryAddr,
            abi.encodeWithSelector(ITradingSafeFactory.isSupportedToken.selector, address(token)),
            abi.encode(false)
        );
        vm.prank(stranger);
        vm.expectRevert(TopUpFactory.TokenNotTradingSupported.selector);
        factory.redirectToTradingSafe(address(topUp), address(token), 100e18);
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

    function test_batchRedirect_revertsForNonRole() public {
        address[] memory topUps = new address[](1);
        topUps[0] = address(topUp);
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.prank(makeAddr("nonRole"));
        vm.expectRevert(TopUpFactory.OnlyRedirectRole.selector);
        factory.batchRedirectToTradingSafe(topUps, tokens, amounts);
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

    // ---- wrap on redirect: raw xStock -> ERC-4626 wrapper ----
    //
    // The call shape never changes: `token` and `amount` are still what leaves the TopUp. What a
    // registered wrapper changes is the form that lands in the safe — the trading catalog lists
    // wTSLAx, while what a user sends to a TopUp address is the TSLAx underneath it.

    function test_redirect_wrapsConfiguredTokenOnTheWayOut() public {
        MockWrappedToken wrapper = _registerWrapper();
        uint256 amount = 250e18;

        vm.expectEmit(true, true, true, true, address(factory));
        emit TopUpFactory.WrapOnRedirect(address(topUp), address(wrapper), address(token), amount, amount);
        vm.expectEmit(true, true, true, true, address(factory));
        emit TopUpFactory.RedirectFunds(address(topUp), derivedTradingSafe, address(wrapper), amount);

        vm.prank(stranger);
        factory.redirectToTradingSafe(address(topUp), address(token), amount);

        assertEq(token.balanceOf(address(topUp)), 750e18, "raw stock not debited");
        assertEq(token.balanceOf(derivedTradingSafe), 0, "raw stock must not reach the safe");
        assertEq(wrapper.balanceOf(derivedTradingSafe), amount, "safe not credited with shares");
        assertEq(token.allowance(address(topUp), address(wrapper)), 0, "standing approval left behind");
    }

    function test_redirect_wrapReportsSharesNotAssets() public {
        MockWrappedToken wrapper = _registerWrapper();
        wrapper.setRate(2e18); // one share costs two assets
        uint256 amount = 100e18;

        // `amount` is the raw stock leaving the TopUp; `RedirectFunds` reports what the safe was
        // actually credited, so summing it by token still tracks the safe's balance.
        vm.expectEmit(true, true, true, true, address(factory));
        emit TopUpFactory.WrapOnRedirect(address(topUp), address(wrapper), address(token), amount, 50e18);
        vm.expectEmit(true, true, true, true, address(factory));
        emit TopUpFactory.RedirectFunds(address(topUp), derivedTradingSafe, address(wrapper), 50e18);

        vm.prank(stranger);
        factory.redirectToTradingSafe(address(topUp), address(token), amount);

        assertEq(wrapper.balanceOf(derivedTradingSafe), 50e18);
        assertEq(token.balanceOf(address(topUp)), 900e18);
    }

    function test_redirect_checksTradingSupportOfTheWrapperNotTheRawStock() public {
        MockWrappedToken wrapper = _registerWrapper();

        // The raw stock is trading-supported in no form of its own — only the wrapper is listed —
        // so it is the wrapper the guard has to be satisfied by.
        vm.mockCall(
            tradingSafeFactoryAddr,
            abi.encodeWithSelector(ITradingSafeFactory.isSupportedToken.selector, address(token)),
            abi.encode(false)
        );
        vm.prank(stranger);
        factory.redirectToTradingSafe(address(topUp), address(token), 100e18);
        assertEq(wrapper.balanceOf(derivedTradingSafe), 100e18);

        // ...and an unlisted wrapper still stops the redirect.
        vm.mockCall(
            tradingSafeFactoryAddr,
            abi.encodeWithSelector(ITradingSafeFactory.isSupportedToken.selector, address(wrapper)),
            abi.encode(false)
        );
        vm.prank(stranger);
        vm.expectRevert(TopUpFactory.TokenNotTradingSupported.selector);
        factory.redirectToTradingSafe(address(topUp), address(token), 100e18);
    }

    function test_redirect_revertsWhenWrapCreditsNothing() public {
        NoOpDepositVault vault = new NoOpDepositVault(address(token));
        _setRedirectWrapper(address(token), address(vault));
        uint256 balanceBefore = token.balanceOf(address(topUp));

        vm.prank(stranger);
        vm.expectRevert(TopUpFactory.WrapMintedNothing.selector);
        factory.redirectToTradingSafe(address(topUp), address(token), 100e18);

        assertEq(token.balanceOf(address(topUp)), balanceBefore, "the pulled stock must roll back");
    }

    function test_redirect_clearedWrapperGoesBackToPlainTransfer() public {
        _registerWrapper();
        _setRedirectWrapper(address(token), address(0));

        vm.prank(stranger);
        factory.redirectToTradingSafe(address(topUp), address(token), 100e18);

        assertEq(token.balanceOf(derivedTradingSafe), 100e18, "should have transferred as-is");
    }

    function test_redirect_wrapRevertsOnZeroAmount() public {
        _registerWrapper();

        vm.prank(stranger);
        vm.expectRevert(TopUp.InvalidAmount.selector);
        factory.redirectToTradingSafe(address(topUp), address(token), 0);
    }

    function test_batchRedirect_wrapsAndTransfersInOneBatch() public {
        MockWrappedToken wrapper = _registerWrapper();
        MockERC20 plain = new MockERC20("Other", "OTH", 18);
        plain.mint(address(topUp), 500e18);

        address[] memory topUps = new address[](2);
        topUps[0] = address(topUp);
        topUps[1] = address(topUp);
        address[] memory tokens = new address[](2);
        tokens[0] = address(token); // wrapper configured → wrap leg
        tokens[1] = address(plain); // no wrapper → transfer leg
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 250e18;

        vm.prank(stranger);
        factory.batchRedirectToTradingSafe(topUps, tokens, amounts);

        assertEq(wrapper.balanceOf(derivedTradingSafe), 100e18);
        assertEq(plain.balanceOf(derivedTradingSafe), 250e18);
        assertEq(token.balanceOf(address(topUp)), 900e18);
    }

    // ---- setRedirectWrappers ----

    function test_setRedirectWrappers_emitsEventAndUpdatesView() public {
        MockWrappedToken wrapper = new MockWrappedToken(IERC20(address(token)));

        vm.expectEmit(true, false, false, true, address(factory));
        emit TopUpFactory.RedirectWrapperSet(address(token), address(0), address(wrapper));
        _setRedirectWrapper(address(token), address(wrapper));

        assertEq(factory.wrapperFor(address(token)), address(wrapper));
        assertEq(factory.wrapperFor(makeAddr("unconfigured")), address(0));
    }

    function test_setRedirectWrappers_revertsForWrapperOfAnotherAsset() public {
        MockERC20 otherAsset = new MockERC20("Other", "OTH", 18);
        MockWrappedToken mismatched = new MockWrappedToken(IERC20(address(otherAsset)));

        vm.prank(owner);
        vm.expectRevert(TopUpFactory.InvalidRedirectWrapper.selector);
        _setRedirectWrapperRaw(address(token), address(mismatched));
    }

    function test_setRedirectWrappers_revertsForNonVault() public {
        // A plain ERC20 has no `asset()` to check the pairing against.
        MockERC20 notAVault = new MockERC20("Plain", "PLN", 18);
        vm.prank(owner);
        vm.expectRevert();
        _setRedirectWrapperRaw(address(token), address(notAVault));
    }

    function test_setRedirectWrappers_revertsOnZeroToken() public {
        vm.prank(owner);
        vm.expectRevert(TopUpFactory.TokenCannotBeZeroAddress.selector);
        _setRedirectWrapperRaw(address(0), address(0));
    }

    function test_setRedirectWrappers_revertsOnLengthMismatch() public {
        address[] memory tokens = new address[](2);
        address[] memory wrappers = new address[](1);
        vm.prank(owner);
        vm.expectRevert(TopUpFactory.ArrayLengthMismatch.selector);
        factory.setRedirectWrappers(tokens, wrappers);
    }

    function test_setRedirectWrappers_revertsForNonAdmin() public {
        MockWrappedToken wrapper = new MockWrappedToken(IERC20(address(token)));
        vm.prank(stranger);
        vm.expectRevert();
        _setRedirectWrapperRaw(address(token), address(wrapper));
    }

    /// @dev Helper: a vault over the misrouted `token`, registered as its redirect wrapper.
    function _registerWrapper() internal returns (MockWrappedToken wrapper) {
        wrapper = new MockWrappedToken(IERC20(address(token)));
        _setRedirectWrapper(address(token), address(wrapper));
    }

    function _setRedirectWrapper(address _token, address _wrapper) internal {
        vm.prank(owner);
        _setRedirectWrapperRaw(_token, _wrapper);
    }

    function _setRedirectWrapperRaw(address _token, address _wrapper) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = _token;
        address[] memory wrappers = new address[](1);
        wrappers[0] = _wrapper;
        factory.setRedirectWrappers(tokens, wrappers);
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
