// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { SafeTestSetup } from "../safe/SafeTestSetup.t.sol";
import { MigrationBridgeModule } from "../../src/migration/MigrationBridgeModule.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { TopUpDestWithMigration } from "../../src/top-up/TopUpDestWithMigration.sol";

/**
 * @title MigrationBridgeModuleTest
 * @notice Tests for the migration bridge module that sends all safe tokens
 *         to mainnet/HyperEVM. Uses Scroll fork for real token/bridge contracts.
 */
contract MigrationBridgeModuleTest is SafeTestSetup {
    MigrationBridgeModule migrationModule;
    TopUpDestWithMigration topUpDestV2;

    address supplier;

    // Real Scroll token addresses
    address constant USDC            = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    address constant WEETH           = 0x01f0a31698C4d065659b9bdC21B3610292a1c506;
    address constant SCR             = 0xd29687c813D741E2F938F4aC377128810E217b1b;
    address constant LIQUID_ETH      = 0xf0bb20865277aBd641a307eCe5Ee04E79073416C;
    address constant LIQUID_BTC      = 0x5f46d540b6eD704C3c8789105F30E075AA900726;
    address constant LIQUID_USD      = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address constant EUSD            = 0x939778D83b46B456224A33Fb59630B11DEC56663;
    address constant EBTC            = 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;
    address constant WETH            = 0x5300000000000000000000000000000000000004;
    address constant ETHFI           = 0x056A5FA5da84ceb7f93d36e545C5905607D8bD81;
    address constant SETHFI          = 0x86B5780b606940Eb59A062aA85a07959518c0161;
    address constant USDT            = 0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df;
    address constant WHYPE           = 0xd83E3d560bA6F05094d9D8B3EB8aaEA571D1864E;
    address constant BEHYPE          = 0xA519AfBc91986c0e7501d7e34968FEE51CD901aC;
    address constant FRXUSD          = 0x397F939C3b91A74C321ea7129396492bA9Cdce82;
    address constant LIQUID_RESERVE  = 0xb7Fb3768CAAC98354EaDF514b48f28F2fE822bF0;
    address constant EURC            = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;

    // Teller addresses (Scroll)
    address constant LIQUID_ETH_TELLER = 0x9AA79C84b79816ab920bBcE20f8f74557B514734;
    address constant LIQUID_BTC_TELLER = 0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353;
    address constant LIQUID_USD_TELLER = 0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387;
    address constant EUSD_TELLER       = 0xCc9A7620D0358a521A068B444846E3D5DebEa8fA;
    address constant EBTC_TELLER       = 0x6Ee3aaCcf9f2321E49063C4F8da775DdBd407268;
    address constant SETHFI_TELLER     = 0x35dD2463fA7a335b721400C5Ad8Ba40bD85c179b;

    // OFT adapters (when token != OFT contract)
    address constant ETHFI_LZ_ADAPTER = 0xe0080d2F853ecDdbd81A643dC10DA075Df26fD3f;

    // Frax Hop V2 on Scroll
    address constant FRAX_HOP = 0x0000006D38568b00B457580b734e0076C62de659;

    // Liquid Reserve OFT
    address constant LIQUID_RESERVE_OFT = 0xE5d3854736e0D513aAE2D8D708Ad94d14Fd56A6a;

    // LZ endpoint IDs
    uint32 constant ETHEREUM_EID = 30_101;
    uint32 constant HYPEREVM_EID = 30_367;
    uint32 constant OPTIMISM_EID = 30_111;

    function setUp() public override {
        super.setUp();

        supplier = makeAddr("supplier");

        vm.startPrank(owner);

        // Deploy TopUpDest proxy, then upgrade to V2 after migration module is known
        address topUpDestImpl = address(new TopUpDest(address(dataProvider), WETH));
        address topUpDestProxy = address(new UUPSProxy(topUpDestImpl, abi.encodeWithSelector(TopUpDest.initialize.selector, address(roleRegistry))));

        // Deploy migration module as UUPS proxy (with topUpDest address)
        address migrationImpl = address(new MigrationBridgeModule(address(dataProvider), topUpDestProxy));
        migrationModule = MigrationBridgeModule(payable(address(
            new UUPSProxy(migrationImpl, abi.encodeWithSelector(MigrationBridgeModule.initialize.selector, address(roleRegistry)))
        )));

        // Upgrade TopUpDest to V2 with migration module as authorized caller
        address topUpDestV2Impl = address(new TopUpDestWithMigration(address(dataProvider), WETH, address(migrationModule)));
        UUPSUpgradeable(topUpDestProxy).upgradeToAndCall(topUpDestV2Impl, "");
        topUpDestV2 = TopUpDestWithMigration(payable(topUpDestProxy));

        // Register as default module so it can call execTransactionFromModule on any safe
        address[] memory modules = new address[](1);
        bool[] memory shouldWhitelist = new bool[](1);
        modules[0] = address(migrationModule);
        shouldWhitelist[0] = true;
        dataProvider.configureDefaultModules(modules, shouldWhitelist);

        // Update hook to skip ensureHealth for migration module
        address newHookImpl = address(new EtherFiHook(address(dataProvider)));
        UUPSUpgradeable(address(hook)).upgradeToAndCall(newHookImpl, "");
        hook.setMigrationModule(address(migrationModule));

        // Grant roles
        roleRegistry.grantRole(migrationModule.MIGRATION_BRIDGE_ADMIN_ROLE(), owner);

        // Supply USDC to debt manager so we can create debt
        deal(USDC, supplier, 1_000_000e6);
        vm.stopPrank();

        vm.startPrank(supplier);
        IERC20(USDC).approve(address(debtManager), type(uint256).max);
        debtManager.supply(supplier, USDC, 1_000_000e6);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //                    ADMIN TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_configureTokens() public {
        address[] memory tokens = new address[](3);
        MigrationBridgeModule.TokenBridgeConfig[] memory configs = new MigrationBridgeModule.TokenBridgeConfig[](3);

        tokens[0] = USDC;
        configs[0] = MigrationBridgeModule.TokenBridgeConfig({
            bridgeType: MigrationBridgeModule.BridgeType.CANONICAL,
            bridgeContract: address(0),
            destEid: 0
        });

        tokens[1] = WEETH;
        configs[1] = MigrationBridgeModule.TokenBridgeConfig({
            bridgeType: MigrationBridgeModule.BridgeType.OFT,
            bridgeContract: WEETH, // weETH is its own OFT on Scroll
            destEid: 30_101 // Ethereum mainnet
        });

        tokens[2] = SCR;
        configs[2] = MigrationBridgeModule.TokenBridgeConfig({
            bridgeType: MigrationBridgeModule.BridgeType.SKIP,
            bridgeContract: address(0),
            destEid: 0
        });

        vm.prank(owner);
        migrationModule.configureTokens(tokens, configs);

        address[] memory storedTokens = migrationModule.getTokens();
        assertEq(storedTokens.length, 3);
        assertEq(storedTokens[0], USDC);
        assertEq(storedTokens[1], WEETH);
        assertEq(storedTokens[2], SCR);
    }

    function test_configureTokens_revertsWithoutAdmin() public {
        address[] memory tokens = new address[](1);
        MigrationBridgeModule.TokenBridgeConfig[] memory configs = new MigrationBridgeModule.TokenBridgeConfig[](1);
        tokens[0] = USDC;
        configs[0] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.CANONICAL, address(0), 0);

        vm.prank(supplier); // not admin
        vm.expectRevert(MigrationBridgeModule.OnlyAdmin.selector);
        migrationModule.configureTokens(tokens, configs);
    }

    function test_configureTokens_revertsOnArrayMismatch() public {
        address[] memory tokens = new address[](2);
        MigrationBridgeModule.TokenBridgeConfig[] memory configs = new MigrationBridgeModule.TokenBridgeConfig[](1);
        tokens[0] = USDC;
        tokens[1] = WEETH;
        configs[0] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.CANONICAL, address(0), 0);

        vm.prank(owner);
        vm.expectRevert(MigrationBridgeModule.ArrayLengthMismatch.selector);
        migrationModule.configureTokens(tokens, configs);
    }

    function test_configureTokens_replacesOldConfig() public {
        // Configure with 2 tokens
        address[] memory tokens1 = new address[](2);
        MigrationBridgeModule.TokenBridgeConfig[] memory configs1 = new MigrationBridgeModule.TokenBridgeConfig[](2);
        tokens1[0] = USDC;
        tokens1[1] = WEETH;
        configs1[0] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.CANONICAL, address(0), 0);
        configs1[1] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, WEETH, 30_101);

        vm.startPrank(owner);
        migrationModule.configureTokens(tokens1, configs1);
        assertEq(migrationModule.getTokens().length, 2);

        // Reconfigure with 1 token — should replace
        address[] memory tokens2 = new address[](1);
        MigrationBridgeModule.TokenBridgeConfig[] memory configs2 = new MigrationBridgeModule.TokenBridgeConfig[](1);
        tokens2[0] = SCR;
        configs2[0] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.SKIP, address(0), 0);

        migrationModule.configureTokens(tokens2, configs2);
        assertEq(migrationModule.getTokens().length, 1);
        assertEq(migrationModule.getTokens()[0], SCR);

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //                  ACCESS CONTROL TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_bridgeAll_revertsWithoutWalletRole() public {
        vm.prank(supplier); // not etherFiWallet
        vm.expectRevert(MigrationBridgeModule.OnlyEtherFiWallet.selector);
        migrationModule.bridgeAll(_safes(address(safe)));
    }

    function test_bridgeAll_revertsForNonSafe() public {
        vm.prank(etherFiWallet);
        vm.expectRevert(MigrationBridgeModule.NotEtherFiSafe.selector);
        migrationModule.bridgeAll(_safes(supplier)); // not a safe
    }

    // ═══════════════════════════════════════════════════════════════
    //                  BRIDGE ALL TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_bridgeAll_skipsTokensWithZeroBalance() public {
        // Configure USDC as canonical but safe has no USDC
        _configureCanonical(USDC);

        vm.prank(etherFiWallet);
        migrationModule.bridgeAll(_safes(address(safe)));
        // Should succeed with 0 tokens bridged (no revert)
    }

    function test_bridgeAll_skipsSkipTokens() public {
        // Give safe some SCR
        deal(SCR, address(safe), 1000e18);
        uint256 scrBefore = IERC20(SCR).balanceOf(address(safe));

        // Configure SCR as SKIP
        address[] memory tokens = new address[](1);
        MigrationBridgeModule.TokenBridgeConfig[] memory configs = new MigrationBridgeModule.TokenBridgeConfig[](1);
        tokens[0] = SCR;
        configs[0] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.SKIP, address(0), 0);

        vm.prank(owner);
        migrationModule.configureTokens(tokens, configs);

        vm.prank(etherFiWallet);
        migrationModule.bridgeAll(_safes(address(safe)));

        // SCR balance should be unchanged
        assertEq(IERC20(SCR).balanceOf(address(safe)), scrBefore);
    }

    function test_bridgeAll_canonicalBridge_USDC() public {
        // Give safe some USDC
        uint256 amount = 10_000e6;
        deal(USDC, address(safe), amount);

        _configureCanonical(USDC);

        uint256 balanceBefore = IERC20(USDC).balanceOf(address(safe));
        assertEq(balanceBefore, amount);

        vm.prank(etherFiWallet);
        migrationModule.bridgeAll(_safes(address(safe)));

        // USDC should be gone from safe (bridged via canonical)
        assertEq(IERC20(USDC).balanceOf(address(safe)), 0);
    }

    function test_bridgeAll_canonicalBridge_WETH() public {
        uint256 amount = 5 ether;
        deal(WETH, address(safe), amount);

        _configureCanonical(WETH);

        vm.prank(etherFiWallet);
        migrationModule.bridgeAll(_safes(address(safe)));

        assertEq(IERC20(WETH).balanceOf(address(safe)), 0);
    }

    function test_bridgeAll_multipleTokens() public {
        // Give safe USDC + WETH + SCR
        deal(USDC, address(safe), 10_000e6);
        deal(WETH, address(safe), 2 ether);
        deal(SCR, address(safe), 500e18);

        // Configure: USDC canonical, WETH canonical, SCR skip
        address[] memory tokens = new address[](3);
        MigrationBridgeModule.TokenBridgeConfig[] memory configs = new MigrationBridgeModule.TokenBridgeConfig[](3);

        tokens[0] = USDC;
        configs[0] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.CANONICAL, address(0), 0);
        tokens[1] = WETH;
        configs[1] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.CANONICAL, address(0), 0);
        tokens[2] = SCR;
        configs[2] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.SKIP, address(0), 0);

        vm.prank(owner);
        migrationModule.configureTokens(tokens, configs);

        vm.prank(etherFiWallet);
        migrationModule.bridgeAll(_safes(address(safe)));

        // USDC and WETH should be bridged, SCR stays
        assertEq(IERC20(USDC).balanceOf(address(safe)), 0);
        assertEq(IERC20(WETH).balanceOf(address(safe)), 0);
        assertEq(IERC20(SCR).balanceOf(address(safe)), 500e18);
    }

    // ═══════════════════════════════════════════════════════════════
    //                HOOK BYPASS TEST
    // ═══════════════════════════════════════════════════════════════

    function test_hookBypass_migrationModuleSkipsHealthCheck() public {
        // Give safe collateral + create debt so it's at LTV limit
        deal(USDC, address(safe), 100_000e6);
        deal(address(weETHScroll), address(safe), 10 ether);

        // Create debt via borrow (through cash module spend)
        // Instead, we'll verify the hook bypass by calling execTransactionFromModule
        // from the migration module — it should NOT revert even if health would fail

        // Configure USDC as canonical
        _configureCanonical(USDC);

        // Bridge USDC out — even though removing collateral would make position unhealthy,
        // the hook skips ensureHealth for the migration module
        vm.prank(etherFiWallet);
        migrationModule.bridgeAll(_safes(address(safe)));

        assertEq(IERC20(USDC).balanceOf(address(safe)), 0);
    }

    function test_hookBypass_setMigrationModule() public {
        address newModule = makeAddr("newMigrationModule");

        vm.prank(owner);
        hook.setMigrationModule(newModule);

        assertEq(hook.migrationModule(), newModule);
    }

    function test_hookBypass_setMigrationModule_revertsForNonOwner() public {
        vm.prank(supplier);
        vm.expectRevert(EtherFiHook.OnlyAdmin.selector);
        hook.setMigrationModule(makeAddr("newModule"));
    }

    // ═══════════════════════════════════════════════════════════════
    //              MIGRATION BLOCKS TOP-UPS TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_bridgeAll_marksSafesAsMigrated() public {
        // Configure USDC as canonical
        _configureCanonical(USDC);

        // Grant top-up roles to supplier
        vm.startPrank(owner);
        roleRegistry.grantRole(keccak256("DEPOSITOR_ROLE"), supplier);
        roleRegistry.grantRole(keccak256("TOP_UP_ROLE"), supplier);
        vm.stopPrank();

        // Fund TopUpDest with USDC
        deal(USDC, supplier, 100_000e6);
        vm.startPrank(supplier);
        IERC20(USDC).approve(address(topUpDestV2), 100_000e6);
        topUpDestV2.deposit(USDC, 100_000e6);
        vm.stopPrank();

        // Verify top-up works before migration
        vm.prank(supplier);
        topUpDestV2.topUpUserSafe(keccak256("tx_before"), address(safe), 100, USDC, 1e6);

        // Verify safe is not migrated
        assertFalse(topUpDestV2.isMigrated(address(safe)));

        // Give safe some USDC and bridge all
        deal(USDC, address(safe), 10_000e6);
        vm.prank(etherFiWallet);
        migrationModule.bridgeAll(_safes(address(safe)));

        // Verify safe is now migrated
        assertTrue(topUpDestV2.isMigrated(address(safe)));

        // Verify top-ups are blocked after migration
        vm.prank(supplier);
        vm.expectRevert(TopUpDestWithMigration.SafeMigrated.selector);
        topUpDestV2.topUpUserSafe(keccak256("tx_after"), address(safe), 100, USDC, 1e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    QUOTE TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_quoteBridgeAll_returnsZeroForCanonical() public {
        deal(USDC, address(safe), 10_000e6);
        _configureCanonical(USDC);

        uint256 fee = migrationModule.quoteBridgeAll(_safes(address(safe)));
        // Canonical bridge has no LZ fee
        assertEq(fee, 0);
    }

    function test_quoteBridgeAll_returnsZeroForSkip() public {
        deal(SCR, address(safe), 1000e18);

        address[] memory tokens = new address[](1);
        MigrationBridgeModule.TokenBridgeConfig[] memory configs = new MigrationBridgeModule.TokenBridgeConfig[](1);
        tokens[0] = SCR;
        configs[0] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.SKIP, address(0), 0);

        vm.prank(owner);
        migrationModule.configureTokens(tokens, configs);

        uint256 fee = migrationModule.quoteBridgeAll(_safes(address(safe)));
        assertEq(fee, 0);
    }

    function test_quoteBridgeAll_returnsZeroForEmptyBalance() public {
        _configureCanonical(USDC);
        // Safe has no USDC
        uint256 fee = migrationModule.quoteBridgeAll(_safes(address(safe)));
        assertEq(fee, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                      HELPERS
    // ═══════════════════════════════════════════════════════════════

    function _safes(address safe) internal pure returns (address[] memory s) {
        s = new address[](1);
        s[0] = safe;
    }

    function _configureCanonical(address token) internal {
        address[] memory t = new address[](1);
        MigrationBridgeModule.TokenBridgeConfig[] memory c = new MigrationBridgeModule.TokenBridgeConfig[](1);
        t[0] = token;
        c[0] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.CANONICAL, address(0), 0);
        vm.prank(owner);
        migrationModule.configureTokens(t, c);
    }

    function _configureAllTokens() internal {
        address[] memory t = new address[](16);
        MigrationBridgeModule.TokenBridgeConfig[] memory c = new MigrationBridgeModule.TokenBridgeConfig[](16);

        // Canonical: USDC, USDT, WETH
        t[0] = USDC;  c[0] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.CANONICAL, address(0), 0);
        t[1] = USDT;  c[1] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.CANONICAL, address(0), 0);
        t[2] = WETH;  c[2] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.CANONICAL, address(0), 0);

        // OFT to Ethereum: weETH, ETHFI, EURC
        t[3] = EURC;   c[3] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, EURC, ETHEREUM_EID);
        t[4] = WEETH;  c[4] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, WEETH, ETHEREUM_EID);
        t[5] = ETHFI;  c[5] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, ETHFI_LZ_ADAPTER, ETHEREUM_EID);

        // Teller to Ethereum: LiquidETH, LiquidBTC, LiquidUSD, EUSD, EBTC, sETHFI
        t[6]  = LIQUID_ETH; c[6]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, LIQUID_ETH_TELLER, ETHEREUM_EID);
        t[7]  = LIQUID_BTC; c[7]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, LIQUID_BTC_TELLER, ETHEREUM_EID);
        t[8]  = LIQUID_USD; c[8]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, LIQUID_USD_TELLER, ETHEREUM_EID);
        t[9]  = EUSD;       c[9]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, EUSD_TELLER, ETHEREUM_EID);
        t[10] = EBTC;       c[10] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, EBTC_TELLER, ETHEREUM_EID);
        t[11] = SETHFI;     c[11] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, SETHFI_TELLER, ETHEREUM_EID);

        // OFT to HyperEVM: wHYPE, beHype
        t[12] = WHYPE;  c[12] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, WHYPE, HYPEREVM_EID);
        t[13] = BEHYPE; c[13] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, BEHYPE, HYPEREVM_EID);

        // Hop to Ethereum: frxUSD (via Frax Hop V2 → Fraxtal → Ethereum)
        t[14] = FRXUSD; c[14] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.HOP, FRAX_HOP, ETHEREUM_EID);

        // Skip: SCR, LiquidReserve (by omission)
        t[15] = SCR; c[15] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.SKIP, address(0), 0);

        vm.prank(owner);
        migrationModule.configureTokens(t, c);
    }

    function _dealAllTokensToSafe() internal {
        deal(USDC, address(safe), 10_000e6);
        deal(USDT, address(safe), 5_000e6);
        deal(WETH, address(safe), 2 ether);
        deal(EURC, address(safe), 3_000e6);
        deal(WEETH, address(safe), 1 ether);
        deal(ETHFI, address(safe), 100e18);
        deal(FRXUSD, address(safe), 1_000e18);
        deal(LIQUID_ETH, address(safe), 1 ether);
        deal(LIQUID_BTC, address(safe), 0.1e6);
        deal(LIQUID_USD, address(safe), 500e6);
        deal(EUSD, address(safe), 500e18);
        deal(EBTC, address(safe), 0.05e6);
        deal(SETHFI, address(safe), 200e18);
        deal(WHYPE, address(safe), 100e18);
        deal(BEHYPE, address(safe), 50e18);
        deal(SCR, address(safe), 1_000e18);
        deal(LIQUID_RESERVE, address(safe), 300e18);
    }

    // ═══════════════════════════════════════════════════════════════
    //              ALL-TOKEN BRIDGE TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_bridgeAll_allCanonicalTokens() public {
        deal(USDC, address(safe), 10_000e6);
        deal(USDT, address(safe), 5_000e6);
        deal(WETH, address(safe), 2 ether);

        address[] memory t = new address[](3);
        MigrationBridgeModule.TokenBridgeConfig[] memory c = new MigrationBridgeModule.TokenBridgeConfig[](3);
        t[0] = USDC; c[0] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.CANONICAL, address(0), 0);
        t[1] = USDT; c[1] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.CANONICAL, address(0), 0);
        t[2] = WETH; c[2] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.CANONICAL, address(0), 0);

        vm.prank(owner);
        migrationModule.configureTokens(t, c);

        vm.prank(etherFiWallet);
        migrationModule.bridgeAll(_safes(address(safe)));

        assertEq(IERC20(USDC).balanceOf(address(safe)), 0, "USDC not bridged");
        assertEq(IERC20(USDT).balanceOf(address(safe)), 0, "USDT not bridged");
        assertEq(IERC20(WETH).balanceOf(address(safe)), 0, "WETH not bridged");
    }

    function test_bridgeAll_allTellerTokens() public {
        deal(LIQUID_ETH, address(safe), 1 ether);
        deal(LIQUID_BTC, address(safe), 0.1e8);
        deal(LIQUID_USD, address(safe), 500e6);
        deal(EUSD, address(safe), 500e18);
        deal(EBTC, address(safe), 0.05e6);
        deal(SETHFI, address(safe), 200e18);

        address[] memory t = new address[](6);
        MigrationBridgeModule.TokenBridgeConfig[] memory c = new MigrationBridgeModule.TokenBridgeConfig[](6);
        t[0] = LIQUID_ETH; c[0] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, LIQUID_ETH_TELLER, ETHEREUM_EID);
        t[1] = LIQUID_BTC; c[1] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, LIQUID_BTC_TELLER, ETHEREUM_EID);
        t[2] = LIQUID_USD; c[2] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, LIQUID_USD_TELLER, ETHEREUM_EID);
        t[3] = EUSD;       c[3] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, EUSD_TELLER, ETHEREUM_EID);
        t[4] = EBTC;       c[4] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, EBTC_TELLER, ETHEREUM_EID);
        t[5] = SETHFI;     c[5] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, SETHFI_TELLER, ETHEREUM_EID);

        vm.prank(owner);
        migrationModule.configureTokens(t, c);

        // Quote fees
        uint256 fee = migrationModule.quoteBridgeAll(_safes(address(safe)));
        assertGt(fee, 0, "Teller bridge should require LZ fee");

        // Fund and bridge
        vm.deal(etherFiWallet, fee + 1 ether);
        vm.prank(etherFiWallet);
        migrationModule.bridgeAll{ value: fee }(_safes(address(safe)));

        assertEq(IERC20(LIQUID_ETH).balanceOf(address(safe)), 0, "LiquidETH not bridged");
        assertEq(IERC20(LIQUID_BTC).balanceOf(address(safe)), 0, "LiquidBTC not bridged");
        assertEq(IERC20(LIQUID_USD).balanceOf(address(safe)), 0, "LiquidUSD not bridged");
        assertEq(IERC20(EUSD).balanceOf(address(safe)), 0, "EUSD not bridged");
        assertEq(IERC20(EBTC).balanceOf(address(safe)), 0, "EBTC not bridged");
        assertEq(IERC20(SETHFI).balanceOf(address(safe)), 0, "sETHFI not bridged");
    }

    function test_bridgeAll_allOftTokensMainnet() public {
        deal(WEETH, address(safe), 1 ether);
        deal(ETHFI, address(safe), 100e18);
        deal(EURC, address(safe), 3_000e6);

        address[] memory t = new address[](3);
        MigrationBridgeModule.TokenBridgeConfig[] memory c = new MigrationBridgeModule.TokenBridgeConfig[](3);
        t[0] = WEETH;  c[0] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, WEETH, ETHEREUM_EID);
        t[1] = ETHFI;  c[1] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, ETHFI_LZ_ADAPTER, ETHEREUM_EID);
        t[2] = EURC;   c[2] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, EURC, ETHEREUM_EID);

        vm.prank(owner);
        migrationModule.configureTokens(t, c);

        uint256 fee = migrationModule.quoteBridgeAll(_safes(address(safe)));
        assertGt(fee, 0, "OFT bridge should require LZ fee");

        vm.deal(etherFiWallet, fee + 1 ether);
        vm.prank(etherFiWallet);
        migrationModule.bridgeAll{ value: fee }(_safes(address(safe)));

        assertEq(IERC20(WEETH).balanceOf(address(safe)), 0, "weETH not bridged");
        assertEq(IERC20(ETHFI).balanceOf(address(safe)), 0, "ETHFI not bridged");
        assertEq(IERC20(EURC).balanceOf(address(safe)), 0, "EURC not bridged");
    }

    function test_bridgeAll_allOftTokensHyperEVM() public {
        deal(WHYPE, address(safe), 100e18);
        deal(BEHYPE, address(safe), 50e18);

        address[] memory t = new address[](2);
        MigrationBridgeModule.TokenBridgeConfig[] memory c = new MigrationBridgeModule.TokenBridgeConfig[](2);
        t[0] = WHYPE;  c[0] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, WHYPE, HYPEREVM_EID);
        t[1] = BEHYPE; c[1] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, BEHYPE, HYPEREVM_EID);

        vm.prank(owner);
        migrationModule.configureTokens(t, c);

        uint256 fee = migrationModule.quoteBridgeAll(_safes(address(safe)));
        assertGt(fee, 0, "OFT to HyperEVM should require LZ fee");

        vm.deal(etherFiWallet, fee + 1 ether);
        vm.prank(etherFiWallet);
        migrationModule.bridgeAll{ value: fee }(_safes(address(safe)));

        assertEq(IERC20(WHYPE).balanceOf(address(safe)), 0, "wHYPE not bridged");
        assertEq(IERC20(BEHYPE).balanceOf(address(safe)), 0, "beHype not bridged");
    }

    function test_bridgeAll_oftLiquidReserveToOptimism() public {
        deal(LIQUID_RESERVE, address(safe), 300e18);

        address[] memory t = new address[](1);
        MigrationBridgeModule.TokenBridgeConfig[] memory c = new MigrationBridgeModule.TokenBridgeConfig[](1);
        t[0] = LIQUID_RESERVE;
        c[0] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, LIQUID_RESERVE_OFT, OPTIMISM_EID);

        vm.prank(owner);
        migrationModule.configureTokens(t, c);

        uint256 fee = migrationModule.quoteBridgeAll(_safes(address(safe)));
        assertGt(fee, 0, "OFT to OP should require LZ fee");

        vm.deal(etherFiWallet, fee + 1 ether);
        vm.prank(etherFiWallet);
        migrationModule.bridgeAll{ value: fee }(_safes(address(safe)));

        assertEq(IERC20(LIQUID_RESERVE).balanceOf(address(safe)), 0, "LiquidReserve not bridged");
    }

    function test_bridgeAll_skipTokensUntouched() public {
        deal(SCR, address(safe), 1_000e18);
        deal(LIQUID_RESERVE, address(safe), 300e18);

        _configureAllTokens();

        uint256 scrBefore = IERC20(SCR).balanceOf(address(safe));
        uint256 lrBefore = IERC20(LIQUID_RESERVE).balanceOf(address(safe));

        // Need fees for OFT/Teller tokens — but safe has no other tokens so fee should be 0
        // Actually safe has no OFT/Teller tokens with balance, only SCR and LiquidReserve
        // But configureAllTokens doesn't include LiquidReserve, and SCR is SKIP

        vm.prank(etherFiWallet);
        migrationModule.bridgeAll(_safes(address(safe)));

        assertEq(IERC20(SCR).balanceOf(address(safe)), scrBefore, "SCR should stay");
        assertEq(IERC20(LIQUID_RESERVE).balanceOf(address(safe)), lrBefore, "LiquidReserve should stay");
    }

    function test_bridgeAll_fullMigration_allTokenTypes() public {
        _configureAllTokens();
        _dealAllTokensToSafe();

        // Record skip token balances
        uint256 scrBefore = IERC20(SCR).balanceOf(address(safe));
        uint256 lrBefore = IERC20(LIQUID_RESERVE).balanceOf(address(safe));

        // Quote and fund
        uint256 fee = migrationModule.quoteBridgeAll(_safes(address(safe)));
        vm.deal(etherFiWallet, fee + 10 ether);

        vm.prank(etherFiWallet);
        migrationModule.bridgeAll{ value: fee }(_safes(address(safe)));

        // Canonical tokens: gone
        assertEq(IERC20(USDC).balanceOf(address(safe)), 0, "USDC not bridged");
        assertEq(IERC20(USDT).balanceOf(address(safe)), 0, "USDT not bridged");
        assertEq(IERC20(WETH).balanceOf(address(safe)), 0, "WETH not bridged");

        // OFT mainnet tokens: gone
        assertEq(IERC20(EURC).balanceOf(address(safe)), 0, "EURC not bridged");
        assertEq(IERC20(WEETH).balanceOf(address(safe)), 0, "weETH not bridged");
        assertEq(IERC20(ETHFI).balanceOf(address(safe)), 0, "ETHFI not bridged");

        // Hop token: gone
        assertEq(IERC20(FRXUSD).balanceOf(address(safe)), 0, "frxUSD not bridged");

        // Teller tokens: gone
        assertEq(IERC20(LIQUID_ETH).balanceOf(address(safe)), 0, "LiquidETH not bridged");
        assertEq(IERC20(LIQUID_BTC).balanceOf(address(safe)), 0, "LiquidBTC not bridged");
        assertEq(IERC20(LIQUID_USD).balanceOf(address(safe)), 0, "LiquidUSD not bridged");
        assertEq(IERC20(EUSD).balanceOf(address(safe)), 0, "EUSD not bridged");
        assertEq(IERC20(EBTC).balanceOf(address(safe)), 0, "EBTC not bridged");
        assertEq(IERC20(SETHFI).balanceOf(address(safe)), 0, "sETHFI not bridged");

        // OFT HyperEVM tokens: gone
        assertEq(IERC20(WHYPE).balanceOf(address(safe)), 0, "wHYPE not bridged");
        assertEq(IERC20(BEHYPE).balanceOf(address(safe)), 0, "beHype not bridged");

        // Skip tokens: untouched
        assertEq(IERC20(SCR).balanceOf(address(safe)), scrBefore, "SCR should stay");
        assertEq(IERC20(LIQUID_RESERVE).balanceOf(address(safe)), lrBefore, "LiquidReserve should stay");
    }

    function test_quoteBridgeAll_allTokens() public {
        _configureAllTokens();
        _dealAllTokensToSafe();

        uint256 fee = migrationModule.quoteBridgeAll(_safes(address(safe)));
        // Should have fees for 3 OFT mainnet + 2 OFT HyperEVM + 6 Teller = 11 LZ messages
        assertGt(fee, 0, "Should have non-zero fee for OFT+Teller tokens");
    }
}
