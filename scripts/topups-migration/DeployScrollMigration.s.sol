// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { Utils } from "../utils/Utils.sol";
import { Cashback, BinSponsor, ICashModule } from "../../src/interfaces/ICashModule.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { MigrationBridgeModule } from "../../src/migration/MigrationBridgeModule.sol";
import { TopUpDestWithMigration } from "../../src/top-up/TopUpDestWithMigration.sol";
import { DebtManagerCoreWithMigration } from "../../src/debt-manager/DebtManagerCoreWithMigration.sol";
import { CashLensWithMigration } from "../../src/modules/cash/CashLensWithMigration.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";

/**
 * @title DeployScrollMigration
 * @notice Deploys the full migration stack on Scroll (prod) in one script:
 *         - MigrationBridgeModule (impl + proxy via CREATE3, atomic init)
 *         - New EtherFiHook impl (via CREATE3)
 *         - TopUpDestWithMigration impl (via CREATE3)
 *         - DebtManagerCoreWithMigration impl (via CREATE3)
 *         - CashLensWithMigration impl (via CREATE3)
 *
 *         Then generates a Gnosis Safe TX bundle for the multisig to:
 *         1. Register migration module as default module
 *         2. Upgrade EtherFiHook + set migration bypass
 *         3. Upgrade TopUpDest -> TopUpDestWithMigration
 *         4. Upgrade DebtManager -> DebtManagerCoreWithMigration
 *         5. Upgrade CashLens -> CashLensWithMigration
 *         6. Grant MIGRATION_BRIDGE_ADMIN_ROLE
 *         7. Configure 17 token bridge routes
 *
 * Circular dependency resolution:
 *   - MigrationBridgeModule constructor needs topUpDest => uses existing TopUpDest proxy
 *   - TopUpDestWithMigration constructor needs migrationModule => uses CREATE3-predicted proxy address
 *
 * Usage:
 *   ENV=mainnet forge script scripts/topups-migration/DeployScrollMigration.s.sol \
 *     --rpc-url $SCROLL_RPC --broadcast
 */
contract DeployScrollMigration is GnosisHelpers, Utils, Test {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant CASH_CONTROLLER_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    // ── CREATE3 salts (all unique, deterministic, prod-only) ──
    bytes32 constant SALT_MIGRATION_MODULE_IMPL  = keccak256("TopupsMigration.Prod.MigrationModuleImpl");
    bytes32 constant SALT_MIGRATION_MODULE_PROXY = keccak256("TopupsMigration.Prod.MigrationModuleProxy");
    bytes32 constant SALT_HOOK_IMPL              = keccak256("TopupsMigration.Prod.HookImpl");
    bytes32 constant SALT_TOPUP_DEST_IMPL        = keccak256("TopupsMigration.Prod.TopUpDestWithMigrationImpl");
    bytes32 constant SALT_DEBT_MANAGER_IMPL      = keccak256("TopupsMigration.Prod.DebtManagerCoreWithMigrationImpl");
    bytes32 constant SALT_CASH_LENS_IMPL         = keccak256("TopupsMigration.Prod.CashLensWithMigrationImpl");

    // ── Scroll WETH ──
    address constant WETH = 0x5300000000000000000000000000000000000004;

    // ── Token addresses (Scroll) ──
    address constant USDC            = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    address constant USDT            = 0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df;
    address constant WEETH           = 0x01f0a31698C4d065659b9bdC21B3610292a1c506;
    address constant ETHFI           = 0x056A5FA5da84ceb7f93d36e545C5905607D8bD81;
    address constant EURC            = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;
    address constant FRXUSD          = 0x397F939C3b91A74C321ea7129396492bA9Cdce82;
    address constant SCR             = 0xd29687c813D741E2F938F4aC377128810E217b1b;
    address constant LIQUID_ETH      = 0xf0bb20865277aBd641a307eCe5Ee04E79073416C;
    address constant LIQUID_BTC      = 0x5f46d540b6eD704C3c8789105F30E075AA900726;
    address constant LIQUID_USD      = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address constant EUSD            = 0x939778D83b46B456224A33Fb59630B11DEC56663;
    address constant EBTC            = 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;
    address constant SETHFI          = 0x86B5780b606940Eb59A062aA85a07959518c0161;
    address constant WHYPE           = 0xd83E3d560bA6F05094d9D8B3EB8aaEA571D1864E;
    address constant BEHYPE          = 0xA519AfBc91986c0e7501d7e34968FEE51CD901aC;
    address constant LIQUID_RESERVE  = 0xb7Fb3768CAAC98354EaDF514b48f28F2fE822bF0;

    // ── Teller addresses ──
    address constant LIQUID_ETH_TELLER = 0x9AA79C84b79816ab920bBcE20f8f74557B514734;
    address constant LIQUID_BTC_TELLER = 0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353;
    address constant LIQUID_USD_TELLER = 0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387;
    address constant EUSD_TELLER       = 0xCc9A7620D0358a521A068B444846E3D5DebEa8fA;
    address constant EBTC_TELLER       = 0x6Ee3aaCcf9f2321E49063C4F8da775DdBd407268;
    address constant SETHFI_TELLER     = 0x35dD2463fA7a335b721400C5Ad8Ba40bD85c179b;

    // ── OFT / bridge addresses ──
    address constant ETHFI_LZ_ADAPTER    = 0xe0080d2F853ecDdbd81A643dC10DA075Df26fD3f;
    address constant LIQUID_RESERVE_OFT  = 0xE5d3854736e0D513aAE2D8D708Ad94d14Fd56A6a;

    // ── LZ endpoint IDs ──
    uint32 constant ETHEREUM_EID = 30_101;
    uint32 constant HYPEREVM_EID = 30_367;
    uint32 constant OPTIMISM_EID = 30_111;

    ICashModule cashModule;

    // Struct to avoid stack-too-deep
    struct Addrs {
        address dataProvider;
        address hook;
        address topUpDest;
        address debtManager;
        address cashLens;
        address cashModule;
        address roleRegistry;
    }

    struct Impls {
        address migrationImpl;
        address migrationProxy;
        address hookImpl;
        address topUpDestImpl;
        address debtManagerImpl;
        address cashLensImpl;
    }

    function run() public {
        require(block.chainid == 534352, "Must run on Scroll (534352)");

        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        Addrs memory a = _loadAddrs();
        cashModule = ICashModule(a.cashModule);
        Impls memory impls = _deployAll(a, privateKey);
        _generateGnosisTxs(a, impls);
    }

    function _loadAddrs() internal view returns (Addrs memory a) {
        string memory deployments = readDeploymentFile();
        a.dataProvider  = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        a.hook          = stdJson.readAddress(deployments, ".addresses.EtherFiHook");
        a.topUpDest     = stdJson.readAddress(deployments, ".addresses.TopUpDest");
        a.debtManager   = stdJson.readAddress(deployments, ".addresses.DebtManager");
        a.cashLens      = stdJson.readAddress(deployments, ".addresses.CashLens");
        a.cashModule    = stdJson.readAddress(deployments, ".addresses.CashModule");
        a.roleRegistry  = stdJson.readAddress(deployments, ".addresses.RoleRegistry");
    }

    function _deployAll(Addrs memory a, uint256 privateKey) internal returns (Impls memory impls) {
        impls.migrationProxy = CREATE3.predictDeterministicAddress(SALT_MIGRATION_MODULE_PROXY, NICKS_FACTORY);
        console.log("Predicted MigrationBridgeModule proxy:", impls.migrationProxy);

        vm.startBroadcast(privateKey);

        // 1. MigrationBridgeModule impl (needs dataProvider + existing topUpDest proxy)
        impls.migrationImpl = deployCreate3(
            abi.encodePacked(type(MigrationBridgeModule).creationCode, abi.encode(a.dataProvider, a.topUpDest)),
            SALT_MIGRATION_MODULE_IMPL
        );
        console.log("MigrationBridgeModule impl:", impls.migrationImpl);

        // 2. MigrationBridgeModule proxy (atomic init - NOT front-runnable)
        {
            address proxy = deployCreate3(
                abi.encodePacked(
                    type(UUPSProxy).creationCode,
                    abi.encode(impls.migrationImpl, abi.encodeWithSelector(MigrationBridgeModule.initialize.selector, a.roleRegistry))
                ),
                SALT_MIGRATION_MODULE_PROXY
            );
            require(proxy == impls.migrationProxy, "CREATE3 proxy address mismatch");
            console.log("MigrationBridgeModule proxy:", proxy);
        }

        // 3. New EtherFiHook impl
        impls.hookImpl = deployCreate3(
            abi.encodePacked(type(EtherFiHook).creationCode, abi.encode(a.dataProvider)),
            SALT_HOOK_IMPL
        );
        console.log("EtherFiHook impl:", impls.hookImpl);

        // 4. TopUpDestWithMigration impl
        impls.topUpDestImpl = deployCreate3(
            abi.encodePacked(type(TopUpDestWithMigration).creationCode, abi.encode(a.dataProvider, WETH, impls.migrationProxy)),
            SALT_TOPUP_DEST_IMPL
        );
        console.log("TopUpDestWithMigration impl:", impls.topUpDestImpl);

        // 5. DebtManagerCoreWithMigration impl
        impls.debtManagerImpl = deployCreate3(
            abi.encodePacked(type(DebtManagerCoreWithMigration).creationCode, abi.encode(a.dataProvider, a.topUpDest)),
            SALT_DEBT_MANAGER_IMPL
        );
        console.log("DebtManagerCoreWithMigration impl:", impls.debtManagerImpl);

        // 6. CashLensWithMigration impl
        impls.cashLensImpl = deployCreate3(
            abi.encodePacked(type(CashLensWithMigration).creationCode, abi.encode(a.cashModule, a.dataProvider, a.topUpDest)),
            SALT_CASH_LENS_IMPL
        );
        console.log("CashLensWithMigration impl:", impls.cashLensImpl);

        vm.stopBroadcast();
    }

    function _generateGnosisTxs(Addrs memory a, Impls memory impls) internal {
        string memory chainId = vm.toString(block.chainid);
        string memory txs = _getGnosisHeader(chainId, addressToHex(CASH_CONTROLLER_SAFE));

        // TX 1: Register migration module as default module on DataProvider
        {
            address[] memory modules = new address[](1);
            modules[0] = impls.migrationProxy;
            bool[] memory shouldWhitelist = new bool[](1);
            shouldWhitelist[0] = true;

            txs = string(abi.encodePacked(txs, _getGnosisTransaction(
                addressToHex(a.dataProvider),
                iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, modules, shouldWhitelist)),
                "0", false
            )));
        }

        // TX 2: Upgrade EtherFiHook to new impl
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(a.hook),
            iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, impls.hookImpl, "")),
            "0", false
        )));

        // TX 3: Set migration module on hook
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(a.hook),
            iToHex(abi.encodeWithSelector(EtherFiHook.setMigrationModule.selector, impls.migrationProxy)),
            "0", false
        )));

        // TX 4: Upgrade TopUpDest -> TopUpDestWithMigration
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(a.topUpDest),
            iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, impls.topUpDestImpl, "")),
            "0", false
        )));

        // TX 5: Upgrade DebtManager -> DebtManagerCoreWithMigration
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(a.debtManager),
            iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, impls.debtManagerImpl, "")),
            "0", false
        )));

        // TX 6: Upgrade CashLens -> CashLensWithMigration
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(a.cashLens),
            iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, impls.cashLensImpl, "")),
            "0", false
        )));

        // TX 7: Grant MIGRATION_BRIDGE_ADMIN_ROLE to cashControllerSafe
        {
            bytes32 adminRole = MigrationBridgeModule(payable(impls.migrationProxy)).MIGRATION_BRIDGE_ADMIN_ROLE();
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(
                addressToHex(a.roleRegistry),
                iToHex(abi.encodeWithSelector(IRoleRegistry.grantRole.selector, adminRole, CASH_CONTROLLER_SAFE)),
                "0", false
            )));
        }

        // TX 8: Configure 17 token bridge routes
        {
            (address[] memory tokens, MigrationBridgeModule.TokenBridgeConfig[] memory configs) = _getTokenConfigs();
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(
                addressToHex(impls.migrationProxy),
                iToHex(abi.encodeWithSelector(MigrationBridgeModule.configureTokens.selector, tokens, configs)),
                "0", true
            )));
        }

        vm.createDir("./output", true);
        string memory path = "./output/DeployScrollMigration.json";
        vm.writeFile(path, txs);
        console.log("\nGnosis bundle written to:", path);

        // Simulate gnosis bundle on fork
        executeGnosisTransactionBundle(path);
        test_spend();
        console.log("[OK] Gnosis bundle simulation passed");

        // Post-execution ownership check
        address currentOwner = IRoleRegistry(a.roleRegistry).owner();
        require(currentOwner == CASH_CONTROLLER_SAFE, "CRITICAL: RoleRegistry owner changed!");
        console.log("[OK] RoleRegistry owner unchanged:", currentOwner);
    }

    // ═══════════════════════════════════════════════════════════════
    //                      CREATE3 HELPER
    // ═══════════════════════════════════════════════════════════════

    function deployCreate3(bytes memory creationCode, bytes32 salt) internal returns (address deployed) {
        deployed = CREATE3.predictDeterministicAddress(salt, NICKS_FACTORY);

        if (deployed.code.length > 0) {
            console.log("  [SKIP] already deployed at", deployed);
            return deployed;
        }

        address proxy = address(uint160(uint256(keccak256(abi.encodePacked(
            hex"ff", NICKS_FACTORY, salt, CREATE3.PROXY_INITCODE_HASH
        )))));

        bool ok;
        if (proxy.code.length == 0) {
            (ok,) = NICKS_FACTORY.call(abi.encodePacked(salt, hex"67363d3d37363d34f03d5260086018f3"));
            require(ok, "CREATE3 proxy deploy failed");
        }

        (ok,) = proxy.call(creationCode);
        require(ok, "CREATE3 contract deploy failed");
        require(deployed.code.length > 0, "CREATE3 deployment verification failed");
    }

    // ═══════════════════════════════════════════════════════════════
    //                      TOKEN CONFIGS
    // ═══════════════════════════════════════════════════════════════

    function _getTokenConfigs() internal pure returns (
        address[] memory tokens,
        MigrationBridgeModule.TokenBridgeConfig[] memory configs
    ) {
        tokens = new address[](17);
        configs = new MigrationBridgeModule.TokenBridgeConfig[](17);

        // Canonical bridges (Scroll L2 -> L1)
        tokens[0] = USDC;  configs[0]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.CANONICAL, address(0), 0);
        tokens[1] = USDT;  configs[1]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.CANONICAL, address(0), 0);
        tokens[2] = WETH;  configs[2]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.CANONICAL, address(0), 0);

        // OFT bridges -> Ethereum
        tokens[3] = WEETH; configs[3]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, WEETH, ETHEREUM_EID);
        tokens[4] = ETHFI; configs[4]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, ETHFI_LZ_ADAPTER, ETHEREUM_EID);
        tokens[5] = EURC;  configs[5]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, EURC, ETHEREUM_EID);

        // Teller bridges -> Ethereum
        tokens[6]  = LIQUID_ETH; configs[6]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, LIQUID_ETH_TELLER, ETHEREUM_EID);
        tokens[7]  = LIQUID_BTC; configs[7]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, LIQUID_BTC_TELLER, ETHEREUM_EID);
        tokens[8]  = LIQUID_USD; configs[8]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, LIQUID_USD_TELLER, ETHEREUM_EID);
        tokens[9]  = EUSD;      configs[9]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, EUSD_TELLER, ETHEREUM_EID);
        tokens[10] = EBTC;      configs[10] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, EBTC_TELLER, ETHEREUM_EID);
        tokens[11] = SETHFI;    configs[11] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, SETHFI_TELLER, ETHEREUM_EID);

        // OFT bridges -> HyperEVM
        tokens[12] = WHYPE;  configs[12] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, WHYPE, HYPEREVM_EID);
        tokens[13] = BEHYPE; configs[13] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, BEHYPE, HYPEREVM_EID);

        // OFT bridge -> Optimism
        tokens[14] = FRXUSD; configs[14] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.HOP, FRXUSD, OPTIMISM_EID);

        // OFT bridge -> Optimism (Liquid Reserve)
        tokens[15] = LIQUID_RESERVE;  configs[15] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, LIQUID_RESERVE_OFT, OPTIMISM_EID);

        // Skip (not bridged)
        tokens[16] = SCR;             configs[16] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.SKIP, address(0), 0);
    }

    function test_spend() internal {
        console.log("Trying to spend...");
        address usdc = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
        uint256 amount = 100e6;
        address spenderWallet = 0xdC45DB93c3fC37272f40812bBa9C4Bad91344b46;

        address[] memory spendTokens = new address[](1);
        spendTokens[0] = usdc;
        uint256[] memory spendAmounts = new uint256[](1);
        spendAmounts[0] = amount;
        Cashback[] memory cashbacks;

        address user = 0x28a1fe58673f42Cf153A3978152125A1d3e44BeD;
        deal(usdc, user, amount);
        vm.prank(spenderWallet);
        cashModule.spend(user, keccak256("txID"), BinSponsor.Reap, spendTokens, spendAmounts, cashbacks);
        console.log("Spend successful!");
    }
}
