// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { MigrationBridgeModule } from "../../src/migration/MigrationBridgeModule.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title DeployMigrationBridgeModule (Prod)
 * @notice Deploys contracts via CREATE3 with deployer key, then generates a
 *         Gnosis Safe TX bundle for the multisig to configure everything.
 *         Uses same salts as the dev script so VerifyMigrationBridgeModule works for both.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/gnosis-txs/DeployMigrationBridgeModule.s.sol \
 *     --rpc-url $SCROLL_RPC --broadcast
 */
contract DeployMigrationBridgeModule is GnosisHelpers, Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    // Deterministic salts (prod — different from dev to avoid collision on same chain)
    bytes32 constant SALT_MIGRATION_MODULE_IMPL  = keccak256("MigrationBridgeModule.Prod.Impl");
    bytes32 constant SALT_MIGRATION_MODULE_PROXY = keccak256("MigrationBridgeModule.Prod.Proxy");
    bytes32 constant SALT_HOOK_IMPL              = keccak256("MigrationBridgeModule.Prod.HookImpl");

    // ── Token addresses (Scroll) ──
    address constant USDC            = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    address constant USDT            = 0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df;
    address constant WETH            = 0x5300000000000000000000000000000000000004;
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
    address constant BEHYPE           = 0xA519AfBc91986c0e7501d7e34968FEE51CD901aC;
    address constant LIQUID_RESERVE   = 0xb7Fb3768CAAC98354EaDF514b48f28F2fE822bF0;

    address constant LIQUID_ETH_TELLER = 0x9AA79C84b79816ab920bBcE20f8f74557B514734;
    address constant LIQUID_BTC_TELLER = 0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353;
    address constant LIQUID_USD_TELLER = 0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387;
    address constant EUSD_TELLER       = 0xCc9A7620D0358a521A068B444846E3D5DebEa8fA;
    address constant EBTC_TELLER       = 0x6Ee3aaCcf9f2321E49063C4F8da775DdBd407268;
    address constant SETHFI_TELLER     = 0x35dD2463fA7a335b721400C5Ad8Ba40bD85c179b;

    address constant ETHFI_LZ_ADAPTER = 0xe0080d2F853ecDdbd81A643dC10DA075Df26fD3f;
    address constant FRAX_HOP = 0x0000006D38568b00B457580b734e0076C62de659;
    address constant LIQUID_RESERVE_OFT = 0xE5d3854736e0D513aAE2D8D708Ad94d14Fd56A6a;

    uint32 constant ETHEREUM_EID = 30_101;
    uint32 constant HYPEREVM_EID = 30_367;
    uint32 constant OPTIMISM_EID = 30_111;

    function run() public {
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();

        address dataProviderAddr = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        address hookAddr = stdJson.readAddress(deployments, ".addresses.EtherFiHook");
        address roleRegistryAddr = stdJson.readAddress(deployments, ".addresses.RoleRegistry");

        // ════════════════════════════════════════════════════════════
        //  BROADCAST: deploy via CREATE3 with deployer key
        // ════════════════════════════════════════════════════════════

        vm.startBroadcast();

        address migrationImpl = deployCreate3(
            abi.encodePacked(type(MigrationBridgeModule).creationCode, abi.encode(dataProviderAddr)),
            SALT_MIGRATION_MODULE_IMPL
        );

        MigrationBridgeModule migrationModule = MigrationBridgeModule(payable(deployCreate3(
            abi.encodePacked(
                type(UUPSProxy).creationCode,
                abi.encode(migrationImpl, abi.encodeWithSelector(MigrationBridgeModule.initialize.selector, roleRegistryAddr))
            ),
            SALT_MIGRATION_MODULE_PROXY
        )));

        address newHookImpl = deployCreate3(
            abi.encodePacked(type(EtherFiHook).creationCode, abi.encode(dataProviderAddr)),
            SALT_HOOK_IMPL
        );

        vm.stopBroadcast();

        console.log("MigrationBridgeModule impl: ", migrationImpl);
        console.log("MigrationBridgeModule proxy:", address(migrationModule));
        console.log("New EtherFiHook impl:       ", newHookImpl);

        // ════════════════════════════════════════════════════════════
        //  GNOSIS: generate TX bundle for cashControllerSafe
        // ════════════════════════════════════════════════════════════

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        // 1. Register as default module
        {
            address[] memory modules = new address[](1);
            modules[0] = address(migrationModule);
            bool[] memory shouldWhitelist = new bool[](1);
            shouldWhitelist[0] = true;

            txs = string(abi.encodePacked(txs, _getGnosisTransaction(
                addressToHex(dataProviderAddr),
                iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, modules, shouldWhitelist)),
                "0", false
            )));
        }

        // 2. Upgrade hook
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(hookAddr),
            iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, newHookImpl, "")),
            "0", false
        )));

        // 3. Set migration module on hook
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(hookAddr),
            iToHex(abi.encodeWithSelector(EtherFiHook.setMigrationModule.selector, address(migrationModule))),
            "0", false
        )));

        // 4. Grant admin role
        bytes32 adminRole = migrationModule.MIGRATION_BRIDGE_ADMIN_ROLE();
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(roleRegistryAddr),
            iToHex(abi.encodeWithSelector(IRoleRegistry.grantRole.selector, adminRole, cashControllerSafe)),
            "0", false
        )));

        // 5. Configure tokens
        (address[] memory tokens, MigrationBridgeModule.TokenBridgeConfig[] memory configs) = _getTokenConfigs();
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(address(migrationModule)),
            iToHex(abi.encodeWithSelector(MigrationBridgeModule.configureTokens.selector, tokens, configs)),
            "0", true
        )));

        vm.createDir("./output", true);
        string memory path = "./output/ConfigureMigrationBridgeModule.json";
        vm.writeFile(path, txs);
        console.log("Gnosis bundle:", path);

        executeGnosisTransactionBundle(path);
    }

    function deployCreate3(bytes memory creationCode, bytes32 salt) internal returns (address deployed) {
        deployed = CREATE3.predictDeterministicAddress(salt, NICKS_FACTORY);

        if (deployed.code.length > 0) {
            console.log("  [SKIP] already deployed at", deployed);
            return deployed;
        }

        address proxy = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", NICKS_FACTORY, salt, CREATE3.PROXY_INITCODE_HASH)))));

        bool ok;
        if (proxy.code.length == 0) {
            (ok,) = NICKS_FACTORY.call(abi.encodePacked(salt, hex"67363d3d37363d34f03d5260086018f3"));
            require(ok, "CREATE3 proxy deploy failed");
        }

        (ok,) = proxy.call(creationCode);
        require(ok, "CREATE3 contract deploy failed");
        require(deployed.code.length > 0, "CREATE3 deployment verification failed");
    }

    function _getTokenConfigs() internal pure returns (
        address[] memory tokens,
        MigrationBridgeModule.TokenBridgeConfig[] memory configs
    ) {
        tokens = new address[](17);
        configs = new MigrationBridgeModule.TokenBridgeConfig[](17);

        tokens[0] = USDC;  configs[0]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.CANONICAL, address(0), 0);
        tokens[1] = USDT;  configs[1]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.CANONICAL, address(0), 0);
        tokens[2] = WETH;  configs[2]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.CANONICAL, address(0), 0);

        tokens[3] = WEETH; configs[3]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, WEETH, ETHEREUM_EID);
        tokens[4] = ETHFI; configs[4]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, ETHFI_LZ_ADAPTER, ETHEREUM_EID);
        tokens[5] = EURC;  configs[5]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, EURC, ETHEREUM_EID);

        tokens[6]  = LIQUID_ETH; configs[6]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, LIQUID_ETH_TELLER, ETHEREUM_EID);
        tokens[7]  = LIQUID_BTC; configs[7]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, LIQUID_BTC_TELLER, ETHEREUM_EID);
        tokens[8]  = LIQUID_USD; configs[8]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, LIQUID_USD_TELLER, ETHEREUM_EID);
        tokens[9]  = EUSD;      configs[9]  = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, EUSD_TELLER, ETHEREUM_EID);
        tokens[10] = EBTC;      configs[10] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, EBTC_TELLER, ETHEREUM_EID);
        tokens[11] = SETHFI;    configs[11] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.TELLER, SETHFI_TELLER, ETHEREUM_EID);

        tokens[12] = WHYPE;  configs[12] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, WHYPE, HYPEREVM_EID);
        tokens[13] = BEHYPE; configs[13] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, BEHYPE, HYPEREVM_EID);

        tokens[14] = FRXUSD; configs[14] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, FRXUSD, OPTIMISM_EID);

        tokens[15] = SCR;             configs[15] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.SKIP, address(0), 0);
        tokens[16] = LIQUID_RESERVE;  configs[16] = MigrationBridgeModule.TokenBridgeConfig(MigrationBridgeModule.BridgeType.OFT, LIQUID_RESERVE_OFT, OPTIMISM_EID);
    }
}
