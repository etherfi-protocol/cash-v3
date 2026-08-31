// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Test } from "forge-std/Test.sol";

import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { IOracleSink } from "../../src/interfaces/IOracleSink.sol";
import { BaseAaveV4PriceFeed } from "../../src/oracle/BaseAaveV4PriceFeed.sol";
import { OracleSinkPriceFeed } from "../../src/oracle/OracleSinkPriceFeed.sol";
import { ERC4626PriceCapAdapter } from "../../src/oracle/capo/ERC4626PriceCapAdapter.sol";
import { CLRatePriceCapAdapter } from "../../src/oracle/capo/vendor/CLRatePriceCapAdapter.sol";
import { IACLManager } from "../../src/oracle/capo/vendor/IACLManager.sol";
import { IPriceCapAdapter } from "../../src/oracle/capo/vendor/IPriceCapAdapter.sol";
import { MockOracleSink } from "./OracleSinkPriceFeed.t.sol";

/**
 * @notice Fork tests on Optimism for the svZCHF price stack:
 *
 *           svZCHF vault  ->  ERC4626PriceCapAdapter  ->  AaveOracle
 *           CHF/USD relayed from mainnet -> OracleSinkPriceFeed -> (base leg of the adapter)
 *
 *         The vault is the live Frankencoin savings vault. The base leg runs over a mock sink so the
 *         CHF/USD number is deterministic — in prod it is fed by the mainnet relay.
 *
 *         The equivalence test at the bottom feeds the same ratio to Aave's unmodified
 *         `CLRatePriceCapAdapter` and requires the same price out, which pins that subclassing the
 *         base did not disturb the compose path. The ratio formula itself is asserted separately,
 *         against the vault.
 */

/// @notice A Chainlink-shaped ratio provider over the same previewRedeem read, standing in for the
///         `CLRatePriceCapAdapter` ratio leg in the equivalence test below. Test-only: the production
///         path reads the vault from inside `ERC4626PriceCapAdapter.getRatio()`.
contract MockRateProvider {
    IERC4626 public immutable vault;
    uint256 public immutable shareUnit;
    uint256 public immutable assetUnit;

    constructor(IERC4626 _vault) {
        vault = _vault;
        shareUnit = 10 ** _vault.decimals();
        assetUnit = 10 ** IERC20Metadata(_vault.asset()).decimals();
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function latestAnswer() external view returns (int256) {
        return int256(vault.previewRedeem(shareUnit) * 1e18 / assetUnit);
    }
}

contract ERC4626PriceCapAdapterTest is Test {
    using SafeCast for int256;
    using SafeCast for uint256;

    /// @dev Frankencoin savings vault on OP
    IERC4626 constant svZchf = IERC4626(0x20191448fcC813d34D0BDeae5Cdb1E89B3Fb7b8E);
    /// @dev ZCHF on OP — the vault's asset
    address constant ZCHF_OP = 0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553;
    /// @dev Mainnet ZCHF — the OracleSink price key, since the relay ships mainnet token addresses
    address constant ZCHF_MAINNET = 0xB58E61C3098d85632Df34EecfB899A1Ed80921cB;

    uint8 constant RATIO_DECIMALS = 18;
    uint8 constant USD_FEED_DECIMALS = 8;
    uint256 constant SINK_MAX_STALENESS = 2 days;

    uint48 constant SNAPSHOT_DELAY = 7 days;
    uint16 constant GROWTH_SVZCHF = 400; // 4.00%, placeholder until risk review sets it

    /// @dev 1.25 USD per CHF, in the mock sink's 6 decimals
    uint256 constant CHF_USD = 1.25e6;

    /// @dev Code-less on purpose. `PriceCapAdapterBase` only rejects address(0) and never calls the
    ///      ACL in its constructor; prod passes the instance's AccessManager, which implements
    ///      neither role check, so the cap setters are permanently unreachable. Asserted below.
    address aclManager;

    OracleSinkPriceFeed zchfUsd;
    MockOracleSink sink;
    ERC4626PriceCapAdapter adapter;

    uint104 snapshotRatio;
    uint48 snapshotTimestamp;

    function setUp() public {
        vm.createSelectFork(vm.envOr("OPTIMISM_RPC", string("https://mainnet.optimism.io")));
        aclManager = makeAddr("aclManager");

        // base leg: the relayed CHF/USD price, staleness-checked. isStableToken stays false — the snap
        // is to 1 USD, and a franc is not a dollar.
        sink = new MockOracleSink();
        sink.setPrice(ZCHF_MAINNET, CHF_USD, uint64(block.timestamp));
        zchfUsd = new OracleSinkPriceFeed(IOracleSink(address(sink)), ZCHF_MAINNET, IAaveV4PriceFeed(address(0)), USD_FEED_DECIMALS, SINK_MAX_STALENESS, false, "ZCHF / USD");

        // A snapshot 30 days back, just below the current ratio, so the ceiling sits above spot.
        // The discount must stay under what the growth rate allows over the window — 4%/yr across 30
        // days is only ~0.33% — or the ceiling lands below spot and every price here comes out capped.
        // The ratio is recomputed from the vault rather than read off an adapter, so the adapter's own
        // normalisation is never both the fixture and the thing under test.
        snapshotTimestamp = (block.timestamp - 30 days).toUint48();
        uint256 currentRatio = svZchf.previewRedeem(10 ** svZchf.decimals()) * 10 ** RATIO_DECIMALS / 10 ** IERC20Metadata(ZCHF_OP).decimals();
        snapshotRatio = (currentRatio * 999 / 1000).toUint104();
        adapter = _adapter(GROWTH_SVZCHF);
    }

    function _adapter(uint16 growthBps) internal returns (ERC4626PriceCapAdapter) {
        return new ERC4626PriceCapAdapter(_params(growthBps, address(svZchf)));
    }

    function _params(uint16 growthBps, address ratioProvider) internal view returns (IPriceCapAdapter.CapAdapterParams memory) {
        return IPriceCapAdapter.CapAdapterParams({ aclManager: IACLManager(aclManager), baseAggregatorAddress: address(zchfUsd), ratioProviderAddress: ratioProvider, pairDescription: "Capped svZCHF / ZCHF / USD", minimumSnapshotDelay: SNAPSHOT_DELAY, priceCapParams: IPriceCapAdapter.PriceCapUpdateParams({ snapshotRatio: snapshotRatio, snapshotTimestamp: snapshotTimestamp, maxYearlyRatioGrowthPercent: growthBps }) });
    }

    // ------------------------------------------------------------------ ratio

    /// @notice The ratio is previewRedeem of one whole share, normalised to 18 decimals.
    function test_getRatio_isPreviewRedeemOfOneShareAt18Decimals() public view {
        uint256 assets = svZchf.previewRedeem(adapter.SHARE_UNIT());
        uint256 expected = assets * 1e18 / adapter.ASSET_UNIT();

        assertEq(adapter.getRatio().toUint256(), expected, "ratio mismatch");
    }

    /// @notice ZCHF is 18 decimals, so the normalisation is a no-op here — pin that it stays one.
    function test_wiring() public view {
        assertEq(adapter.RATIO_PROVIDER(), address(svZchf));
        assertEq(adapter.ASSET(), ZCHF_OP, "base leg must price the vault's own asset");
        assertEq(adapter.SHARE_UNIT(), 10 ** svZchf.decimals());
        assertEq(adapter.ASSET_UNIT(), 1e18, "ZCHF is 18 decimals");
        assertEq(adapter.RATIO_DECIMALS(), RATIO_DECIMALS);
        assertEq(address(adapter.BASE_TO_USD_AGGREGATOR()), address(zchfUsd));
    }

    /// @notice A decimals check, not a yield check: the band is wide on the low side so an exit fee
    ///         priced in by previewRedeem cannot fail it.
    function test_getRatio_landsInASaneRange() public view {
        uint256 ratio = adapter.getRatio().toUint256();
        assertGt(ratio, 0.9e18, "ratio this far below par means a decimals slip");
        assertLt(ratio, 2e18, "ratio this far above par means a decimals slip");
    }

    // ------------------------------------------------------------------ price

    /// @notice AaveOracle requires exactly 8 decimals, which the base inherits from the base leg.
    function test_reportsEightDecimals() public view {
        assertEq(adapter.decimals(), USD_FEED_DECIMALS);
        assertEq(adapter.description(), "Capped svZCHF / ZCHF / USD");
    }

    /// @notice Uncapped: the price is the CHF/USD leg times the vault ratio.
    function test_pricesRatioTimesBaseWhenUncapped() public view {
        assertFalse(adapter.isCapped(), "ceiling should sit above spot with a 30-day snapshot");

        uint256 expected = zchfUsd.latestAnswer().toUint256() * adapter.getRatio().toUint256() / 10 ** RATIO_DECIMALS;
        assertEq(adapter.latestAnswer().toUint256(), expected, "price mismatch");

        // svZCHF is a franc, so ~1.25 USD at the mocked rate. Catches a decimals slip.
        assertGt(adapter.latestAnswer().toUint256(), 1e8);
        assertLt(adapter.latestAnswer().toUint256(), 5e8);
    }

    /// @notice With zero allowed growth the ceiling stays at the snapshot, which sits below spot, so
    ///         the price uses the capped ratio rather than the vault's own.
    function test_capsTheRatio() public {
        ERC4626PriceCapAdapter capped = _adapter(0);

        assertTrue(capped.isCapped(), "a zero growth rate must bind");

        uint256 expected = zchfUsd.latestAnswer().toUint256() * snapshotRatio / 10 ** RATIO_DECIMALS;
        assertEq(capped.latestAnswer().toUint256(), expected, "capped price should use the snapshot ratio");
        assertLt(capped.latestAnswer(), adapter.latestAnswer(), "capping can only lower the price");
    }

    /// @notice A stale relayed CHF/USD price reverts through the adapter instead of pricing. Aave's
    ///         base has no age check of its own; the revert in our base leg propagates.
    function test_revertsWhenRelayedBaseIsStale() public {
        vm.warp(block.timestamp + SINK_MAX_STALENESS + 1);

        vm.expectRevert(BaseAaveV4PriceFeed.StalePrice.selector);
        adapter.latestAnswer();
    }

    /// @notice A vault reporting a zero redemption rate prices at 0, which AaveOracle rejects with
    ///         `InvalidPrice` — Aave's base returns 0 on a non-positive ratio rather than reverting.
    function test_pricesZeroOnZeroRate() public {
        vm.mockCall(address(svZchf), abi.encodeWithSelector(IERC4626.previewRedeem.selector), abi.encode(uint256(0)));

        assertEq(adapter.latestAnswer(), 0, "a zero ratio must not produce a usable price");
    }

    /// @notice The cap is immutable in prod: the ACL manager implements neither role check, so
    ///         `setCapParameters` can never be called. Retuning means a fresh adapter and a repoint.
    function test_capSettersAreUnreachable() public {
        vm.expectRevert();
        adapter.setCapParameters(IPriceCapAdapter.PriceCapUpdateParams({ snapshotRatio: snapshotRatio, snapshotTimestamp: (block.timestamp - 8 days).toUint48(), maxYearlyRatioGrowthPercent: 1 }));
    }

    // ------------------------------------------------------------------ equivalence

    /// @notice Given the same ratio, the subclass must price exactly as Aave's own
    ///         `CLRatePriceCapAdapter` does — the shape every Veda vault on this instance already
    ///         runs. This is what shows the override changed only where the ratio comes from.
    function test_matchesCLRateAdapterGivenTheSameRatio() public {
        MockRateProvider rateProvider = new MockRateProvider(svZchf);
        CLRatePriceCapAdapter clRate = new CLRatePriceCapAdapter(_params(GROWTH_SVZCHF, address(rateProvider)));

        assertEq(clRate.RATIO_DECIMALS(), adapter.RATIO_DECIMALS(), "ratio precision must agree");
        assertEq(clRate.getRatio(), adapter.getRatio(), "ratio must agree");
        assertEq(clRate.latestAnswer(), adapter.latestAnswer(), "price must agree");
    }
}
