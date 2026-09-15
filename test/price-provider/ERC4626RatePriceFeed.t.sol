// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Test } from "forge-std/Test.sol";

import { IAaveV4PriceFeed } from "../../src/interfaces/IAaveV4PriceFeed.sol";
import { BaseAaveV4PriceFeed } from "../../src/oracle/BaseAaveV4PriceFeed.sol";
import { ERC4626RatePriceFeed } from "../../src/oracle/ERC4626RatePriceFeed.sol";

interface IAaveOracleLike {
    function getReservePrice(uint256 reserveId) external view returns (uint256);
}

/// @dev Minimal vault: fixed share and asset decimals, settable redemption rate per whole share.
contract MockVault {
    address public immutable asset;
    uint8 public immutable decimals;
    uint256 public rate;

    constructor(address _asset, uint8 _decimals, uint256 _rate) {
        asset = _asset;
        decimals = _decimals;
        rate = _rate;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * rate / (10 ** decimals);
    }
}

contract MockAsset is ERC20 {
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) ERC20("Asset", "AST") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

/// @dev Settable USD leg; `broken` makes it revert like a stale Chainlink leg would.
contract MockUsdFeed is IAaveV4PriceFeed {
    int256 public answer;
    bool public broken;

    constructor(int256 _answer) {
        answer = _answer;
    }

    function set(int256 _answer, bool _broken) external {
        answer = _answer;
        broken = _broken;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "STOCK / USD";
    }

    function latestAnswer() external view returns (int256) {
        require(!broken, BaseAaveV4PriceFeed.StalePrice());
        return answer;
    }
}

/// @notice Unit tests against mocks, then fork tests on Optimism against Backed's live wSPYx wrapper.
contract ERC4626RatePriceFeedTest is Test {
    using SafeCast for int256;

    uint8 constant FEED_DECIMALS = 8;

    MockUsdFeed usd;
    MockVault vault;
    ERC4626RatePriceFeed feed;

    function setUp() public {
        usd = new MockUsdFeed(760e8);
        vault = new MockVault(address(new MockAsset(18)), 18, 1.0057e18);
        feed = new ERC4626RatePriceFeed(IERC4626(address(vault)), usd, FEED_DECIMALS, "wSPYx / USD");
    }

    /// @notice price = rate x underlying, normalized to feed decimals. 1.0057 x 760 = 764.332
    function test_latestAnswer_isRateTimesUnderlying() public view {
        assertEq(feed.latestAnswer(), 764.332e8);
        assertEq(feed.rateDecimals(), 18);
        assertEq(feed.underlyingDecimals(), 8);
        assertEq(address(feed.vault()), address(vault));
        assertEq(feed.decimals(), FEED_DECIMALS);
        assertEq(feed.description(), "wSPYx / USD");
    }

    /// @notice The rate is read live, so a change shows on the next read with no caching.
    function test_rateChange_reflectsImmediately() public {
        vault.setRate(1.1e18);
        assertEq(feed.latestAnswer(), 836e8);
        vault.setRate(1e18);
        assertEq(feed.latestAnswer(), 760e8);
    }

    /// @notice Rate decimals follow the vault's asset, not its share, e.g. a 6-decimal underlying.
    function test_rateDecimals_followAsset() public {
        MockVault v6 = new MockVault(address(new MockAsset(6)), 18, 1.5e6);
        ERC4626RatePriceFeed f6 = new ERC4626RatePriceFeed(IERC4626(address(v6)), usd, FEED_DECIMALS, "v6 / USD");
        assertEq(f6.rateDecimals(), 6);
        assertEq(f6.latestAnswer(), 1140e8);
    }

    function test_reverts_whenUnderlyingStale() public {
        usd.set(760e8, true);
        vm.expectRevert(BaseAaveV4PriceFeed.StalePrice.selector);
        feed.latestAnswer();
    }

    function test_reverts_whenUnderlyingNotPositive() public {
        usd.set(0, false);
        vm.expectRevert(BaseAaveV4PriceFeed.InvalidPrice.selector);
        feed.latestAnswer();
    }

    function test_reverts_whenRateZero() public {
        vault.setRate(0);
        vm.expectRevert(BaseAaveV4PriceFeed.InvalidPrice.selector);
        feed.latestAnswer();
    }

    function test_constructor_requiresUnderlyingFeed() public {
        vm.expectRevert(ERC4626RatePriceFeed.MissingUnderlyingFeed.selector);
        new ERC4626RatePriceFeed(IERC4626(address(vault)), IAaveV4PriceFeed(address(0)), FEED_DECIMALS, "wSPYx / USD");
    }
}

/// @notice Optimism fork: Backed's wSPYx wrapper priced over the live SPY/USD leg that the current
///         iwSPYx reserve already uses, compared against the oracle's current iwSPYx price.
contract ERC4626RatePriceFeedForkTest is Test {
    using SafeCast for int256;

    address constant WSPYX = 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540;
    address constant SPY_USD_LEG = 0xf41eBb842D8e2e2ea818BC6f27497fEF97FAe68F;
    address constant AAVE_ORACLE = 0xe8cbd37210bF1E29436dAe183d7b9fe45E886fA8;
    uint256 constant IWSPYX_RESERVE_ID = 19;

    ERC4626RatePriceFeed feed;

    function setUp() public {
        vm.createSelectFork(vm.envOr("OPTIMISM_RPC", string("https://mainnet.optimism.io")));
        feed = new ERC4626RatePriceFeed(IERC4626(WSPYX), IAaveV4PriceFeed(SPY_USD_LEG), 8, "wSPYx / USD");
    }

    function test_fork_matchesManualCompose() public view {
        uint256 rate = IERC4626(WSPYX).convertToAssets(1e18);
        uint256 spy = IAaveV4PriceFeed(SPY_USD_LEG).latestAnswer().toUint256();
        assertEq(feed.latestAnswer().toUint256(), rate * spy / 1e18);
        assertEq(feed.rateDecimals(), 18);
    }

    /// @notice The wrapper rate is identical on both chains, so the local read must land within 0.1% of
    ///         the relayed price the live iwSPYx reserve carries today.
    function test_fork_withinTenBpsOfLiveMirrorPrice() public view {
        uint256 live = IAaveOracleLike(AAVE_ORACLE).getReservePrice(IWSPYX_RESERVE_ID);
        assertApproxEqRel(feed.latestAnswer().toUint256(), live, 0.001e18);
    }
}
