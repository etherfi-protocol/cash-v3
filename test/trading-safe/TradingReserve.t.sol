// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { TradingReserve } from "../../src/trading-safe/TradingReserve.sol";
import { TradingSafe } from "../../src/trading-safe/TradingSafe.sol";
import { TradingSafeFactory } from "../../src/trading-safe/TradingSafeFactory.sol";
import { TradingSafeTestBase } from "./TradingSafeTestBase.t.sol";

/// @dev 6-decimal USDC stand-in for the primary release path.
contract UsdcMock is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev 18-decimal token to prove the reserve is token-agnostic.
contract GenericToken is ERC20 {
    constructor() ERC20("Generic", "GEN") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract TradingReserveTest is TradingSafeTestBase {
    TradingSafeFactory public factory;
    TradingSafe public tradingSafe;
    TradingReserve public reserve;
    UsdcMock public usdc;
    GenericToken public generic;

    address public bridgeReceiver = makeAddr("bridgeReceiver");
    address public releaser = makeAddr("releaser");
    address public pauser = makeAddr("pauser");
    address public unpauser = makeAddr("unpauser");
    address public stranger = makeAddr("stranger");
    address public sourceSafe = makeAddr("sourceSafe");
    address public tradingSafeOwner = makeAddr("tradingSafeOwner");

    function setUp() public {
        _setupCore();

        vm.startPrank(owner);
        factory = _deployFactory(bridgeReceiver);
        _initDataProvider(address(factory));
        roleRegistry.grantRole(factory.TRADING_SAFE_FACTORY_ADMIN_ROLE(), owner);

        address reserveImpl = address(new TradingReserve(address(factory)));
        reserve = TradingReserve(payable(address(new UUPSProxy(
            reserveImpl,
            abi.encodeWithSelector(TradingReserve.initialize.selector, address(roleRegistry))
        ))));

        roleRegistry.grantRole(reserve.TRADING_RESERVE_RELEASE_ROLE(), releaser);
        roleRegistry.grantRole(roleRegistry.PAUSER(), pauser);
        roleRegistry.grantRole(roleRegistry.UNPAUSER(), unpauser);

        address[] memory tsOwners = new address[](1);
        tsOwners[0] = tradingSafeOwner;
        tradingSafe = _deployTradingSafe(factory, sourceSafe, tsOwners, 1);
        vm.stopPrank();

        usdc = new UsdcMock();
        generic = new GenericToken();
        usdc.mint(address(reserve), 1_000_000e6);
        generic.mint(address(reserve), 500e18);
    }

    // ---- Happy path: USDC ----

    function test_releaseFunds_sendsUsdcToRegisteredTradingSafe() public {
        uint256 amount = 250e6;
        uint256 reserveBefore = usdc.balanceOf(address(reserve));
        uint256 safeBefore = usdc.balanceOf(address(tradingSafe));

        vm.expectEmit(true, true, true, true);
        emit TradingReserve.FundsReleased(address(usdc), sourceSafe, address(tradingSafe), amount);
        vm.prank(releaser);
        reserve.releaseFunds(address(usdc), sourceSafe, amount);

        assertEq(usdc.balanceOf(address(reserve)), reserveBefore - amount);
        assertEq(usdc.balanceOf(address(tradingSafe)), safeBefore + amount);
    }

    // ---- Token-agnostic: any ERC20 the reserve holds is releasable ----

    function test_releaseFunds_worksWith_arbitraryToken() public {
        uint256 amount = 7e18;
        vm.prank(releaser);
        reserve.releaseFunds(address(generic), sourceSafe, amount);

        assertEq(generic.balanceOf(address(tradingSafe)), amount);
    }

    // ---- Role gating ----

    function test_releaseFunds_revertsWhen_callerLacksRole() public {
        vm.expectRevert(TradingReserve.OnlyReleaseRole.selector);
        vm.prank(stranger);
        reserve.releaseFunds(address(usdc), sourceSafe, 100e6);
    }

    // ---- Input validation ----

    function test_releaseFunds_revertsWhen_amountZero() public {
        vm.expectRevert(TradingReserve.InvalidAmount.selector);
        vm.prank(releaser);
        reserve.releaseFunds(address(usdc), sourceSafe, 0);
    }

    // ---- Deterministic-derivation guard: destination must be a registered TradingSafe ----

    function test_releaseFunds_revertsWhen_destinationNotRegistered() public {
        address unknownSource = makeAddr("unknownSource");
        address predicted = factory.getDeterministicAddress(unknownSource);

        vm.expectRevert(abi.encodeWithSelector(TradingReserve.InvalidTradingSafe.selector, predicted));
        vm.prank(releaser);
        reserve.releaseFunds(address(usdc), unknownSource, 100e6);
    }

    // ---- Pause ----

    function test_releaseFunds_revertsWhen_paused() public {
        vm.prank(pauser);
        reserve.pause();

        vm.expectRevert();
        vm.prank(releaser);
        reserve.releaseFunds(address(usdc), sourceSafe, 100e6);
    }

    function test_releaseFunds_worksAgain_afterUnpause() public {
        vm.prank(pauser);
        reserve.pause();
        vm.prank(unpauser);
        reserve.unpause();

        vm.prank(releaser);
        reserve.releaseFunds(address(usdc), sourceSafe, 100e6);

        assertEq(usdc.balanceOf(address(tradingSafe)), 100e6);
    }

    // ---- Inbound: CCTP / treasury mints land in the balance with no special handling ----

    function test_reserve_receivesTokens_withoutInboundHandler() public {
        uint256 before = usdc.balanceOf(address(reserve));
        usdc.mint(address(reserve), 500_000e6);
        assertEq(usdc.balanceOf(address(reserve)), before + 500_000e6);
    }

    // ---- withdrawFunds: role-registry-owner escape hatch ----

    address private constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function test_withdrawFunds_erc20_partial() public {
        address recipient = makeAddr("recipient");
        uint256 before = usdc.balanceOf(address(reserve));

        vm.expectEmit(true, true, true, true);
        emit TradingReserve.FundsWithdrawn(address(usdc), recipient, 250_000e6);
        vm.prank(owner);
        reserve.withdrawFunds(address(usdc), recipient, 250_000e6);

        assertEq(usdc.balanceOf(recipient), 250_000e6);
        assertEq(usdc.balanceOf(address(reserve)), before - 250_000e6);
    }

    function test_withdrawFunds_erc20_drainAllWhenAmountZero() public {
        address recipient = makeAddr("recipient");
        uint256 before = usdc.balanceOf(address(reserve));

        vm.prank(owner);
        reserve.withdrawFunds(address(usdc), recipient, 0);

        assertEq(usdc.balanceOf(recipient), before, "amount=0 drains full balance");
        assertEq(usdc.balanceOf(address(reserve)), 0);
    }

    function test_withdrawFunds_eth_partial() public {
        address recipient = makeAddr("recipient");
        vm.deal(address(reserve), 5 ether);

        vm.prank(owner);
        reserve.withdrawFunds(ETH, recipient, 2 ether);

        assertEq(recipient.balance, 2 ether);
        assertEq(address(reserve).balance, 3 ether);
    }

    function test_withdrawFunds_eth_drainAllWhenAmountZero() public {
        address recipient = makeAddr("recipient");
        vm.deal(address(reserve), 5 ether);

        vm.prank(owner);
        reserve.withdrawFunds(ETH, recipient, 0);

        assertEq(recipient.balance, 5 ether);
        assertEq(address(reserve).balance, 0);
    }

    function test_withdrawFunds_revertsWhen_notRoleRegistryOwner() public {
        vm.expectRevert();
        vm.prank(stranger);
        reserve.withdrawFunds(address(usdc), stranger, 100e6);
    }

    function test_withdrawFunds_revertsWhen_recipientZero() public {
        vm.expectRevert(TradingReserve.InvalidRecipient.selector);
        vm.prank(owner);
        reserve.withdrawFunds(address(usdc), address(0), 100e6);
    }

    function test_withdrawFunds_revertsWhen_erc20BalanceZero() public {
        // Drain first so the next call resolves amount=0 → revert.
        address recipient = makeAddr("recipient");
        vm.prank(owner);
        reserve.withdrawFunds(address(usdc), recipient, 0);

        vm.expectRevert(TradingReserve.CannotWithdrawZeroAmount.selector);
        vm.prank(owner);
        reserve.withdrawFunds(address(usdc), recipient, 0);
    }

    function test_withdrawFunds_revertsWhen_ethBalanceZero() public {
        vm.expectRevert(TradingReserve.CannotWithdrawZeroAmount.selector);
        vm.prank(owner);
        reserve.withdrawFunds(ETH, makeAddr("recipient"), 0);
    }
}
