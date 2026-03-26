// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { TopUpDest } from "../src/top-up/TopUpDest.sol";
import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";
import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { EtherFiSafe } from "../src/safe/EtherFiSafe.sol";
import { EtherFiSafeFactory } from "../src/safe/EtherFiSafeFactory.sol";
import { EtherFiHook } from "../src/hook/EtherFiHook.sol";
import { ICashModule, BinSponsor } from "../src/interfaces/ICashModule.sol";
import { CashLens } from "../src/modules/cash/CashLens.sol";
import { CashModuleCore } from "../src/modules/cash/CashModuleCore.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";
import { CashbackDispatcher } from "../src/cashback-dispatcher/CashbackDispatcher.sol";
import { PriceProvider } from "../src/oracle/PriceProvider.sol";
import { SettlementDispatcher } from "../src/settlement-dispatcher/SettlementDispatcher.sol";
import { OpenOceanSwapModule } from "../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { CashEventEmitter } from "../src/modules/cash/CashEventEmitter.sol";
import { DebtManagerCore } from "../src/debt-manager/DebtManagerCore.sol";

/// @title Post-deployment verification for OP Mainnet prod
/// @notice Reverts on any failed check so CI/scripts can rely on exit code.
///         Run against live chain: forge script scripts/VerifyOptimismProd.s.sol --rpc-url <OP_RPC>
contract VerifyOptimismProd is Script {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    bytes32 constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant OZ_INIT_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 constant ROLE_REGISTRY_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;

    // ── Expected proxy addresses (deterministic via Nick's factory + prod salts) ──
    address constant ROLE_REGISTRY          = 0x5C1E3D653fcbC54Ae25c2AD9d59548D2082C687B;
    address constant DATA_PROVIDER          = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address constant CASH_MODULE            = 0x7Ca0b75E67E33c0014325B739A8d019C4FE445F0;
    address constant PRICE_PROVIDER         = 0x44dd2372FE7B97C4B4D6a7d4DeCf72466485BAcB;
    address constant CASHBACK_DISPATCHER    = 0xef55eC694B0B8273967f28627C5BC26F5deea836;
    address constant CASH_LENS              = 0x7DA874f3BacA1A8F0af27E5ceE1b8C66A772F84E;
    address constant HOOK                   = 0x5D3c4f5CF2208bB54e8fd129730d01D82d4611b3;
    address constant SAFE_FACTORY           = 0xF4e147Db314947fC1275a8CbB6Cde48c510cd8CF;
    address constant DEBT_MANAGER           = 0x0078C5a459132e279056B2371fE8A8eC973A9553;
    address constant SETTLEMENT_REAP        = 0x9623e86Df854FF3b48F7B4079a516a4F64861Db2;
    address constant SETTLEMENT_RAIN        = 0x50A233C4a0Bb1d7124b0224880037d35767a501C;
    address constant CASH_EVENT_EMITTER     = 0x380B2e96799405be6e3D965f4044099891881acB;
    address constant TOP_UP_DEST            = 0x3a6A724595184dda4be69dB1Ce726F2Ac3D66B87;

    // ── Expected impl addresses (deterministic via Nick's factory + prod impl salts) ──
    bytes32 constant SALT_DATA_PROVIDER_IMPL      = 0x33426737cdc104136d409e458c4cd0e95193cebd080c1e44b289dbc1e940beaa;
    bytes32 constant SALT_ROLE_REGISTRY_IMPL       = 0x32e997ba554122714b8ab01335f36a045850032102a6a6946442eaecac753c3a;
    bytes32 constant SALT_CASH_MODULE_CORE_IMPL    = 0xaf898630953f50a7c1d33680fc7dcf155f3c8143df1c74df7490ef62c98b8248;
    bytes32 constant SALT_PRICE_PROVIDER_IMPL      = 0xaedf608e44a4a1db3cd12c7bde065403b086c16247255165ea591189a625b6da;
    bytes32 constant SALT_CASHBACK_DISP_IMPL       = 0x36a2d3f253a03bb2850d51aa4b008664a9655524d7818377e25cd8362f39f802;
    bytes32 constant SALT_CASH_LENS_IMPL           = 0x9c4d2e9e03347d9ae5b84e91ba528127b4ca4fe0ce227106ed59acbd554df21f;
    bytes32 constant SALT_HOOK_IMPL                = 0xa5255de9d2cd171ef9d8b5da6e27d8e1282493fa55cce90af6e145b2ce8d205e;
    bytes32 constant SALT_SAFE_FACTORY_IMPL        = 0x89a0cb186faf1ec3240a4a2bdefe0124bd4fac7547ef1d07ad0d1f1a9f30cafe;
    bytes32 constant SALT_DEBT_MANAGER_CORE_IMPL   = 0xd7d8accf3671d756a509daca0abd0356c4079376519f8b6e1796646b98b5f9bc;
    bytes32 constant SALT_SETTLEMENT_REAP_IMPL     = 0xfb940a399a0b17489a29999f8d51b555d0834c50a92d989583deaff458551388;
    bytes32 constant SALT_SETTLEMENT_RAIN_IMPL     = 0x9c80c1c53d2395cf81c7efdc6edae701961f3e792cc322d517886347b74aa513;
    bytes32 constant SALT_CASH_EVENT_EMIT_IMPL     = 0xf84100a4d2d9b349177716ea94e9e2cf69065d341c91a34db1522f66d64c15f0;
    bytes32 constant SALT_TOP_UP_DEST_IMPL         = 0x5665b1d054cb150b9bce2109812c618aabb541dedf90abe9b62e4f34ac779e84;

    // ── OP Mainnet config ──
    address constant etherFiRecoverySigner = 0x7fEd99d0aA90423de55e238Eb5F9416FF7Cc58eF;
    address constant thirdPartyRecoverySigner = 0x24e311DA50784Cf9DB1abE59725e4A1A110220FA;
    address constant etherFiWallet = 0x2e0bE8D3D9F1833fbACf9A5E9f2b470817FF0c00;

    address constant usdc = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant weETH = 0x5A7fACB970D094B6C7FF1df0eA68D99E6e73CBFF;
    address constant weth = 0x4200000000000000000000000000000000000006;

    bytes32 constant DEBT_MANAGER_ADMIN_ROLE = keccak256("DEBT_MANAGER_ADMIN_ROLE");

    function run() public view {
        require(block.chainid == 10, "Must run on OP Mainnet (chain 10)");

        console.log("======================================");
        console.log("  OP Mainnet Prod Deployment Verify");
        console.log("======================================");
        console.log("");

        _verifyContractsExist();
        _verifyProxySlots();
        _verifyImplAddresses();
        _verifyDataProviderCrossRefs();
        _verifyCashModuleConfig();
        _verifyDebtManagerConfig();
        _verifyRoles();
        _verifyOwnership();
        _verifyPriceProviderOracles();

        console.log("");
        console.log("======================================");
        console.log("  ALL CHECKS PASSED");
        console.log("======================================");
    }

    // ─────────────────────────────────────────────
    // 1. Verify all contracts have code at expected addresses
    // ─────────────────────────────────────────────
    function _verifyContractsExist() internal view {
        console.log("--- 1. Contract existence ---");
        _requireCode("RoleRegistry", ROLE_REGISTRY);
        _requireCode("DataProvider", DATA_PROVIDER);
        _requireCode("CashModule", CASH_MODULE);
        _requireCode("PriceProvider", PRICE_PROVIDER);
        _requireCode("CashbackDispatcher", CASHBACK_DISPATCHER);
        _requireCode("CashLens", CASH_LENS);
        _requireCode("Hook", HOOK);
        _requireCode("SafeFactory", SAFE_FACTORY);
        _requireCode("DebtManager", DEBT_MANAGER);
        _requireCode("SettlementReap", SETTLEMENT_REAP);
        _requireCode("SettlementRain", SETTLEMENT_RAIN);
        _requireCode("CashEventEmitter", CASH_EVENT_EMITTER);
        _requireCode("TopUpDest", TOP_UP_DEST);
    }

    // ─────────────────────────────────────────────
    // 2. Verify EIP-1967 impl slot, initialization, and roleRegistry for all proxies
    // ─────────────────────────────────────────────
    function _verifyProxySlots() internal view {
        console.log("");
        console.log("--- 2. Proxy slots (impl + init + roleRegistry) ---");

        address[13] memory proxies = [
            ROLE_REGISTRY, DATA_PROVIDER, CASH_MODULE, PRICE_PROVIDER,
            CASHBACK_DISPATCHER, CASH_LENS, HOOK, SAFE_FACTORY,
            DEBT_MANAGER, SETTLEMENT_REAP, SETTLEMENT_RAIN,
            CASH_EVENT_EMITTER, TOP_UP_DEST
        ];
        string[13] memory names = [
            "RoleRegistry", "DataProvider", "CashModule", "PriceProvider",
            "CashbackDispatcher", "CashLens", "Hook", "SafeFactory",
            "DebtManager", "SettlementReap", "SettlementRain",
            "CashEventEmitter", "TopUpDest"
        ];

        for (uint256 i = 0; i < 13; i++) {
            address proxy = proxies[i];
            string memory name = names[i];

            address impl = address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
            require(impl != address(0), string.concat(name, " impl is zero"));
            require(impl.code.length > 0, string.concat(name, " impl has no code"));

            uint256 initVersion = uint256(vm.load(proxy, OZ_INIT_SLOT));
            require(initVersion > 0, string.concat(name, " NOT initialized"));

            address storedRR = address(uint160(uint256(vm.load(proxy, ROLE_REGISTRY_SLOT))));
            require(storedRR == ROLE_REGISTRY, string.concat(name, " roleRegistry mismatch — possible hijack"));

            console.log(string.concat("  [OK] ", name, " impl="), impl);
        }
    }

    // ─────────────────────────────────────────────
    // 2b. Verify implementation addresses match expected (from impl salts)
    // ─────────────────────────────────────────────
    function _verifyImplAddresses() internal view {
        console.log("");
        console.log("--- 2b. Implementation addresses ---");

        _requireImpl("DataProvider",       DATA_PROVIDER,       SALT_DATA_PROVIDER_IMPL);
        _requireImpl("RoleRegistry",       ROLE_REGISTRY,       SALT_ROLE_REGISTRY_IMPL);
        _requireImpl("CashModule",         CASH_MODULE,         SALT_CASH_MODULE_CORE_IMPL);
        _requireImpl("PriceProvider",      PRICE_PROVIDER,      SALT_PRICE_PROVIDER_IMPL);
        _requireImpl("CashbackDispatcher", CASHBACK_DISPATCHER, SALT_CASHBACK_DISP_IMPL);
        _requireImpl("CashLens",           CASH_LENS,           SALT_CASH_LENS_IMPL);
        _requireImpl("Hook",               HOOK,                SALT_HOOK_IMPL);
        _requireImpl("SafeFactory",        SAFE_FACTORY,        SALT_SAFE_FACTORY_IMPL);
        _requireImpl("DebtManager",        DEBT_MANAGER,        SALT_DEBT_MANAGER_CORE_IMPL);
        _requireImpl("SettlementReap",     SETTLEMENT_REAP,     SALT_SETTLEMENT_REAP_IMPL);
        _requireImpl("SettlementRain",     SETTLEMENT_RAIN,     SALT_SETTLEMENT_RAIN_IMPL);
        _requireImpl("CashEventEmitter",   CASH_EVENT_EMITTER,  SALT_CASH_EVENT_EMIT_IMPL);
        _requireImpl("TopUpDest",          TOP_UP_DEST,         SALT_TOP_UP_DEST_IMPL);
    }

    // ─────────────────────────────────────────────
    // 3. Verify DataProvider cross-references are correct
    // ─────────────────────────────────────────────
    function _verifyDataProviderCrossRefs() internal view {
        console.log("");
        console.log("--- 3. DataProvider cross-references ---");

        EtherFiDataProvider dp = EtherFiDataProvider(DATA_PROVIDER);

        require(dp.getCashModule() == CASH_MODULE, "dp.getCashModule mismatch");
        console.log("  [OK] dp.getCashModule");
        require(dp.getCashLens() == CASH_LENS, "dp.getCashLens mismatch");
        console.log("  [OK] dp.getCashLens");
        require(dp.getHookAddress() == HOOK, "dp.getHookAddress mismatch");
        console.log("  [OK] dp.getHookAddress");
        require(dp.getEtherFiSafeFactory() == SAFE_FACTORY, "dp.getEtherFiSafeFactory mismatch");
        console.log("  [OK] dp.getEtherFiSafeFactory");
        require(dp.getPriceProvider() == PRICE_PROVIDER, "dp.getPriceProvider mismatch");
        console.log("  [OK] dp.getPriceProvider");
        require(dp.getEtherFiRecoverySigner() == etherFiRecoverySigner, "dp.getEtherFiRecoverySigner mismatch");
        console.log("  [OK] dp.getEtherFiRecoverySigner");
        require(dp.getThirdPartyRecoverySigner() == thirdPartyRecoverySigner, "dp.getThirdPartyRecoverySigner mismatch");
        console.log("  [OK] dp.getThirdPartyRecoverySigner");

        address[] memory defaultModules = dp.getDefaultModules();
        bool hasCashModule = false;
        for (uint256 i = 0; i < defaultModules.length; i++) {
            if (defaultModules[i] == CASH_MODULE) hasCashModule = true;
        }
        require(hasCashModule, "dp.defaultModules missing CASH_MODULE");
        console.log("  [OK] dp.defaultModules contains CASH_MODULE");
    }

    // ─────────────────────────────────────────────
    // 4. Verify CashModule config
    // ─────────────────────────────────────────────
    function _verifyCashModuleConfig() internal view {
        console.log("");
        console.log("--- 4. CashModule config ---");

        CashModuleCore cm = CashModuleCore(CASH_MODULE);
        address[] memory withdrawAssets = cm.getWhitelistedWithdrawAssets();
        bool hasUsdc = false;
        bool hasWeETH = false;
        for (uint256 i = 0; i < withdrawAssets.length; i++) {
            if (withdrawAssets[i] == usdc) hasUsdc = true;
            if (withdrawAssets[i] == weETH) hasWeETH = true;
        }
        require(hasUsdc, "CashModule missing USDC withdraw asset");
        console.log("  [OK] CashModule withdraw assets include USDC");
        require(hasWeETH, "CashModule missing weETH withdraw asset");
        console.log("  [OK] CashModule withdraw assets include weETH");
    }

    // ─────────────────────────────────────────────
    // 5. Verify DebtManager config
    // ─────────────────────────────────────────────
    function _verifyDebtManagerConfig() internal view {
        console.log("");
        console.log("--- 5. DebtManager config ---");

        IDebtManager dm = IDebtManager(DEBT_MANAGER);

        IDebtManager.CollateralTokenConfig memory usdcConfig = dm.collateralTokenConfig(usdc);
        require(usdcConfig.ltv == 90e18, "DM USDC collateral ltv != 90e18");
        require(usdcConfig.liquidationThreshold == 95e18, "DM USDC collateral liqThreshold != 95e18");
        require(usdcConfig.liquidationBonus == 1e18, "DM USDC collateral liqBonus != 1e18");
        console.log("  [OK] DM USDC collateral config");

        IDebtManager.CollateralTokenConfig memory weETHConfig = dm.collateralTokenConfig(weETH);
        require(weETHConfig.ltv == 50e18, "DM weETH collateral ltv != 50e18");
        require(weETHConfig.liquidationThreshold == 80e18, "DM weETH collateral liqThreshold != 80e18");
        require(weETHConfig.liquidationBonus == 1e18, "DM weETH collateral liqBonus != 1e18");
        console.log("  [OK] DM weETH collateral config");

        IDebtManager.BorrowTokenConfig memory usdcBorrow = dm.borrowTokenConfig(usdc);
        require(usdcBorrow.borrowApy == 1, "DM USDC borrow apy != 1");
        uint128 expectedMinShares = uint128(10 * 10 ** IERC20Metadata(usdc).decimals());
        require(usdcBorrow.minShares == expectedMinShares, "DM USDC borrow minShares mismatch");
        console.log("  [OK] DM USDC borrow config");
    }

    // ─────────────────────────────────────────────
    // 6. Verify critical roles are granted correctly
    // ─────────────────────────────────────────────
    function _verifyRoles() internal view {
        console.log("");
        console.log("--- 6. Role assignments ---");

        RoleRegistry rr = RoleRegistry(ROLE_REGISTRY);
        ICashModule cm = ICashModule(CASH_MODULE);
        EtherFiSafeFactory sf = EtherFiSafeFactory(SAFE_FACTORY);

        require(rr.hasRole(cm.ETHER_FI_WALLET_ROLE(), etherFiWallet), "etherFiWallet missing ETHER_FI_WALLET_ROLE");
        console.log("  [OK] etherFiWallet has ETHER_FI_WALLET_ROLE");
        require(rr.hasRole(sf.ETHERFI_SAFE_FACTORY_ADMIN_ROLE(), etherFiWallet), "etherFiWallet missing SAFE_FACTORY_ADMIN_ROLE");
        console.log("  [OK] etherFiWallet has SAFE_FACTORY_ADMIN_ROLE");
    }

    // ─────────────────────────────────────────────
    // 7. Verify ownership
    // ─────────────────────────────────────────────
    function _verifyOwnership() internal view {
        console.log("");
        console.log("--- 7. Ownership ---");

        address owner = RoleRegistry(ROLE_REGISTRY).owner();
        require(owner != address(0), "RoleRegistry owner is zero — ownership renounced");
        console.log("  [OK] RoleRegistry owner:", owner);
    }

    // ─────────────────────────────────────────────
    // 8. Verify PriceProvider oracle configuration
    // ─────────────────────────────────────────────
    function _verifyPriceProviderOracles() internal view {
        console.log("");
        console.log("--- 8. PriceProvider oracles ---");

        PriceProvider pp = PriceProvider(PRICE_PROVIDER);

        uint256 weETHPrice = pp.price(weETH);
        require(weETHPrice > 0, "weETH price is 0");
        console.log("  [OK] weETH price:", weETHPrice);

        uint256 ethPrice = pp.price(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        require(ethPrice > 0, "ETH price is 0");
        console.log("  [OK] ETH price:", ethPrice);

        uint256 usdcPrice = pp.price(usdc);
        require(usdcPrice > 0, "USDC price is 0");
        require(usdcPrice > 0.95e18 && usdcPrice < 1.05e18, "USDC price out of range");
        console.log("  [OK] USDC price:", usdcPrice);
    }

    // ─────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────

    function _requireCode(string memory name, address addr) internal view {
        require(addr.code.length > 0, string.concat(name, " has no code"));
        console.log(string.concat("  [OK] ", name), addr);
    }

    function _requireImpl(string memory name, address proxy, bytes32 implSalt) internal view {
        address actualImpl = address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
        address expectedImpl = CREATE3.predictDeterministicAddress(implSalt, NICKS_FACTORY);
        require(actualImpl == expectedImpl, string.concat(name, " impl mismatch — possible hijack"));
        console.log(string.concat("  [OK] ", name, " impl="), actualImpl);
    }
}
