// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { IGateway } from "../../src/interfaces/IGateway.sol";
import { Gateway } from "../../src/modules/gateway/Gateway.sol";
import { ChainlinkCompositePriceFeed } from "../../src/oracle/ChainlinkCompositePriceFeed.sol";
import { UpgradeableProxy } from "../../src/utils/UpgradeableProxy.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { CashModuleTestSetup } from "../safe/modules/cash/CashModuleTestSetup.t.sol";
import { AaveV4Fixture } from "./helpers/AaveV4Fixture.sol";

/**
 * @title GatewayAaveV4Test
 * @notice End-to-end Gateway tests against a REAL Aave v4 instance deployed inside the test on an Optimism
 *         fork, driven by the REAL ether.fi stack (EtherFiSafe, EtherFiDataProvider, RoleRegistry,
 *         PriceProvider) — no mocks. Aave reserves are priced by live Optimism Chainlink feeds.
 * @dev Run with: source .env && FOUNDRY_PROFILE=aave TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path test/gateway/GatewayAaveV4.t.sol
 */
contract GatewayAaveV4Test is CashModuleTestSetup, AaveV4Fixture {
    Gateway internal gw;
    address internal driver = makeAddr("gwDriver");
    address internal recipient = makeAddr("gwRecipient");

    uint256 internal usdcReserveId;
    uint256 internal weethReserveId;

    function setUp() public override {
        // Real ether.fi stack on an Optimism fork
        super.setUp();

        // 1. Deploy a real, self-owned Aave v4 instance on the same fork
        _deployAaveV4();

        // 2. List reserves for the OP tokens, priced by live Chainlink feeds (no mock prices):
        //    - weETH: composite weETH/ETH x ETH/USD via the repo's ChainlinkCompositePriceFeed
        //    - USDC: the USDC/USD aggregator directly (it already exposes decimals/description/latestAnswer)
        address weethSource = address(new ChainlinkCompositePriceFeed(IAggregatorV3(weEthWethOracle), IAggregatorV3(ethUsdcOracle), 8, 30 days, 30 days, "weETH / USD"));
        weethReserveId = _addAaveReserve(address(weETH), weethSource, 80_00, false);
        usdcReserveId = _addAaveReserve(address(usdc), usdcUsdOracle, 80_00, true);

        // Seed borrowable USDC liquidity into the hub
        _seedAaveLiquidity(usdcReserveId, address(usdc), 1_000_000e6);

        // 3. Deploy the Gateway proxy pointing at the fresh spoke
        address gwImpl = address(new Gateway(address(dataProvider), address(spoke)));
        gw = Gateway(address(new UUPSProxy(gwImpl, abi.encodeWithSelector(Gateway.initialize.selector, address(roleRegistry)))));

        // 4. Wire the Gateway: roles, reserve registry, driver, whitelist as a module
        vm.startPrank(owner);
        roleRegistry.grantRole(gw.GATEWAY_ADMIN_ROLE(), owner);
        dataProvider.configureModules(_addr1(address(gw)), _bool1(true));
        gw.setReserveId(address(weETH), weethReserveId);
        gw.setReserveId(address(usdc), usdcReserveId);
        gw.setDriver(driver, true);
        vm.stopPrank();

        // Enable the Gateway as a module on the safe (owner-signed) and activate it as an Aave position manager
        _enableModule(address(gw));
        _activateAavePositionManager(address(gw));
    }

    // ----------------------------------------------------------------- registration & reads

    function test_registration_validatedAgainstSpoke() public {
        assertTrue(gw.isRegistered(address(weETH)));
        assertTrue(gw.isRegistered(address(usdc)));
        assertEq(gw.reserveIdOf(address(usdc)), usdcReserveId);

        // A reserveId whose underlying != the asset is rejected
        vm.prank(owner);
        vm.expectRevert(Gateway.ReserveAssetMismatch.selector);
        gw.setReserveId(address(weETH), usdcReserveId);
    }

    function test_reads_ltvAndLiquidity() public view {
        // 80_00 bps -> 80e18 in IGateway's 100e18 scale
        assertEq(gw.ltv(address(usdc)), 80e18);
        assertEq(gw.ltv(address(weETH)), 80e18);
        // Seeded liquidity is withdrawable/borrowable cash
        assertGe(gw.availableCash(address(usdc)), 1_000_000e6);
    }

    function test_getAccountData_freshSafeIsEmptyAndHealthy() public view {
        IGateway.AccountData memory data = gw.getAccountData(address(safe));
        assertEq(data.collateralUsd, 0);
        assertEq(data.debtUsd, 0);
        assertEq(data.availableBorrowsUsd, 0);
        assertEq(data.healthFactor, type(uint256).max);
    }

    // ----------------------------------------------------------------- approval (no user signature)

    function test_supply_autoApprovesPositionManagerOnFirstOp() public {
        assertFalse(spoke.isPositionManager(address(safe), address(gw)));

        deal(address(weETH), address(safe), 10 ether);
        vm.prank(driver);
        gw.supply(address(safe), address(weETH), 5 ether);

        // Approval was folded into the op, with no owner signature
        assertTrue(spoke.isPositionManager(address(safe), address(gw)));
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(weETH)), 5 ether, 2);
    }

    // ----------------------------------------------------------------- full lifecycle vs real Aave

    function test_fullLifecycle_supplyCollateralBorrowRepayWithdraw() public {
        deal(address(weETH), address(safe), 10 ether);

        // supply weETH and enable it as collateral
        vm.startPrank(driver);
        gw.supply(address(safe), address(weETH), 5 ether);
        gw.setUsingAsCollateral(address(safe), address(weETH), true);

        // borrow USDC to a recipient
        gw.borrow(address(safe), address(usdc), 1000e6, recipient);
        vm.stopPrank();

        assertEq(usdc.balanceOf(recipient), 1000e6, "recipient receives borrow");
        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), 1000e6, 2, "debt recorded");

        IGateway.AccountData memory data = gw.getAccountData(address(safe));
        assertGt(data.collateralUsd, 0, "collateral valued");
        assertApproxEqAbs(data.debtUsd, 1000e6, 1e6, "debt in USD");
        assertGt(data.availableBorrowsUsd, 0, "headroom remains");
        assertGt(data.healthFactor, 1e18, "healthy");

        // repay the full debt
        deal(address(usdc), address(safe), 1010e6);
        vm.prank(driver);
        gw.repay(address(safe), address(usdc), type(uint256).max);
        assertLe(gw.debtOf(address(safe), address(usdc)), 1, "debt cleared");

        // withdraw part of the collateral to a recipient
        uint256 beforeBal = weETH.balanceOf(recipient);
        vm.prank(driver);
        gw.withdraw(address(safe), address(weETH), 2 ether, recipient);
        assertEq(weETH.balanceOf(recipient) - beforeBal, 2 ether, "withdraw forwarded");
    }

    // ----------------------------------------------------------------- users cannot disable the position manager

    function test_userCannotDisablePositionManager() public {
        deal(address(weETH), address(safe), 10 ether);
        vm.prank(driver);
        gw.supply(address(safe), address(weETH), 5 ether);
        assertTrue(spoke.isPositionManager(address(safe), address(gw)));

        // The safe tries to revoke the gateway directly on the spoke
        vm.prank(address(safe));
        spoke.setUserPositionManager(address(gw), false);
        assertFalse(spoke.isPositionManager(address(safe), address(gw)));

        // The next op re-establishes approval and succeeds — a user cannot durably turn the manager off
        deal(address(weETH), address(safe), 1 ether);
        vm.prank(driver);
        gw.supply(address(safe), address(weETH), 1 ether);
        assertTrue(spoke.isPositionManager(address(safe), address(gw)), "re-approved on next op");
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(weETH)), 6 ether, 3);
    }

    // ----------------------------------------------------------------- access control

    function test_onlyDriverCanOperate() public {
        deal(address(weETH), address(safe), 1 ether);
        vm.prank(makeAddr("notADriver"));
        vm.expectRevert(Gateway.OnlyDriver.selector);
        gw.supply(address(safe), address(weETH), 1 ether);
    }

    function test_cashModuleIsAlwaysADriver() public {
        assertTrue(gw.isDriver(address(cashModule)));
        assertTrue(gw.isDriver(driver));
        assertFalse(gw.isDriver(makeAddr("random")));
    }

    function test_setReserveId_requiresGatewayAdminRole() public {
        vm.prank(makeAddr("notAdmin"));
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        gw.setReserveId(address(weETH), weethReserveId);
    }

    // ----------------------------------------------------------------- registry management

    function test_setReserveId_rejectsZeroAsset() public {
        vm.prank(owner);
        vm.expectRevert(Gateway.ZeroAddress.selector);
        gw.setReserveId(address(0), 0);
    }

    function test_removeReserve_unregistersAndZeroesReads() public {
        vm.prank(owner);
        gw.removeReserve(address(usdc));

        assertFalse(gw.isRegistered(address(usdc)));
        assertEq(gw.ltv(address(usdc)), 0);
        assertEq(gw.availableCash(address(usdc)), 0);
        assertEq(gw.suppliedOf(address(safe), address(usdc)), 0);
        assertEq(gw.debtOf(address(safe), address(usdc)), 0);

        vm.expectRevert(abi.encodeWithSelector(Gateway.AssetNotRegistered.selector, address(usdc)));
        gw.reserveIdOf(address(usdc));
    }

    function test_removeReserve_guards() public {
        address never = makeAddr("neverRegistered");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Gateway.AssetNotRegistered.selector, never));
        gw.removeReserve(never);

        vm.prank(makeAddr("notAdmin"));
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        gw.removeReserve(address(usdc));
    }

    // ----------------------------------------------------------------- driver management

    function test_setDriver_guardsAndDeauthorization() public {
        // De-authorizing a driver stops it operating
        vm.prank(owner);
        gw.setDriver(driver, false);
        deal(address(weETH), address(safe), 1 ether);
        vm.prank(driver);
        vm.expectRevert(Gateway.OnlyDriver.selector);
        gw.supply(address(safe), address(weETH), 1 ether);

        // Zero address and role gating
        vm.prank(owner);
        vm.expectRevert(Gateway.ZeroAddress.selector);
        gw.setDriver(address(0), true);

        vm.prank(makeAddr("notAdmin"));
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        gw.setDriver(makeAddr("d"), true);
    }

    // ----------------------------------------------------------------- op guards (all mutating ops)

    function test_mutatingOps_onlyDriver() public {
        vm.startPrank(makeAddr("notADriver"));
        vm.expectRevert(Gateway.OnlyDriver.selector);
        gw.withdraw(address(safe), address(weETH), 1, recipient);
        vm.expectRevert(Gateway.OnlyDriver.selector);
        gw.borrow(address(safe), address(usdc), 1, recipient);
        vm.expectRevert(Gateway.OnlyDriver.selector);
        gw.repay(address(safe), address(usdc), 1);
        vm.expectRevert(Gateway.OnlyDriver.selector);
        gw.setUsingAsCollateral(address(safe), address(weETH), true);
        vm.stopPrank();
    }

    function test_mutatingOps_revertOnUnregisteredAsset() public {
        address unreg = makeAddr("unregisteredAsset");
        bytes memory notRegistered = abi.encodeWithSelector(Gateway.AssetNotRegistered.selector, unreg);
        vm.startPrank(driver);
        vm.expectRevert(notRegistered);
        gw.supply(address(safe), unreg, 1e18);
        vm.expectRevert(notRegistered);
        gw.withdraw(address(safe), unreg, 1e18, recipient);
        vm.expectRevert(notRegistered);
        gw.borrow(address(safe), unreg, 1e18, recipient);
        vm.expectRevert(notRegistered);
        gw.repay(address(safe), unreg, type(uint256).max);
        vm.expectRevert(notRegistered);
        gw.setUsingAsCollateral(address(safe), unreg, true);
        vm.stopPrank();
    }

    function test_ops_revertOnZeroAmountAndRecipient() public {
        vm.startPrank(driver);
        vm.expectRevert(Gateway.ZeroAmount.selector);
        gw.supply(address(safe), address(weETH), 0);
        vm.expectRevert(Gateway.ZeroAmount.selector);
        gw.withdraw(address(safe), address(weETH), 0, recipient);
        vm.expectRevert(Gateway.ZeroAmount.selector);
        gw.borrow(address(safe), address(usdc), 0, recipient);
        vm.expectRevert(Gateway.ZeroAddress.selector);
        gw.withdraw(address(safe), address(weETH), 1, address(0));
        vm.expectRevert(Gateway.ZeroAddress.selector);
        gw.borrow(address(safe), address(usdc), 1, address(0));
        // repay(max) with no debt resolves to a zero pull amount
        vm.expectRevert(Gateway.ZeroAmount.selector);
        gw.repay(address(safe), address(usdc), type(uint256).max);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- pause

    function test_pauseBlocksOpsThenUnpauseResumes() public {
        deal(address(weETH), address(safe), 2 ether);

        vm.prank(pauser);
        gw.pause();
        vm.prank(driver);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        gw.supply(address(safe), address(weETH), 1 ether);

        vm.prank(unpauser);
        gw.unpause();
        vm.prank(driver);
        gw.supply(address(safe), address(weETH), 1 ether);
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(weETH)), 1 ether, 2);
    }

    // ----------------------------------------------------------------- reads & misc

    function test_reads_unregisteredAssetReturnZero() public {
        address unreg = makeAddr("unregisteredRead");
        assertEq(gw.suppliedOf(address(safe), unreg), 0);
        assertEq(gw.debtOf(address(safe), unreg), 0);
        assertEq(gw.availableCash(unreg), 0);
        assertEq(gw.ltv(unreg), 0);
    }

    function test_repay_partialReducesDebt() public {
        deal(address(weETH), address(safe), 10 ether);
        vm.startPrank(driver);
        gw.supply(address(safe), address(weETH), 5 ether);
        gw.setUsingAsCollateral(address(safe), address(weETH), true);
        gw.borrow(address(safe), address(usdc), 1000e6, recipient);
        vm.stopPrank();

        deal(address(usdc), address(safe), 400e6);
        vm.prank(driver);
        uint256 repaid = gw.repay(address(safe), address(usdc), 400e6);

        assertApproxEqAbs(repaid, 400e6, 2, "partial repay amount");
        assertApproxEqAbs(gw.debtOf(address(safe), address(usdc)), 600e6, 2, "remaining debt");
    }

    function test_setUsingAsCollateral_enableThenDisable() public {
        deal(address(weETH), address(safe), 5 ether);
        vm.startPrank(driver);
        gw.supply(address(safe), address(weETH), 5 ether);

        gw.setUsingAsCollateral(address(safe), address(weETH), true);
        (bool enabled,) = spoke.getUserReserveStatus(weethReserveId, address(safe));
        assertTrue(enabled, "collateral enabled");

        gw.setUsingAsCollateral(address(safe), address(weETH), false);
        (bool disabled,) = spoke.getUserReserveStatus(weethReserveId, address(safe));
        assertFalse(disabled, "collateral disabled");
        vm.stopPrank();
    }

    function test_isApprovedBy_reflectsApprovalState() public {
        assertFalse(gw.isApprovedBy(address(safe)), "not approved before first op");
        deal(address(weETH), address(safe), 1 ether);
        vm.prank(driver);
        gw.supply(address(safe), address(weETH), 1 ether);
        assertTrue(gw.isApprovedBy(address(safe)), "approved after first op");
    }

    function test_constructor_revertsOnZeroSpoke() public {
        vm.expectRevert(Gateway.ZeroAddress.selector);
        new Gateway(address(dataProvider), address(0));
    }

    // ----------------------------------------------------------------- proof the deployed Aave pool is live

    /// @dev The real Aave risk engine must reject a borrow beyond the collateral's borrowing power.
    function test_borrow_beyondBorrowingPowerReverts() public {
        // ~1 weETH collateral at 80% LTV gives a few thousand USD of power; borrowing $50k must revert.
        deal(address(weETH), address(safe), 1 ether);
        vm.startPrank(driver);
        gw.supply(address(safe), address(weETH), 1 ether);
        gw.setUsingAsCollateral(address(safe), address(weETH), true);
        vm.expectRevert(); // Aave health-factor / borrowing-power check
        gw.borrow(address(safe), address(usdc), 50_000e6, recipient);
        vm.stopPrank();
    }

    /// @dev Supply and borrow must move the reserve's real hub-level accounting, not just per-user views.
    function test_reserveAccountingReflectsSupplyAndBorrow() public {
        uint256 cashBefore = gw.availableCash(address(usdc));
        assertApproxEqAbs(cashBefore, 1_000_000e6, 1, "seeded USDC liquidity present");

        deal(address(weETH), address(safe), 5 ether);
        vm.startPrank(driver);
        gw.supply(address(safe), address(weETH), 5 ether);
        gw.setUsingAsCollateral(address(safe), address(weETH), true);
        gw.borrow(address(safe), address(usdc), 1000e6, recipient);
        vm.stopPrank();

        // Borrow drew from the USDC reserve's cash (hub liquidity accounting)
        assertApproxEqAbs(gw.availableCash(address(usdc)), cashBefore - 1000e6, 2, "borrow reduced reserve cash");
        // Supply landed in the weETH reserve (hub-side supplied assets)
        assertApproxEqAbs(spoke.getReserveSuppliedAssets(weethReserveId), 5 ether, 3, "supply increased reserve assets");
    }

    /// @dev The proxy is initialized in setUp; a second initialize must revert (no init-hijack)
    function test_initialize_cannotBeCalledTwice() public {
        vm.expectRevert(bytes4(keccak256("InvalidInitialization()")));
        gw.initialize(address(roleRegistry));
    }

    /// @dev If the gateway is not an enabled module on the safe, the auto-approval exec reverts (OnlyModules)
    function test_ops_revertWhenGatewayNotEnabledOnSafe() public {
        // Disable the gateway module on the safe (owner-signed), leaving it unable to drive the safe
        address[] memory modules = _addr1(address(gw));
        bool[] memory disable = _bool1(false);
        bytes[] memory setupData = new bytes[](1);
        setupData[0] = "";
        _configureModules(modules, disable, setupData);

        deal(address(weETH), address(safe), 1 ether);
        vm.prank(driver);
        vm.expectRevert(bytes4(keccak256("OnlyModules()")));
        gw.supply(address(safe), address(weETH), 1 ether);
    }

    /// @dev Supplied-but-not-collateral counts toward collateralUsd but grants no borrowing power
    function test_getAccountData_nonCollateralSupplyHasNoBorrowPower() public {
        deal(address(weETH), address(safe), 5 ether);
        vm.startPrank(driver);
        gw.supply(address(safe), address(weETH), 5 ether);
        gw.setUsingAsCollateral(address(safe), address(weETH), false);
        vm.stopPrank();

        IGateway.AccountData memory data = gw.getAccountData(address(safe));
        assertGt(data.collateralUsd, 0, "supplied value counted as collateralUsd");
        assertEq(data.availableBorrowsUsd, 0, "no borrow power without collateral enabled");
        assertEq(data.debtUsd, 0);
    }

    /// @dev Overpaying repay: the spoke caps at the debt and the gateway refunds the dust to the safe
    function test_repay_refundsDustWhenOverpaying() public {
        deal(address(weETH), address(safe), 10 ether);
        vm.startPrank(driver);
        gw.supply(address(safe), address(weETH), 5 ether);
        gw.setUsingAsCollateral(address(safe), address(weETH), true);
        gw.borrow(address(safe), address(usdc), 1000e6, recipient);
        vm.stopPrank();

        // Fund the safe with more than the debt; repay the full over-amount
        deal(address(usdc), address(safe), 1500e6);
        vm.prank(driver);
        uint256 repaid = gw.repay(address(safe), address(usdc), 1500e6);

        assertApproxEqAbs(repaid, 1000e6, 2, "only the debt is repaid");
        assertLe(gw.debtOf(address(safe), address(usdc)), 1, "debt cleared");
        assertApproxEqAbs(usdc.balanceOf(address(safe)), 500e6, 2, "excess refunded to safe");
    }

    // ----------------------------------------------------------------- helpers

    /// @dev Whitelists (done in setUp) then enables `module` on the safe via owner signatures
    function _enableModule(address module) internal {
        address[] memory modules = _addr1(module);
        bool[] memory shouldWhitelist = _bool1(true);
        bytes[] memory setupData = new bytes[](1);
        setupData[0] = "";
        _configureModules(modules, shouldWhitelist, setupData);
    }

    function _addr1(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _bool1(bool b) internal pure returns (bool[] memory arr) {
        arr = new bool[](1);
        arr[0] = b;
    }
}
