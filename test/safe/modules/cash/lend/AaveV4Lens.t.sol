// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";

import { IAaveV4Spoke } from "../../../../../src/interfaces/IAaveV4Spoke.sol";
import { AaveV4Lens } from "../../../../../src/lens/AaveV4Lens.sol";
import { UUPSProxy } from "../../../../../src/UUPSProxy.sol";
import { AaveV4Fixture } from "./helpers/AaveV4Fixture.sol";

/// @dev Fixed-price IPriceFeed for the in-test Aave instance (8-decimal USD)
contract MockPriceFeed {
    int256 private immutable ANSWER;

    constructor(int256 answer_) {
        ANSWER = answer_;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "mock / USD";
    }

    function latestAnswer() external view returns (int256) {
        return ANSWER;
    }
}

/// @dev Deploys a real Aave v4 instance in-test and asserts the lens aggregates it faithfully
contract AaveV4LensTest is AaveV4Fixture {
    AaveV4Lens internal lens;
    MockERC20 internal weeth;
    MockERC20 internal usdc;
    uint256 internal weethId;
    uint256 internal usdcId;
    address internal user = makeAddr("lensUser");
    address internal lensRoleRegistry = makeAddr("lensRoleRegistry");

    function setUp() public {
        _deployAaveV4();

        weeth = new MockERC20("Wrapped eETH", "weETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        weethId = _addAaveReserve(address(weeth), address(new MockPriceFeed(3000e8)), 55_00, false);
        usdcId = _addAaveReserve(address(usdc), address(new MockPriceFeed(1e8)), 90_00, true);
        _seedAaveLiquidity(usdcId, address(usdc), 1_000_000e6);

        address lensImpl = address(new AaveV4Lens());
        lens = AaveV4Lens(address(new UUPSProxy(lensImpl, abi.encodeWithSelector(AaveV4Lens.initialize.selector, lensRoleRegistry))));

        // Real position: 10 weETH collateral, 5k USDC debt
        deal(address(weeth), user, 10e18);
        vm.startPrank(user);
        weeth.approve(address(spoke), 10e18);
        spoke.supply(weethId, 10e18, user);
        spoke.setUsingAsCollateral(weethId, true, user);
        spoke.borrow(usdcId, 5_000e6, user);
        vm.stopPrank();
    }

    function test_getMarketData_aggregatesAllReserves() public view {
        AaveV4Lens.ReserveData[] memory data = lens.getMarketData(IAaveV4Spoke(address(spoke)));

        assertEq(data.length, 2);
        assertEq(data[weethId].underlying, address(weeth));
        assertEq(data[weethId].decimals, 18);
        assertEq(data[weethId].symbol, "weETH");
        assertEq(data[weethId].collateralFactorBps, 55_00);
        assertFalse(data[weethId].borrowable);
        assertEq(data[weethId].price, 3000e8);

        assertTrue(data[usdcId].borrowable);
        assertEq(data[usdcId].price, 1e8);
        assertEq(data[usdcId].suppliedAssets, 1_000_000e6);
        assertEq(data[usdcId].totalDebt, 5_000e6);
        assertGt(data[usdcId].drawnRateRay, 0);
        assertEq(data[usdcId].liquidityFeeBps, 1000); // fixture's hub.updateAssetConfig liquidityFee
    }

    function test_getUserData_matchesDirectSpokeReads() public view {
        (IAaveV4Spoke.UserAccountData memory account, AaveV4Lens.UserReserveData[] memory reserves) =
            lens.getUserData(IAaveV4Spoke(address(spoke)), user);

        // Account block must equal the spoke's own answer verbatim
        assertEq(account.healthFactor, spoke.getUserAccountData(user).healthFactor);
        assertGt(account.healthFactor, 1e18);
        assertGt(account.totalCollateralValue, 0);
        assertGt(account.totalDebtValueRay, 0);

        assertEq(reserves.length, 2);
        assertTrue(reserves[weethId].usingAsCollateral);
        assertEq(reserves[weethId].suppliedAssets, 10e18);
        assertTrue(reserves[usdcId].borrowed);
        assertEq(reserves[usdcId].totalDebt, 5_000e6);
    }

    function test_initialize_lockedAfterProxyDeploy() public {
        assertEq(address(lens.roleRegistry()), lensRoleRegistry);
        vm.expectRevert();
        lens.initialize(makeAddr("attacker"));
    }
}
