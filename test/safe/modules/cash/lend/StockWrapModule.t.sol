// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC4626Mock } from "@openzeppelin/contracts/mocks/token/ERC4626Mock.sol";

import { UUPSProxy } from "../../../../../src/UUPSProxy.sol";
import { ICashModule } from "../../../../../src/interfaces/ICashModule.sol";
import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";
import { StockWrapModule } from "../../../../../src/modules/stock-wrap/StockWrapModule.sol";
import { RoleRegistry } from "../../../../../src/role-registry/RoleRegistry.sol";
import { UpgradeableProxy, PausableUpgradeable } from "../../../../../src/utils/UpgradeableProxy.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title StockWrapModuleTest
 * @notice Raw stock sitting in a gateway safe is wrapped into its wrapper for the same safe, with held amounts left
 *         alone and the lend position untouched.
 */
contract StockWrapModuleTest is CashGatewayTestSetup {
    StockWrapModule internal module;
    MockERC20 internal raw;
    ERC4626Mock internal wrapper;

    address internal keeper = makeAddr("keeper");
    address internal admin = makeAddr("wrapAdmin");

    uint256 internal constant AMOUNT = 3e18;

    function setUp() public override {
        super.setUp();

        raw = new MockERC20("SPYx", "SPYx", 18);
        wrapper = new ERC4626Mock(address(raw));

        address impl = address(new StockWrapModule(address(dataProvider)));
        module = StockWrapModule(address(new UUPSProxy(impl, abi.encodeWithSelector(StockWrapModule.initialize.selector, address(roleRegistry)))));
        _enableModule(address(module));

        vm.startPrank(owner);
        roleRegistry.grantRole(module.ETHER_FI_WALLET_ROLE(), keeper);
        roleRegistry.grantRole(roleRegistry.ADMIN_TIMELOCK_ROLE(), admin);
        vm.stopPrank();

        vm.prank(admin);
        module.setWrapPairs(_addr1(address(raw)), _addr1(address(wrapper)));
    }

    function test_wrap_creditsSafeAndLeavesLendPositionAlone() public {
        raw.mint(address(safe), AMOUNT);

        vm.prank(keeper);
        vm.expectEmit(true, true, true, true);
        emit StockWrapModule.Wrapped(address(safe), address(raw), address(wrapper), AMOUNT, AMOUNT);
        uint256 shares = module.wrap(address(safe), address(raw));

        assertEq(shares, AMOUNT);
        assertEq(raw.balanceOf(address(safe)), 0, "raw left in the safe");
        assertEq(wrapper.balanceOf(address(safe)), AMOUNT, "shares not credited to the safe");
        assertEq(raw.allowance(address(safe), address(wrapper)), 0, "allowance left on the wrapper");
        assertEq(gw.suppliedOf(address(safe), address(wrapper)), 0, "wrap must not touch the lend position");
    }

    function test_wrap_leavesPendingWithdrawalUntouched() public {
        uint256 held = 1e18;
        raw.mint(address(safe), AMOUNT);
        vm.mockCall(address(cashModule), abi.encodeWithSelector(ICashModule.getPendingWithdrawalAmount.selector, address(safe), address(raw)), abi.encode(held));

        vm.prank(keeper);
        uint256 shares = module.wrap(address(safe), address(raw));

        assertEq(shares, AMOUNT - held);
        assertEq(raw.balanceOf(address(safe)), held, "held raw was wrapped");
    }

    function test_wrap_reverts_whenNothingToWrap() public {
        vm.prank(keeper);
        vm.expectRevert(StockWrapModule.NothingToWrap.selector);
        module.wrap(address(safe), address(raw));
    }

    function test_wrap_reverts_whenPairNotSet() public {
        MockERC20 other = new MockERC20("QQQx", "QQQx", 18);
        other.mint(address(safe), AMOUNT);

        vm.prank(keeper);
        vm.expectRevert(StockWrapModule.PairNotSet.selector);
        module.wrap(address(safe), address(other));
    }

    function test_wrap_reverts_whenNotKeeper() public {
        raw.mint(address(safe), AMOUNT);

        vm.prank(admin);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        module.wrap(address(safe), address(raw));
    }

    function test_wrap_reverts_whenPaused() public {
        raw.mint(address(safe), AMOUNT);
        vm.prank(pauser);
        module.pause();

        vm.prank(keeper);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        module.wrap(address(safe), address(raw));
    }

    function test_wrapSelf_reverts_whenNotSelf() public {
        raw.mint(address(safe), AMOUNT);

        vm.prank(keeper);
        vm.expectRevert(StockWrapModule.OnlySelf.selector);
        module.wrapSelf(address(safe), address(raw));
    }

    function test_wrapMany_skipsFailuresAndContinues() public {
        raw.mint(address(safe), AMOUNT);
        address[] memory safes = new address[](3);
        safes[0] = makeAddr("notASafe");
        safes[1] = address(safe);
        safes[2] = address(safe); // nothing left after the first pass

        vm.prank(keeper);
        vm.expectEmit(true, true, false, false);
        emit StockWrapModule.WrapSkipped(safes[0], address(raw), "");
        uint256 wrapped = module.wrapMany(safes, address(raw));

        assertEq(wrapped, 1);
        assertEq(wrapper.balanceOf(address(safe)), AMOUNT);
    }

    function test_setWrapPairs_checksAssetAndRole() public {
        MockERC20 other = new MockERC20("QQQx", "QQQx", 18);

        vm.prank(admin);
        vm.expectRevert(StockWrapModule.InvalidWrapperAsset.selector);
        module.setWrapPairs(_addr1(address(other)), _addr1(address(wrapper)));

        vm.prank(keeper);
        vm.expectRevert(RoleRegistry.OnlyAdminTimelock.selector);
        module.setWrapPairs(_addr1(address(raw)), _addr1(address(0)));

        vm.prank(admin);
        module.setWrapPairs(_addr1(address(raw)), _addr1(address(0)));
        assertEq(module.wrapPairFor(address(raw)), address(0), "zero wrapper should remove the pair");
    }
}
