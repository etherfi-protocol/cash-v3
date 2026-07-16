// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { UUPSProxy } from "../../../../../src/UUPSProxy.sol";
import { IAaveV4PriceFeed } from "../../../../../src/interfaces/IAaveV4PriceFeed.sol";
import { IAggregatorV3 } from "../../../../../src/interfaces/IAggregatorV3.sol";
import { LendGateway } from "../../../../../src/modules/lend-gateway/LendGateway.sol";
import { ChainlinkPriceFeed } from "../../../../../src/oracle/ChainlinkPriceFeed.sol";
import { AaveV4Fixture } from "./helpers/AaveV4Fixture.sol";
import { CashModuleTestSetup } from "../CashModuleTestSetup.t.sol";

/**
 * @title CashGatewayTestSetup
 * @notice Shared setup for cash-flow tests that exercise the REAL LendGateway backed by a real Aave v4
 *         instance deployed in-test on an Optimism fork, with the gateway wired into the CashModule as the
 *         live lend engine. Positions are built through real supply / borrow flows, never injected via mock
 *         setters, so gateway-path behavior (borrowing power, declines, rounding, atomicity) is asserted
 *         against genuine Aave state.
 * @dev These tests run under the lend profile (the default profile skips test/safe/modules/cash/lend/**)
 *      against an Optimism fork. Run with:
 *      source .env && FOUNDRY_PROFILE=lend TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path "test/safe/modules/cash/lend/**"
 *
 *      Dual-engine test convention (functions that route on CashModule.usesLendGateway):
 *      1. The gateway is the default path. Tests of a flag-routed function live in this lend/ directory on a
 *         gateway safe, with positions built through the real supply / borrow helpers below.
 *      2. The legacy DebtManager path lives in its twin outside lend/ (a Legacy* file or debt-manager/*),
 *         opening with _forceLegacyEngine(safe); it may keep the mock gateway as inert plumbing but never sets
 *         gateway state.
 *      3. lend/EngineParity.t.sol is the drift detector: for every (mode x engine) cell it asserts canSpend and
 *         spend agree, so the check side and the execution side never diverge.
 */
abstract contract CashGatewayTestSetup is CashModuleTestSetup, AaveV4Fixture {
    LendGateway internal gw;
    address internal driver = makeAddr("gwDriver"); // arranges Aave positions directly in tests
    address internal recipient = makeAddr("gwRecipient");

    uint256 internal usdcReserveId;
    uint256 internal weethReserveId;

    function setUp() public virtual override {
        // Real ether.fi stack on an Optimism fork (the mock gateway wiring is skipped via _wireDefaultGateway)
        super.setUp();

        // Real Aave v4 instance on the fork, weETH + USDC reserves priced by live Chainlink feeds
        _deployAaveV4();
        address weethSource = address(new ChainlinkPriceFeed(IAggregatorV3(weEthWethOracle), IAaveV4PriceFeed(ethUsdcOracle), 8, 30 days, false, "weETH / USD"));
        weethReserveId = _addAaveReserve(address(weETH), weethSource, _weethCollateralFactorBps(), _weethBorrowable());
        usdcReserveId = _addAaveReserve(address(usdc), usdcUsdOracle, _usdcCollateralFactorBps(), true);
        _seedInitialLiquidity();

        // LendGateway proxy pointing at the fresh spoke, wired as the CashModule's live lend engine
        address gwImpl = address(new LendGateway(address(dataProvider), address(spoke)));
        gw = LendGateway(address(new UUPSProxy(gwImpl, abi.encodeWithSelector(LendGateway.initialize.selector, address(roleRegistry)))));

        vm.startPrank(owner);
        roleRegistry.grantRole(gw.LEND_GATEWAY_ADMIN_ROLE(), owner);
        gw.setReserveId(address(weETH), weethReserveId);
        gw.setReserveId(address(usdc), usdcReserveId);
        // USDC is the card settlement token; weETH is collateral-only and never a debit-spend asset
        gw.setSpendAsset(address(usdc), true);
        gw.setDriver(driver, true);
        cashModule.setLendGateway(address(gw));
        vm.stopPrank();

        _enableModule(address(gw));
        _activateAavePositionManager(address(gw));

        // The default safe was deployed in super.setUp() before the gateway existed, so it onboarded onto the
        // legacy engine (onboarding with the lend flag reverts until the gateway is set). This suite exercises
        // gateway operations on that safe, so put it on the gateway engine now.
        _forceGatewayEngine(address(safe));
    }

    /// @dev Empty on purpose: skips the base mock-gateway wiring so this suite's one-time setLendGateway(gw) is the first and only set.
    function _wireDefaultGateway() internal override { }

    /// @dev The default safe deploys in super.setUp() before the real gateway exists, so onboarding it with the
    ///      lend flag would revert LendGatewayNotSet. It onboards legacy, then _forceGatewayEngine flips it.
    function _newSafeUsesLend() internal pure override returns (bool) {
        return false;
    }

    // ----------------------------------------------------------------- overridable reserve policy

    /// @dev weETH reserve collateral factor in BPS; override to model a different Aave LTV.
    function _weethCollateralFactorBps() internal pure virtual returns (uint16) {
        return 8000;
    }

    /// @dev Whether the weETH reserve allows borrowing (collateral-only by default, matching the planned
    ///      instance config); override to model weETH as a spendable (borrowable) token.
    function _weethBorrowable() internal pure virtual returns (bool) {
        return false;
    }

    /// @dev USDC reserve collateral factor in BPS; override to model a different Aave LTV.
    function _usdcCollateralFactorBps() internal pure virtual returns (uint16) {
        return 8000;
    }

    /// @dev Borrowable liquidity seeded into the USDC reserve at setup; override to seed a different amount (or none).
    function _seedInitialLiquidity() internal virtual {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 1_000_000e6);
    }

    // ----------------------------------------------------------------- position builders

    /// @dev Supplies `amount` of `token` to Aave for `safe_` (dealing it first) and enables it as collateral.
    function _supplyToGateway(address safe_, address token, uint256 amount) internal {
        deal(token, safe_, IERC20(token).balanceOf(safe_) + amount);
        vm.startPrank(driver);
        gw.supply(safe_, token, amount);
        gw.setUsingAsCollateral(safe_, token, true);
        vm.stopPrank();
    }

    /// @dev Borrows `amount` of `token` against `safe_`'s position, sending it to `to`.
    function _borrowOnGateway(address safe_, address token, uint256 amount, address to) internal {
        vm.prank(driver);
        gw.borrow(safe_, token, amount, to);
    }

    /// @dev Builds a full position for `safe_`: supplies collateral, then (if debtAmt > 0) borrows against it.
    function _buildGatewayPosition(address safe_, address collateral, uint256 collateralAmt, address debtToken, uint256 debtAmt) internal {
        _supplyToGateway(safe_, collateral, collateralAmt);
        if (debtAmt > 0) {
            _borrowOnGateway(safe_, debtToken, debtAmt, recipient);
        }
    }

    /// @dev Sets a registered asset's Aave collateral factor (BPS), i.e. its LTV, for the whole reserve.
    function _setAaveCollateralFactor(address token, uint16 cfBps) internal {
        _setAaveReserveCollateralFactor(gw.reserveIdOf(token), cfBps);
    }

    // ----------------------------------------------------------------- module wiring helpers

    /// @dev Whitelists (via dataProvider) then enables `module` on the safe via owner signatures.
    function _enableModule(address module) internal {
        address[] memory modules = _addr1(module);
        bool[] memory shouldWhitelist = _bool1(true);
        vm.prank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);
        bytes[] memory setupData = new bytes[](1);
        setupData[0] = "";
        _configureModules(modules, shouldWhitelist, setupData);
    }

    function _addr1(address a) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = a;
        return arr;
    }

    function _bool1(bool b) internal pure returns (bool[] memory) {
        bool[] memory arr = new bool[](1);
        arr[0] = b;
        return arr;
    }
}
