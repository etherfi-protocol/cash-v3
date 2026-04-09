// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { SettlementDispatcherV2 } from "../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";
import { BinSponsor } from "../src/interfaces/ICashModule.sol";
import { Utils } from "./utils/Utils.sol";

/// @title UpgradeSettlementDispatcherV2OPDev
/// @notice EOA broadcast script to upgrade settlement dispatchers (Reap + Rain) on OP dev.
///         Deploys V2 impls via CREATE3, upgrades proxies, sets Frax / Liquid / settlement config.
///
/// Usage:
///   source .env && ENV=dev forge script scripts/UpgradeSettlementDispatcherV2OPDev.s.sol \
///     --rpc-url $OPTIMISM_RPC --broadcast --account deployer
contract UpgradeSettlementDispatcherV2OPDev is Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    bytes32 constant EIP1967_IMPL_SLOT  = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant ROLE_REGISTRY_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;

    // CREATE3 salts (dev-specific to avoid collision with mainnet)
    bytes32 constant SALT_REAP_IMPL = keccak256("UpgradeSettlementDispatcherV2OPDev.ReapImpl");
    bytes32 constant SALT_RAIN_IMPL = keccak256("UpgradeSettlementDispatcherV2OPDev.RainImpl");
    bytes32 constant SALT_PIX_IMPL = keccak256("UpgradeSettlementDispatcherV2OPDev.PixImpl");
    bytes32 constant SALT_CARD_ORDER_IMPL = keccak256("UpgradeSettlementDispatcherV2OPDev.CardOrderImpl");

    // Dev deployment addresses
    address constant DATA_PROVIDER = 0x4a9c44c97BBf6079db37C4769AebE425bBcDD09a;
    address constant ROLE_REGISTRY = 0xa322a04d1e2Cb44672473740F9F35B057FA29CFB;
    address constant REAP_PROXY    = 0xea6e574886797A65eD22CcF2307e48a83C355771;
    address constant RAIN_PROXY    = 0x26d90676C6aeF2a09Cf383af499cc67E9D6ad7CA;
    address constant PIX_PROXY     = 0xe61c5A65d26fDf27260cf34281a691a227C34bA3;
    address constant CARD_ORDER_PROXY = 0x8e7AB8E9037FBd6C91f3758c6c9E2abf92675Aea;

    // Liquid USD + Boring Queue
    address constant LIQUID_USD              = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address constant LIQUID_USD_BORING_QUEUE = 0x38FC1BA73b7ED289955a07d9F11A85b6E388064A;

    // Frax infrastructure (OP)
    address constant FRAX_USD        = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
    address constant FRAX_CUSTODIAN  = 0x8C81eda18b8F1cF5AdB4f2dcDb010D0B707fd940;
    address constant FRAX_REMOTE_HOP = 0x31D982ebd82Ad900358984bd049207A4c2468640;

    address constant FRAX_DEPOSIT_REAP = 0x045F9630D94f1767217C1118D2BFcD3FBCB704f1;
    address constant FRAX_DEPOSIT_RAIN = 0xF864CAe2985D22e84e2e13593a0f8Aa965fAC8CF;
    address constant FRAX_DEPOSIT_PIX = 0x62D1C411651Cd2Bf549e0a0b0292E218E2697B5f;
    address constant FRAX_DEPOSIT_CARD_ORDER = 0x3713256325e1bc451f11b2c7E44d8291f86bb870;

    // Settlement
    address constant USDC_OP              = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant USDT_OP              = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
    address constant SETTLEMENT_RECIPIENT = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;

    function run() public {
        address owner = RoleRegistry(ROLE_REGISTRY).owner();
        console.log("RoleRegistry owner:", owner);
        console.log("DataProvider:", DATA_PROVIDER);

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // ── 1. Deploy implementations via CREATE3 ──
        console.log("");
        console.log("=== Deploying V2 Implementations ===");

        address reapImpl = deployCreate3(
            abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.Reap, DATA_PROVIDER)),
            SALT_REAP_IMPL
        );
        address rainImpl = deployCreate3(
            abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.Rain, DATA_PROVIDER)),
            SALT_RAIN_IMPL
        );
        address pixImpl = deployCreate3(
            abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.PIX, DATA_PROVIDER)),
            SALT_PIX_IMPL
        );
        address cardOrderImpl = deployCreate3(
            abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.CardOrder, DATA_PROVIDER)),
            SALT_CARD_ORDER_IMPL
        );

        console.log("  Reap impl:", reapImpl);
        console.log("  Rain impl:", rainImpl);

        // ── 2. Upgrade proxies ──
        console.log("");
        console.log("=== Upgrading Proxies ===");

        UUPSUpgradeable(REAP_PROXY).upgradeToAndCall(reapImpl, "");
        UUPSUpgradeable(RAIN_PROXY).upgradeToAndCall(rainImpl, "");
        UUPSUpgradeable(PIX_PROXY).upgradeToAndCall(pixImpl, "");
        UUPSUpgradeable(CARD_ORDER_PROXY).upgradeToAndCall(cardOrderImpl, "");

        console.log("  [OK] Reap upgraded");
        console.log("  [OK] Rain upgraded");
        console.log("  [OK] Pix upgraded");
        console.log("  [OK] CardOrder upgraded");
        // ── 3. Set Frax config ──
        console.log("");
        console.log("=== Setting Frax Config ===");

        SettlementDispatcherV2(payable(REAP_PROXY)).setFraxConfig(FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_REAP);
        SettlementDispatcherV2(payable(RAIN_PROXY)).setFraxConfig(FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_RAIN);
        SettlementDispatcherV2(payable(PIX_PROXY)).setFraxConfig(FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_PIX);
        SettlementDispatcherV2(payable(CARD_ORDER_PROXY)).setFraxConfig(FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_CARD_ORDER);
        console.log("  [OK] Frax config set");

        // ── 4. Set Liquid USD boring queue ──
        console.log("");
        console.log("=== Setting Liquid Queue ===");

        SettlementDispatcherV2(payable(REAP_PROXY)).setLiquidAssetWithdrawQueue(LIQUID_USD, LIQUID_USD_BORING_QUEUE);
        SettlementDispatcherV2(payable(RAIN_PROXY)).setLiquidAssetWithdrawQueue(LIQUID_USD, LIQUID_USD_BORING_QUEUE);
        SettlementDispatcherV2(payable(PIX_PROXY)).setLiquidAssetWithdrawQueue(LIQUID_USD, LIQUID_USD_BORING_QUEUE);
        SettlementDispatcherV2(payable(CARD_ORDER_PROXY)).setLiquidAssetWithdrawQueue(LIQUID_USD, LIQUID_USD_BORING_QUEUE);
        console.log("  [OK] Liquid queue set");

        // ── 5. Set settlement recipients ──
        console.log("");
        console.log("=== Setting Settlement Recipients ===");

        address[] memory tokens = new address[](2);
        tokens[0] = USDC_OP;
        tokens[1] = USDT_OP;

        address[] memory recipients = new address[](2);
        recipients[0] = SETTLEMENT_RECIPIENT;
        recipients[1] = SETTLEMENT_RECIPIENT;

        SettlementDispatcherV2(payable(REAP_PROXY)).setSettlementRecipients(tokens, recipients);
        SettlementDispatcherV2(payable(RAIN_PROXY)).setSettlementRecipients(tokens, recipients);
        SettlementDispatcherV2(payable(PIX_PROXY)).setSettlementRecipients(tokens, recipients);
        SettlementDispatcherV2(payable(CARD_ORDER_PROXY)).setSettlementRecipients(tokens, recipients);
        console.log("  [OK] Settlement recipients set");

        vm.stopBroadcast();

        // ── 6. Post-upgrade verification ──
        console.log("");
        console.log("=== Post-Upgrade Verification ===");

        _verify("Reap", REAP_PROXY, reapImpl, FRAX_DEPOSIT_REAP);
        _verify("Rain", RAIN_PROXY, rainImpl, FRAX_DEPOSIT_RAIN);
        _verify("Pix", PIX_PROXY, pixImpl, FRAX_DEPOSIT_PIX);
        _verify("CardOrder", CARD_ORDER_PROXY, cardOrderImpl, FRAX_DEPOSIT_CARD_ORDER);

        address currentOwner = RoleRegistry(ROLE_REGISTRY).owner();
        require(currentOwner == owner, "CRITICAL: RoleRegistry owner changed!");
        console.log("  [OK] RoleRegistry owner unchanged:", currentOwner);

        console.log("");
        console.log("=== ALL CHECKS PASSED ===");
    }

    // ═══════════════════════════════════════════════════════════════

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

    function _verify(string memory name, address proxy, address expectedImpl, address expectedFraxDeposit) internal view {
        // Impl slot
        address actualImpl = address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
        require(actualImpl == expectedImpl, string.concat(name, ": impl mismatch"));

        // RoleRegistry
        address storedRR = address(uint160(uint256(vm.load(proxy, ROLE_REGISTRY_SLOT))));
        require(storedRR == ROLE_REGISTRY, string.concat(name, ": roleRegistry mismatch"));

        // DataProvider
        SettlementDispatcherV2 sd = SettlementDispatcherV2(payable(proxy));
        require(address(sd.dataProvider()) == DATA_PROVIDER, string.concat(name, ": dataProvider mismatch"));

        // Frax config
        (address fraxUsd_, address custodian_, address remoteHop_, address deposit_) = sd.getFraxConfig();
        require(fraxUsd_ == FRAX_USD && custodian_ == FRAX_CUSTODIAN && remoteHop_ == FRAX_REMOTE_HOP && deposit_ == expectedFraxDeposit, string.concat(name, ": frax config mismatch"));

        // Liquid queue
        require(sd.getLiquidAssetWithdrawQueue(LIQUID_USD) == LIQUID_USD_BORING_QUEUE, string.concat(name, ": liquid queue mismatch"));

        // Settlement recipients
        require(sd.getSettlementRecipient(USDC_OP) == SETTLEMENT_RECIPIENT, string.concat(name, ": USDC recipient mismatch"));
        require(sd.getSettlementRecipient(USDT_OP) == SETTLEMENT_RECIPIENT, string.concat(name, ": USDT recipient mismatch"));

        console.log(string.concat("  [OK] ", name, " - all checks passed"));
    }
}
