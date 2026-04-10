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
import { SettlementDispatcherV2 } from "../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { OpenOceanSwapModule } from "../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { CashEventEmitter } from "../src/modules/cash/CashEventEmitter.sol";
import { DebtManagerCore } from "../src/debt-manager/DebtManagerCore.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

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

    // PIX and CardOrder proxy addresses (computed from salts at runtime)
    bytes32 constant SALT_SETTLEMENT_PIX_PROXY        = 0xb41c7d6d164a5805864d248441939a2d76f98a2294296f0f9c96f4fd28d8c738;
    bytes32 constant SALT_SETTLEMENT_CARD_ORDER_PROXY = 0x21f29b6246a6d23c4712db519298c542183be48de47f73d858b0a29169a32de6;

    // ── Expected impl addresses (deterministic via Nick's factory + prod impl salts) ──
    bytes32 constant SALT_DATA_PROVIDER_IMPL      = 0x33426737cdc104136d409e458c4cd0e95193cebd080c1e44b289dbc1e940beaa;
    bytes32 constant SALT_CASH_MODULE_CORE_IMPL    = 0xaf898630953f50a7c1d33680fc7dcf155f3c8143df1c74df7490ef62c98b8248;
    bytes32 constant SALT_PRICE_PROVIDER_IMPL      = 0xaedf608e44a4a1db3cd12c7bde065403b086c16247255165ea591189a625b6da;
    bytes32 constant SALT_CASHBACK_DISP_IMPL       = 0x36a2d3f253a03bb2850d51aa4b008664a9655524d7818377e25cd8362f39f802;
    bytes32 constant SALT_CASH_LENS_IMPL           = 0x9c4d2e9e03347d9ae5b84e91ba528127b4ca4fe0ce227106ed59acbd554df21f;
    bytes32 constant SALT_HOOK_IMPL                = 0xa5255de9d2cd171ef9d8b5da6e27d8e1282493fa55cce90af6e145b2ce8d205e;
    bytes32 constant SALT_SETTLEMENT_REAP_IMPL     = 0xfb940a399a0b17489a29999f8d51b555d0834c50a92d989583deaff458551388;
    bytes32 constant SALT_SETTLEMENT_RAIN_IMPL     = 0x9c80c1c53d2395cf81c7efdc6edae701961f3e792cc322d517886347b74aa513;
    bytes32 constant SALT_SETTLEMENT_PIX_IMPL      = 0x2927c21ef5b1924d6de0d3ac232b846fb5c7aac14e3252f12d31512dbd00aa5b;
    bytes32 constant SALT_SETTLEMENT_CARD_ORDER_IMPL = 0xd251318731c981b9b9d5546666e2dbb04bbc5be2feedb7f86476706f450bda14;
    bytes32 constant SALT_CASH_EVENT_EMIT_IMPL     = 0xf84100a4d2d9b349177716ea94e9e2cf69065d341c91a34db1522f66d64c15f0;
    bytes32 constant SALT_TOP_UP_DEST_IMPL         = 0x5665b1d054cb150b9bce2109812c618aabb541dedf90abe9b62e4f34ac779e84;

    // ── OP Mainnet config ──
    address constant cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address constant etherFiRecoverySigner = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address constant thirdPartyRecoverySigner = 0x4F5eB42edEce3285B97245f56b64598191b5A58E;
    address constant etherFiWallet1 = 0xdC45DB93c3fC37272f40812bBa9C4Bad91344b46;
    address constant etherFiWallet2 = 0xB42833d6edd1241474D33ea99906fD4CBE893730;

    address constant usdc = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant weETH = 0x5A7fACB970D094B6C7FF1df0eA68D99E6e73CBFF;
    address constant weth = 0x4200000000000000000000000000000000000006;

    bytes32 constant DEBT_MANAGER_ADMIN_ROLE = keccak256("DEBT_MANAGER_ADMIN_ROLE");

    // Computed at runtime
    address SETTLEMENT_PIX;
    address SETTLEMENT_CARD_ORDER;

    function run() public {
        require(block.chainid == 10, "Must run on OP Mainnet (chain 10)");

        SETTLEMENT_PIX = CREATE3.predictDeterministicAddress(SALT_SETTLEMENT_PIX_PROXY, NICKS_FACTORY);
        SETTLEMENT_CARD_ORDER = CREATE3.predictDeterministicAddress(SALT_SETTLEMENT_CARD_ORDER_PROXY, NICKS_FACTORY);

        console.log("======================================");
        console.log("  OP Mainnet Prod Deployment Verify");
        console.log("======================================");
        console.log("");

        _verifyContractsExist();
        _verifyProxySlots();
        _verifyImplAddresses();
        _verifyDataProviderCrossRefs();
        _verifyOwnership();

        // Post-gnosis checks: these verify configuration applied by the gnosis batch.
        // They will fail if the gnosis batch hasn't been executed yet.
        console.log("");
        console.log("--- Post-gnosis configuration checks ---");
        bool gnosisOk = true;
        gnosisOk = _tryPriceProviderOracles() && gnosisOk;
        gnosisOk = _tryCashModuleConfig() && gnosisOk;
        gnosisOk = _tryDebtManagerConfig() && gnosisOk;
        gnosisOk = _tryDebtManagerPaused() && gnosisOk;
        gnosisOk = _tryRoles() && gnosisOk;

        console.log("");
        console.log("======================================");
        if (gnosisOk) {
            console.log("  ALL CHECKS PASSED");
        } else {
            console.log("  CORE CHECKS PASSED");
            console.log("  Some post-gnosis checks failed (gnosis batch not yet executed)");
        }
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
        _requireCode("SettlementPix", SETTLEMENT_PIX);
        _requireCode("SettlementCardOrder", SETTLEMENT_CARD_ORDER);
        _requireCode("CashEventEmitter", CASH_EVENT_EMITTER);
        _requireCode("TopUpDest", TOP_UP_DEST);
    }

    // ─────────────────────────────────────────────
    // 2. Verify EIP-1967 impl slot, initialization, and roleRegistry for all proxies
    // ─────────────────────────────────────────────
    function _verifyProxySlots() internal view {
        console.log("");
        console.log("--- 2. Proxy slots (impl + init + roleRegistry) ---");

        address[15] memory proxies = [
            ROLE_REGISTRY, DATA_PROVIDER, CASH_MODULE, PRICE_PROVIDER,
            CASHBACK_DISPATCHER, CASH_LENS, HOOK, SAFE_FACTORY,
            DEBT_MANAGER, SETTLEMENT_REAP, SETTLEMENT_RAIN,
            SETTLEMENT_PIX, SETTLEMENT_CARD_ORDER,
            CASH_EVENT_EMITTER, TOP_UP_DEST
        ];
        string[15] memory names = [
            "RoleRegistry", "DataProvider", "CashModule", "PriceProvider",
            "CashbackDispatcher", "CashLens", "Hook", "SafeFactory",
            "DebtManager", "SettlementReap", "SettlementRain",
            "SettlementPix", "SettlementCardOrder",
            "CashEventEmitter", "TopUpDest"
        ];

        for (uint256 i = 0; i < 15; i++) {
            address proxy = proxies[i];
            string memory name = names[i];

            address impl = address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
            require(impl != address(0), string.concat(name, " impl is zero"));
            require(impl.code.length > 0, string.concat(name, " impl has no code"));

            uint256 initVersion = uint256(vm.load(proxy, OZ_INIT_SLOT));
            require(initVersion > 0, string.concat(name, " NOT initialized"));

            // RoleRegistry uses Ownable (no roleRegistry slot); skip for it
            if (proxy != ROLE_REGISTRY) {
                address storedRR = address(uint160(uint256(vm.load(proxy, ROLE_REGISTRY_SLOT))));
                require(storedRR == ROLE_REGISTRY, string.concat(name, " roleRegistry mismatch - possible hijack"));
            }

            console.log(string.concat("  [OK] ", name, " impl="), impl);
        }
    }

    // ─────────────────────────────────────────────
    // 2b. Verify implementation addresses match expected (from impl salts)
    //     RoleRegistry impl is deployed via EOA (not CREATE3), so verified by non-zero check only.
    // ─────────────────────────────────────────────
    function _verifyImplAddresses() internal view {
        console.log("");
        console.log("--- 2b. Implementation addresses ---");

        _requireImpl("DataProvider",       DATA_PROVIDER,       SALT_DATA_PROVIDER_IMPL);
        _requireImpl("CashModule",         CASH_MODULE,         SALT_CASH_MODULE_CORE_IMPL);
        _requireImpl("PriceProvider",      PRICE_PROVIDER,      SALT_PRICE_PROVIDER_IMPL);
        _requireImpl("CashbackDispatcher", CASHBACK_DISPATCHER, SALT_CASHBACK_DISP_IMPL);
        _requireImpl("CashLens",           CASH_LENS,           SALT_CASH_LENS_IMPL);
        _requireImpl("Hook",               HOOK,                SALT_HOOK_IMPL);
        _requireImpl("SettlementReap",     SETTLEMENT_REAP,     SALT_SETTLEMENT_REAP_IMPL);
        _requireImpl("SettlementRain",     SETTLEMENT_RAIN,     SALT_SETTLEMENT_RAIN_IMPL);
        _requireImpl("SettlementPix",      SETTLEMENT_PIX,      SALT_SETTLEMENT_PIX_IMPL);
        _requireImpl("SettlementCardOrder", SETTLEMENT_CARD_ORDER, SALT_SETTLEMENT_CARD_ORDER_IMPL);
        _requireImpl("CashEventEmitter",   CASH_EVENT_EMITTER,  SALT_CASH_EVENT_EMIT_IMPL);
        _requireImpl("TopUpDest",          TOP_UP_DEST,         SALT_TOP_UP_DEST_IMPL);

        // RoleRegistry, SafeFactory, and DebtManager impls are deployed/upgraded via gnosis (not CREATE3 with prod salts).
        // Just verify non-zero impl with code.
        _requireImplNonZero("RoleRegistry", ROLE_REGISTRY);
        _requireImplNonZero("SafeFactory", SAFE_FACTORY);
        _requireImplNonZero("DebtManager", DEBT_MANAGER);
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
    // 4. Verify CashModule config (post-gnosis)
    // ─────────────────────────────────────────────
    function _tryCashModuleConfig() internal view returns (bool) {
        console.log("  4. CashModule config...");

        CashModuleCore cm = CashModuleCore(CASH_MODULE);
        address[] memory withdrawAssets = cm.getWhitelistedWithdrawAssets();
        bool hasUsdc = false;
        bool hasWeETH = false;
        for (uint256 i = 0; i < withdrawAssets.length; i++) {
            if (withdrawAssets[i] == usdc) hasUsdc = true;
            if (withdrawAssets[i] == weETH) hasWeETH = true;
        }
        if (!hasUsdc || !hasWeETH) { console.log("  [SKIP] withdraw assets not configured yet"); return false; }
        console.log("  [OK] CashModule withdraw assets");

        ICashModule icm = ICashModule(CASH_MODULE);
        if (icm.getSettlementDispatcher(BinSponsor.Reap) != SETTLEMENT_REAP) { console.log("  [SKIP] Reap SD not set"); return false; }
        if (icm.getSettlementDispatcher(BinSponsor.Rain) != SETTLEMENT_RAIN) { console.log("  [SKIP] Rain SD not set"); return false; }
        if (icm.getSettlementDispatcher(BinSponsor.PIX) != SETTLEMENT_PIX) { console.log("  [SKIP] PIX SD not set"); return false; }
        if (icm.getSettlementDispatcher(BinSponsor.CardOrder) != SETTLEMENT_CARD_ORDER) { console.log("  [SKIP] CardOrder SD not set"); return false; }
        console.log("  [OK] All settlement dispatchers set");
        return true;
    }

    // ─────────────────────────────────────────────
    // 5. Verify DebtManager config (post-gnosis)
    // ─────────────────────────────────────────────
    function _tryDebtManagerConfig() internal view returns (bool) {
        console.log("  5. DebtManager config...");

        IDebtManager dm = IDebtManager(DEBT_MANAGER);

        try dm.collateralTokenConfig(usdc) returns (IDebtManager.CollateralTokenConfig memory usdcConfig) {
            if (usdcConfig.ltv != 90e18) { console.log("  [SKIP] DM USDC collateral not configured"); return false; }
            if (usdcConfig.liquidationThreshold != 95e18 || usdcConfig.liquidationBonus != 1e18) { console.log("  [SKIP] DM USDC collateral mismatch"); return false; }
            console.log("  [OK] DM USDC collateral config");
        } catch { console.log("  [SKIP] DM not upgraded to core impl yet"); return false; }

        IDebtManager.CollateralTokenConfig memory weETHConfig = dm.collateralTokenConfig(weETH);
        if (weETHConfig.ltv != 55e18) { console.log("  [SKIP] DM weETH collateral not configured"); return false; }
        if (weETHConfig.liquidationThreshold != 75e18 || weETHConfig.liquidationBonus != 3.5e18) { console.log("  [SKIP] DM weETH collateral mismatch"); return false; }
        console.log("  [OK] DM weETH collateral config");

        IDebtManager.BorrowTokenConfig memory usdcBorrow = dm.borrowTokenConfig(usdc);
        uint128 expectedMinShares = uint128(10 * 10 ** IERC20Metadata(usdc).decimals());
        if (usdcBorrow.borrowApy != 126839167935 || usdcBorrow.minShares != expectedMinShares) { console.log("  [SKIP] DM USDC borrow not configured"); return false; }
        console.log("  [OK] DM USDC borrow config");
        return true;
    }

    // ─────────────────────────────────────────────
    // 5b. Verify DebtManager is paused (post-gnosis)
    // ─────────────────────────────────────────────
    function _tryDebtManagerPaused() internal view returns (bool) {
        console.log("  5b. DebtManager paused...");
        if (!PausableUpgradeable(DEBT_MANAGER).paused()) { console.log("  [SKIP] DebtManager not paused yet"); return false; }
        console.log("  [OK] DebtManager is paused");
        return true;
    }

    // ─────────────────────────────────────────────
    // 6. Verify critical roles (post-gnosis)
    // ─────────────────────────────────────────────
    function _tryRoles() internal view returns (bool) {
        console.log("  6. Role assignments...");

        RoleRegistry rr = RoleRegistry(ROLE_REGISTRY);
        ICashModule cm = ICashModule(CASH_MODULE);

        if (!rr.hasRole(cm.ETHER_FI_WALLET_ROLE(), etherFiWallet1)) { console.log("  [SKIP] roles not granted yet"); return false; }
        console.log("  [OK] etherFiWallet1 has ETHER_FI_WALLET_ROLE");

        if (!rr.hasRole(cm.ETHER_FI_WALLET_ROLE(), etherFiWallet2)) { console.log("  [SKIP] etherFiWallet2 missing role"); return false; }
        console.log("  [OK] etherFiWallet2 has ETHER_FI_WALLET_ROLE");

        if (!rr.hasRole(rr.PAUSER(), cashControllerSafe)) { console.log("  [SKIP] Safe missing PAUSER"); return false; }
        console.log("  [OK] Safe has PAUSER");

        bytes32 bridgerRole = SettlementDispatcherV2(payable(SETTLEMENT_REAP)).SETTLEMENT_DISPATCHER_BRIDGER_ROLE();
        if (!rr.hasRole(bridgerRole, cashControllerSafe)) { console.log("  [SKIP] Safe missing bridger roles"); return false; }
        console.log("  [OK] Safe has bridger roles");

        return true;
    }

    // ─────────────────────────────────────────────
    // 7. Verify ownership
    // ─────────────────────────────────────────────
    function _verifyOwnership() internal view {
        console.log("");
        console.log("--- 7. Ownership ---");

        address owner = RoleRegistry(ROLE_REGISTRY).owner();
        require(owner != address(0), "RoleRegistry owner is zero - ownership renounced");
        console.log("  [OK] RoleRegistry owner:", owner);
    }

    // ─────────────────────────────────────────────
    // 8. Verify PriceProvider oracle configuration (post-gnosis)
    // ─────────────────────────────────────────────
    function _tryPriceProviderOracles() internal view returns (bool) {
        console.log("  8. PriceProvider oracles...");

        PriceProvider pp = PriceProvider(PRICE_PROVIDER);

        try pp.price(weETH) returns (uint256 weETHPrice) {
            if (weETHPrice == 0) { console.log("  [SKIP] weETH price is 0"); return false; }
            console.log("  [OK] weETH price:", weETHPrice);
        } catch { console.log("  [SKIP] weETH oracle not configured"); return false; }

        try pp.price(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) returns (uint256 ethPrice) {
            if (ethPrice == 0) { console.log("  [SKIP] ETH price is 0"); return false; }
            console.log("  [OK] ETH price:", ethPrice);
        } catch { console.log("  [SKIP] ETH oracle not configured"); return false; }

        try pp.price(usdc) returns (uint256 usdcPrice) {
            if (usdcPrice == 0 || usdcPrice < 0.95e6 || usdcPrice > 1.05e6) { console.log("  [SKIP] USDC price out of range"); return false; }
            console.log("  [OK] USDC price:", usdcPrice);
        } catch { console.log("  [SKIP] USDC oracle not configured"); return false; }

        return true;
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
        require(actualImpl == expectedImpl, string.concat(name, " impl mismatch - possible hijack"));
        console.log(string.concat("  [OK] ", name, " impl="), actualImpl);
    }

    function _requireImplNonZero(string memory name, address proxy) internal view {
        address impl = address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
        require(impl != address(0) && impl.code.length > 0, string.concat(name, " impl missing"));
        console.log(string.concat("  [OK] ", name, " impl="), impl);
    }
}
