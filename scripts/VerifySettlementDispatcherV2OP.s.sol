// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";
import { SettlementDispatcherV2 } from "../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { BinSponsor } from "../src/interfaces/ICashModule.sol";
import { ContractCodeChecker } from "./utils/ContractCodeChecker.sol";
import { GnosisHelpers } from "./utils/GnosisHelpers.sol";
import { Utils } from "./utils/Utils.sol";

/// @title VerifySettlementDispatcherV2OP
/// @notice Post-deployment verification for the SettlementDispatcherV2 upgrade on Optimism.
///         Reverts on any failed check so CI/scripts can rely on exit code.
///
/// Usage:
///   source .env && ENV=mainnet forge script scripts/VerifySettlementDispatcherV2OP.s.sol --rpc-url optimism
contract VerifySettlementDispatcherV2OP is Utils, GnosisHelpers, ContractCodeChecker {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    bytes32 constant EIP1967_IMPL_SLOT   = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant OZ_INIT_SLOT        = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 constant ROLE_REGISTRY_SLOT  = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;

    // Must match salts in UpgradeSettlementDispatcherV2OP.s.sol
    bytes32 constant SALT_REAP_IMPL       = keccak256("UpgradeSettlementDispatcherV2.ReapImpl");
    bytes32 constant SALT_RAIN_IMPL       = keccak256("UpgradeSettlementDispatcherV2.RainImpl");
    bytes32 constant SALT_PIX_IMPL        = keccak256("UpgradeSettlementDispatcherV2.PixImpl");
    bytes32 constant SALT_CARD_ORDER_IMPL = keccak256("UpgradeSettlementDispatcherV2.CardOrderImpl");

    address constant ROLE_REGISTRY = 0x5C1E3D653fcbC54Ae25c2AD9d59548D2082C687B;
    address constant DATA_PROVIDER = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address constant REAP_PROXY = 0x9623e86Df854FF3b48F7B4079a516a4F64861Db2;
    address constant RAIN_PROXY = 0x50A233C4a0Bb1d7124b0224880037d35767a501C;
    address constant PIX_PROXY = 0x95aaddD43b6edF838ec486E9f9814787212Bf42D;
    address constant CARD_ORDER_PROXY = 0xb14FDfd7D2cfFb6Cc6953C1b80F1B1d12c2F766a;

    // Frax infrastructure (OP) — must match UpgradeSettlementDispatcherV2OP.s.sol
    address constant FRAX_USD        = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
    address constant FRAX_CUSTODIAN  = 0x8C81eda18b8F1cF5AdB4f2dcDb010D0B707fd940;
    address constant FRAX_REMOTE_HOP = 0x31D982ebd82Ad900358984bd049207A4c2468640;

    // Generated via Frax API — per-sponsor deposit addresses
    // https://api-net.frax.com/fetchAddress?targetEid=30111&beneficiary=<SETTLEMENT_DISPATCHER_ADDRESS>
    address constant FRAX_DEPOSIT_REAP       = 0xdeAD11e5df3defa3FE2EF71592bE6be53C5FEA44;
    address constant FRAX_DEPOSIT_RAIN       = 0xBF0b6cC19cB93EdC3162cc3293129069A7D61E75;
    address constant FRAX_DEPOSIT_PIX        = 0x9409e5a271b988158D48dF9c5f626ceE1b3EB59C;
    address constant FRAX_DEPOSIT_CARD_ORDER = 0x23e54D73DbEC7d811F2d672Ba755DE04d4EedCd2;

    // Liquid USD + Boring Queue
    address constant LIQUID_USD              = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address constant LIQUID_USD_BORING_QUEUE = 0x38FC1BA73b7ED289955a07d9F11A85b6E388064A;

    // Settlement recipients
    address constant USDC_OP              = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant USDT_OP              = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
    address constant SETTLEMENT_RECIPIENT = 0xe04031f03DeB0aD7010C5AD0D70e9f1611Aa85DD;

    function run() public {
        address expectedReapImpl      = CREATE3.predictDeterministicAddress(SALT_REAP_IMPL, NICKS_FACTORY);
        address expectedRainImpl      = CREATE3.predictDeterministicAddress(SALT_RAIN_IMPL, NICKS_FACTORY);
        address expectedPixImpl       = CREATE3.predictDeterministicAddress(SALT_PIX_IMPL, NICKS_FACTORY);
        address expectedCardOrderImpl = CREATE3.predictDeterministicAddress(SALT_CARD_ORDER_IMPL, NICKS_FACTORY);

        console.log("=============================================");
        console.log("  Verify SettlementDispatcherV2 OP Upgrade");
        console.log("=============================================");
        console.log("Chain ID:", block.chainid);
        console.log("RoleRegistry:", ROLE_REGISTRY);
        console.log("DataProvider:", DATA_PROVIDER);
        console.log("");

        // ── 0. If impls not deployed or upgrade not executed, simulate the full bundle ──
        if (expectedReapImpl.code.length == 0 || _currentImpl(REAP_PROXY) != expectedReapImpl) {
            console.log("=== Upgrade not yet executed - simulating ===");
            executeGnosisTransactionBundle('./output/UpgradeSettlementDispatcherV2OP-10.json');
            console.log("");
        }

        // ── 1. Implementation existence ──
        console.log("--- 1. Implementation existence ---");
        require(expectedReapImpl.code.length > 0, "Reap impl has no code");
        console.log("  [OK] Reap impl:", expectedReapImpl);
        require(expectedRainImpl.code.length > 0, "Rain impl has no code");
        console.log("  [OK] Rain impl:", expectedRainImpl);
        require(expectedPixImpl.code.length > 0, "PIX impl has no code");
        console.log("  [OK] PIX impl:", expectedPixImpl);
        require(expectedCardOrderImpl.code.length > 0, "CardOrder impl has no code");
        console.log("  [OK] CardOrder impl:", expectedCardOrderImpl);

        // ── 2. EIP-1967 impl slots match CREATE3-predicted addresses ──
        console.log("");
        console.log("--- 2. EIP-1967 impl slots ---");
        _verifyImplSlot("Reap", REAP_PROXY, expectedReapImpl);
        _verifyImplSlot("Rain", RAIN_PROXY, expectedRainImpl);
        _verifyImplSlot("PIX", PIX_PROXY, expectedPixImpl);
        _verifyImplSlot("CardOrder", CARD_ORDER_PROXY, expectedCardOrderImpl);

        // ── 3. Initialization ──
        console.log("");
        console.log("--- 3. Initialization ---");
        _verifyInitialized("Reap", REAP_PROXY);
        _verifyInitialized("Rain", RAIN_PROXY);
        _verifyInitialized("PIX", PIX_PROXY);
        _verifyInitialized("CardOrder", CARD_ORDER_PROXY);

        // ── 4. RoleRegistry references (hijack detection) ──
        console.log("");
        console.log("--- 4. RoleRegistry references ---");
        _verifyRoleRegistry("Reap", REAP_PROXY, ROLE_REGISTRY);
        _verifyRoleRegistry("Rain", RAIN_PROXY, ROLE_REGISTRY);
        _verifyRoleRegistry("PIX", PIX_PROXY, ROLE_REGISTRY);
        _verifyRoleRegistry("CardOrder", CARD_ORDER_PROXY, ROLE_REGISTRY);
        address owner = RoleRegistry(ROLE_REGISTRY).owner();
        require(owner != address(0), "RoleRegistry owner is zero");
        console.log("  [OK] RoleRegistry owner:", owner);

        // ── 5. Immutable constructor params ──
        console.log("");
        console.log("--- 5. Constructor params ---");
        _verifyConstructorParams("Reap", REAP_PROXY, DATA_PROVIDER);
        _verifyConstructorParams("Rain", RAIN_PROXY, DATA_PROVIDER);
        _verifyConstructorParams("PIX", PIX_PROXY, DATA_PROVIDER);
        _verifyConstructorParams("CardOrder", CARD_ORDER_PROXY, DATA_PROVIDER);

        // ── 6. Bytecode verification ──
        console.log("");
        console.log("--- 6. Bytecode verification ---");
        _verifyBytecode("Reap", expectedReapImpl, BinSponsor.Reap);
        _verifyBytecode("Rain", expectedRainImpl, BinSponsor.Rain);
        _verifyBytecode("PIX", expectedPixImpl, BinSponsor.PIX);
        _verifyBytecode("CardOrder", expectedCardOrderImpl, BinSponsor.CardOrder);

        // ── 7. Frax config ──
        console.log("");
        console.log("--- 6. Frax config ---");
        _verifyFraxConfig("Reap", REAP_PROXY, FRAX_DEPOSIT_REAP);
        _verifyFraxConfig("Rain", RAIN_PROXY, FRAX_DEPOSIT_RAIN);
        _verifyFraxConfig("PIX", PIX_PROXY, FRAX_DEPOSIT_PIX);
        _verifyFraxConfig("CardOrder", CARD_ORDER_PROXY, FRAX_DEPOSIT_CARD_ORDER);

        // ── 8. Liquid queue ──
        console.log("");
        console.log("--- 8. Liquid queue ---");
        _verifyLiquidQueue("Reap", REAP_PROXY);
        _verifyLiquidQueue("Rain", RAIN_PROXY);
        _verifyLiquidQueue("PIX", PIX_PROXY);
        _verifyLiquidQueue("CardOrder", CARD_ORDER_PROXY);

        // ── 9. Settlement recipients ──
        console.log("");
        console.log("--- 9. Settlement recipients ---");
        _verifySettlementRecipients("Reap", REAP_PROXY);
        _verifySettlementRecipients("Rain", RAIN_PROXY);
        _verifySettlementRecipients("PIX", PIX_PROXY);
        _verifySettlementRecipients("CardOrder", CARD_ORDER_PROXY);

        console.log("");
        console.log("=============================================");
        console.log("  ALL CHECKS PASSED");
        console.log("=============================================");
    }

    function _verifyImplSlot(string memory name, address proxy, address expectedImpl) internal view {
        address actualImpl = address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
        require(actualImpl == expectedImpl, string.concat(name, ": impl slot mismatch - possible hijack"));
        console.log(string.concat("  [OK] ", name, " impl="), actualImpl);
    }

    function _verifyInitialized(string memory name, address proxy) internal view {
        uint256 initVersion = uint256(vm.load(proxy, OZ_INIT_SLOT));
        require(initVersion > 0, string.concat(name, ": NOT initialized"));
        console.log(string.concat("  [OK] ", name, " initialized (v=", vm.toString(initVersion), ")"));
    }

    function _verifyRoleRegistry(string memory name, address proxy, address expectedRR) internal view {
        address storedRR = address(uint160(uint256(vm.load(proxy, ROLE_REGISTRY_SLOT))));
        require(storedRR == expectedRR, string.concat(name, ": roleRegistry mismatch - possible hijack"));
        console.log(string.concat("  [OK] ", name, " roleRegistry"));
    }

    function _verifyConstructorParams(string memory name, address proxy, address expectedDataProvider) internal view {
        SettlementDispatcherV2 sd = SettlementDispatcherV2(payable(proxy));
        require(address(sd.dataProvider()) == expectedDataProvider, string.concat(name, ": dataProvider mismatch"));
        console.log(string.concat("  [OK] ", name, " dataProvider="), expectedDataProvider);
    }

    function _verifyFraxConfig(string memory name, address proxy, address expectedDeposit) internal view {
        SettlementDispatcherV2 sd = SettlementDispatcherV2(payable(proxy));
        (address fraxUsd_, address custodian_, address remoteHop_, address deposit_) = sd.getFraxConfig();
        require(fraxUsd_ == FRAX_USD, string.concat(name, ": fraxUsd mismatch"));
        require(custodian_ == FRAX_CUSTODIAN, string.concat(name, ": custodian mismatch"));
        require(remoteHop_ == FRAX_REMOTE_HOP, string.concat(name, ": remoteHop mismatch"));
        require(deposit_ == expectedDeposit, string.concat(name, ": frax deposit mismatch"));
        console.log(string.concat("  [OK] ", name, " frax config"));
    }

    function _verifyLiquidQueue(string memory name, address proxy) internal view {
        SettlementDispatcherV2 sd = SettlementDispatcherV2(payable(proxy));
        address queue = sd.getLiquidAssetWithdrawQueue(LIQUID_USD);
        require(queue == LIQUID_USD_BORING_QUEUE, string.concat(name, ": liquid queue mismatch"));
        console.log(string.concat("  [OK] ", name, " liquid queue"));
    }

    function _verifySettlementRecipients(string memory name, address proxy) internal view {
        SettlementDispatcherV2 sd = SettlementDispatcherV2(payable(proxy));
        require(sd.getSettlementRecipient(USDC_OP) == SETTLEMENT_RECIPIENT, string.concat(name, ": USDC recipient mismatch"));
        require(sd.getSettlementRecipient(USDT_OP) == SETTLEMENT_RECIPIENT, string.concat(name, ": USDT recipient mismatch"));
        console.log(string.concat("  [OK] ", name, " settlement recipients"));
    }

    function _verifyBytecode(string memory name, address onChainImpl, BinSponsor binSponsor) internal {
        SettlementDispatcherV2 localDeploy = new SettlementDispatcherV2(binSponsor, DATA_PROVIDER);
        console.log(string.concat("  ", name, ": comparing on-chain impl vs local deploy..."));
        verifyContractByteCodeMatch(onChainImpl, address(localDeploy));
        console.log(string.concat("  [OK] ", name, " bytecode match"));
    }

    function _currentImpl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
    }
}
