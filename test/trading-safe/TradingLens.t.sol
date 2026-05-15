// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TradingLens } from "../../src/trading-safe/TradingLens.sol";

/// @dev Minimal ERC20 with configurable decimals (so we can vary token decimals in tests).
contract TestToken is ERC20 {
    uint8 private immutable _decimals;
    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }
    function decimals() public view override returns (uint8) { return _decimals; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev ERC20 whose `decimals()` reverts — used to verify the lens's defensive fallback.
contract BrokenDecimalsToken is ERC20 {
    constructor() ERC20("Broken", "BRK") {}
    function decimals() public pure override returns (uint8) { revert("no decimals"); }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev ERC20 whose `balanceOf` reverts — used to verify the lens's defensive fallback
///      doesn't let a single paused / broken token brick the whole batch read.
contract BrokenBalanceToken is ERC20 {
    constructor() ERC20("BalanceBroken", "BBT") {}
    function balanceOf(address) public pure override returns (uint256) { revert("paused"); }
}

/// @dev Price provider stub: returns 6-decimal prices for configured tokens, reverts for
///      unknown ones — matches `IPriceProvider.price` semantics closely enough for the
///      lens's try/catch fallback to be exercised.
contract PriceProviderMock {
    mapping(address token => uint256 priceUsd) public priceUsd;
    error UnknownToken();

    function setPrice(address token, uint256 priceUsd_) external { priceUsd[token] = priceUsd_; }

    function price(address token) external view returns (uint256) {
        uint256 p = priceUsd[token];
        if (p == 0) revert UnknownToken();
        return p;
    }
}

contract TradingLensTest is Test {
    address public owner = makeAddr("owner");
    address public admin = makeAddr("admin");
    address public stranger = makeAddr("stranger");
    address public safe = makeAddr("safe");

    RoleRegistry public roleRegistry;
    PriceProviderMock public priceProvider;
    TradingLens public lens;

    TestToken public tokenA; // 18 decimals
    TestToken public tokenB; // 6 decimals
    TestToken public tokenC; // 8 decimals (e.g. WBTC-style)

    function setUp() public {
        // Role registry — needs a data provider address baked in immutably; for these tests
        // the lens doesn't call into the data provider, so we can pass any non-zero address.
        address dataProviderPlaceholder = makeAddr("dataProvider");
        address roleRegistryImpl = address(new RoleRegistry(dataProviderPlaceholder));
        roleRegistry = RoleRegistry(address(new UUPSProxy(
            roleRegistryImpl,
            abi.encodeWithSelector(RoleRegistry.initialize.selector, owner)
        )));

        priceProvider = new PriceProviderMock();

        address lensImpl = address(new TradingLens(address(priceProvider)));
        lens = TradingLens(address(new UUPSProxy(
            lensImpl,
            abi.encodeWithSelector(TradingLens.initialize.selector, address(roleRegistry))
        )));

        bytes32 adminRole = lens.TRADING_LENS_ADMIN_ROLE();
        vm.prank(owner);
        roleRegistry.grantRole(adminRole, admin);

        tokenA = new TestToken("Token A", "TKA", 18);
        tokenB = new TestToken("Token B", "TKB", 6);
        tokenC = new TestToken("Token C", "TKC", 8);
    }

    // ---- Admin: add / remove ----

    function test_addSupportedToken_admin() public {
        vm.prank(admin);
        lens.addSupportedToken(address(tokenA));

        assertTrue(lens.isSupportedToken(address(tokenA)));
        address[] memory list = lens.getSupportedTokens();
        assertEq(list.length, 1);
        assertEq(list[0], address(tokenA));
    }

    function test_addSupportedToken_revertsWhen_notAdmin() public {
        vm.expectRevert(TradingLens.OnlyAdmin.selector);
        vm.prank(stranger);
        lens.addSupportedToken(address(tokenA));
    }

    function test_addSupportedToken_revertsWhen_zeroAddress() public {
        vm.expectRevert(TradingLens.InvalidToken.selector);
        vm.prank(admin);
        lens.addSupportedToken(address(0));
    }

    function test_addSupportedToken_revertsWhen_alreadySupported() public {
        vm.startPrank(admin);
        lens.addSupportedToken(address(tokenA));
        vm.expectRevert(abi.encodeWithSelector(TradingLens.TokenAlreadySupported.selector, address(tokenA)));
        lens.addSupportedToken(address(tokenA));
        vm.stopPrank();
    }

    function test_removeSupportedToken_admin() public {
        vm.startPrank(admin);
        lens.addSupportedToken(address(tokenA));
        lens.removeSupportedToken(address(tokenA));
        vm.stopPrank();

        assertFalse(lens.isSupportedToken(address(tokenA)));
        assertEq(lens.getSupportedTokens().length, 0);
    }

    function test_removeSupportedToken_revertsWhen_notAdmin() public {
        vm.prank(admin);
        lens.addSupportedToken(address(tokenA));

        vm.expectRevert(TradingLens.OnlyAdmin.selector);
        vm.prank(stranger);
        lens.removeSupportedToken(address(tokenA));
    }

    function test_removeSupportedToken_revertsWhen_notSupported() public {
        vm.expectRevert(abi.encodeWithSelector(TradingLens.TokenNotSupported.selector, address(tokenA)));
        vm.prank(admin);
        lens.removeSupportedToken(address(tokenA));
    }

    // ---- Read surface ----

    function test_getSafeData_aggregates_acrossSupportedTokens() public {
        // tokenA (18 dec): 5 units @ $2 → $10
        // tokenB (6 dec): 100 units @ $1 → $100
        // tokenC (8 dec): 0.5 units @ $1000 → $500
        tokenA.mint(safe, 5e18);
        tokenB.mint(safe, 100e6);
        tokenC.mint(safe, 5e7); // 0.5 with 8 decimals

        priceProvider.setPrice(address(tokenA), 2e6);     // $2
        priceProvider.setPrice(address(tokenB), 1e6);     // $1
        priceProvider.setPrice(address(tokenC), 1000e6);  // $1000

        vm.startPrank(admin);
        lens.addSupportedToken(address(tokenA));
        lens.addSupportedToken(address(tokenB));
        lens.addSupportedToken(address(tokenC));
        vm.stopPrank();

        (TradingLens.TokenInfo[] memory tokens, uint256 totalValueUsd) = lens.getSafeData(safe);

        assertEq(tokens.length, 3);
        assertEq(tokens[0].token, address(tokenA));
        assertEq(tokens[0].balance, 5e18);
        assertEq(tokens[0].decimals, 18);
        assertEq(tokens[0].priceUsd, 2e6);
        assertEq(tokens[0].valueUsd, 10e6);

        assertEq(tokens[1].token, address(tokenB));
        assertEq(tokens[1].balance, 100e6);
        assertEq(tokens[1].decimals, 6);
        assertEq(tokens[1].priceUsd, 1e6);
        assertEq(tokens[1].valueUsd, 100e6);

        assertEq(tokens[2].token, address(tokenC));
        assertEq(tokens[2].balance, 5e7);
        assertEq(tokens[2].decimals, 8);
        assertEq(tokens[2].priceUsd, 1000e6);
        assertEq(tokens[2].valueUsd, 500e6);

        assertEq(totalValueUsd, 10e6 + 100e6 + 500e6, "header total matches row sum");
    }

    function test_getSafeData_zeroBalance_returnsZeroValue() public {
        priceProvider.setPrice(address(tokenA), 5e6);
        vm.prank(admin);
        lens.addSupportedToken(address(tokenA));

        (TradingLens.TokenInfo[] memory tokens, uint256 totalValueUsd) = lens.getSafeData(safe);
        assertEq(tokens.length, 1);
        assertEq(tokens[0].balance, 0);
        assertEq(tokens[0].priceUsd, 5e6);
        assertEq(tokens[0].valueUsd, 0);
        assertEq(totalValueUsd, 0);
    }

    function test_getSafeData_missingPrice_doesNotRevert_andContributesZero() public {
        tokenA.mint(safe, 1e18);
        tokenB.mint(safe, 50e6);

        // tokenA has a price; tokenB does not — the latter's `price()` call reverts.
        priceProvider.setPrice(address(tokenA), 7e6);

        vm.startPrank(admin);
        lens.addSupportedToken(address(tokenA));
        lens.addSupportedToken(address(tokenB));
        vm.stopPrank();

        (TradingLens.TokenInfo[] memory tokens, uint256 totalValueUsd) = lens.getSafeData(safe);

        assertEq(tokens.length, 2);
        // tokenA: priced
        assertEq(tokens[0].priceUsd, 7e6);
        assertEq(tokens[0].valueUsd, 7e6);
        // tokenB: balance recorded but price lookup failed → zero for both price and value.
        assertEq(tokens[1].balance, 50e6, "balance still recorded");
        assertEq(tokens[1].priceUsd, 0);
        assertEq(tokens[1].valueUsd, 0);

        assertEq(totalValueUsd, 7e6, "total excludes unpriced token");
    }

    function test_getSafeData_brokenBalance_doesNotRevert_andContributesZero() public {
        // A token whose balanceOf reverts (paused / self-destructed / broken) must not
        // brick the whole batch — its row gets balance=0 and value=0, every other token
        // still gets snapshotted correctly.
        BrokenBalanceToken broken = new BrokenBalanceToken();
        tokenA.mint(safe, 1e18);
        priceProvider.setPrice(address(tokenA), 5e6);
        priceProvider.setPrice(address(broken), 10e6);

        vm.startPrank(admin);
        lens.addSupportedToken(address(broken));
        lens.addSupportedToken(address(tokenA));
        vm.stopPrank();

        (TradingLens.TokenInfo[] memory tokens, uint256 totalValueUsd) = lens.getSafeData(safe);
        assertEq(tokens.length, 2);
        // Broken token: balanceOf reverted, fallback to zero — value is zero even with a price.
        assertEq(tokens[0].token, address(broken));
        assertEq(tokens[0].balance, 0);
        assertEq(tokens[0].priceUsd, 10e6);
        assertEq(tokens[0].valueUsd, 0);
        // Healthy token unaffected.
        assertEq(tokens[1].token, address(tokenA));
        assertEq(tokens[1].balance, 1e18);
        assertEq(tokens[1].valueUsd, 5e6);
        assertEq(totalValueUsd, 5e6);
    }

    function test_getSafeData_brokenDecimals_fallsBackTo18() public {
        BrokenDecimalsToken broken = new BrokenDecimalsToken();
        broken.mint(safe, 3e18);
        priceProvider.setPrice(address(broken), 4e6);

        vm.prank(admin);
        lens.addSupportedToken(address(broken));

        (TradingLens.TokenInfo[] memory tokens, uint256 totalValueUsd) = lens.getSafeData(safe);
        assertEq(tokens[0].decimals, 18, "fallback when decimals() reverts");
        assertEq(tokens[0].priceUsd, 4e6);
        assertEq(tokens[0].valueUsd, 12e6); // 3 * 4 = 12
        assertEq(totalValueUsd, 12e6);
    }

    function test_getSafeData_withRequestedTokens_bypassesSupportedSet() public {
        // tokenA isn't in the supported set, but caller can still query it ad-hoc.
        tokenA.mint(safe, 2e18);
        priceProvider.setPrice(address(tokenA), 3e6);

        address[] memory req = new address[](1);
        req[0] = address(tokenA);

        (TradingLens.TokenInfo[] memory tokens, uint256 totalValueUsd) = lens.getSafeData(safe, req);
        assertEq(tokens.length, 1);
        assertEq(tokens[0].token, address(tokenA));
        assertEq(tokens[0].balance, 2e18);
        assertEq(tokens[0].priceUsd, 3e6);
        assertEq(tokens[0].valueUsd, 6e6);
        assertEq(totalValueUsd, 6e6);
    }

    function test_getSafeData_emptySupportedSet_returnsEmpty() public view {
        (TradingLens.TokenInfo[] memory tokens, uint256 totalValueUsd) = lens.getSafeData(safe);
        assertEq(tokens.length, 0);
        assertEq(totalValueUsd, 0);
    }
}
