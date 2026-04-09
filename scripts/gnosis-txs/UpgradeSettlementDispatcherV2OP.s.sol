// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { SettlementDispatcherV2 } from "../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { BinSponsor } from "../../src/interfaces/ICashModule.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/// @title UpgradeSettlementDispatcherV2OP
/// @notice Deploys V2 implementations via CREATE3 and generates a Gnosis Safe upgrade bundle
///         for all 4 settlement dispatchers on Optimism.
///
/// Usage:
///   # 1. Deploy implementations (broadcast)
///     source .env && ENV=mainnet forge script scripts/gnosis-txs/UpgradeSettlementDispatcherV2OP.s.sol --rpc-url optimism --broadcast  -vvv --verify
///
///   # 2. Import output JSON into Gnosis Safe UI to execute upgrades
contract UpgradeSettlementDispatcherV2OP is Utils, GnosisHelpers {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    bytes32 constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant ROLE_REGISTRY_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;

    // CREATE3 salts for deterministic impl addresses
    bytes32 constant SALT_REAP_IMPL       = keccak256("UpgradeSettlementDispatcherWithCCTP.ReapImpl");
    bytes32 constant SALT_RAIN_IMPL       = keccak256("UpgradeSettlementDispatcherWithCCTP.RainImpl");
    bytes32 constant SALT_PIX_IMPL        = keccak256("UpgradeSettlementDispatcherWithCCTP.PixImpl");
    bytes32 constant SALT_CARD_ORDER_IMPL = keccak256("UpgradeSettlementDispatcherWithCCTP.CardOrderImpl");

    // Liquid USD + Boring Queue
    address constant LIQUID_USD              = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address constant LIQUID_USD_BORING_QUEUE = 0x38FC1BA73b7ED289955a07d9F11A85b6E388064A;

    // Frax infrastructure (OP)
    address constant FRAX_USD        = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
    address constant FRAX_CUSTODIAN  = 0x8C81eda18b8F1cF5AdB4f2dcDb010D0B707fd940;
    address constant FRAX_REMOTE_HOP = 0x31D982ebd82Ad900358984bd049207A4c2468640;

    // Generated via Frax API — per-sponsor deposit addresses
    // https://api-net.frax.com/fetchAddress?targetEid=30111&beneficiary=<SETTLEMENT_DISPATCHER_ADDRESS>
    address constant FRAX_DEPOSIT_REAP       = 0xdeAD11e5df3defa3FE2EF71592bE6be53C5FEA44;
    address constant FRAX_DEPOSIT_RAIN       = 0xBF0b6cC19cB93EdC3162cc3293129069A7D61E75;
    address constant FRAX_DEPOSIT_PIX        = 0x9409e5a271b988158D48dF9c5f626ceE1b3EB59C;
    address constant FRAX_DEPOSIT_CARD_ORDER = 0x23e54D73DbEC7d811F2d672Ba755DE04d4EedCd2;

    address constant USDC_OP              = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant USDT_OP              = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;

    // RAIN settlement recipient on OP (JV gave)
    address constant SETTLEMENT_RECIPIENT = 0xe04031f03DeB0aD7010C5AD0D70e9f1611Aa85DD;

    // CCTP (PIX USDC → Base)
    address constant CCTP_TOKEN_MESSENGER    = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    uint32 constant CCTP_DEST_DOMAIN_BASE    = 6;
    uint256 constant CCTP_MAX_FEE            = 0;
    uint32 constant CCTP_MIN_FINALITY        = 2000;
    address constant PIX_CCTP_RECIPIENT_BASE = 0xC6a422C4e3bE35d5191862259Ac0192e4B2aB104;

    address constant DATA_PROVIDER = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address constant ROLE_REGISTRY = 0x5C1E3D653fcbC54Ae25c2AD9d59548D2082C687B;
    address constant REAP_PROXY = 0x9623e86Df854FF3b48F7B4079a516a4F64861Db2;
    address constant RAIN_PROXY = 0x50A233C4a0Bb1d7124b0224880037d35767a501C;
    address constant PIX_PROXY = 0x95aaddD43b6edF838ec486E9f9814787212Bf42D;
    address constant CARD_ORDER_PROXY = 0xb14FDfd7D2cfFb6Cc6953C1b80F1B1d12c2F766a;

    function run() public {
        string memory chainId = vm.toString(block.chainid);

        address safeAddress = RoleRegistry(ROLE_REGISTRY).owner();
        console.log("Safe (RoleRegistry owner):", safeAddress);
        console.log("DataProvider:", DATA_PROVIDER);

        // ── 1. Deploy implementations via CREATE3 ──
        console.log("");
        console.log("=== Deploying V2 Implementations ===");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        address reapImpl      = deployCreate3(abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.Reap, DATA_PROVIDER)), SALT_REAP_IMPL);
        address rainImpl      = deployCreate3(abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.Rain, DATA_PROVIDER)), SALT_RAIN_IMPL);
        address pixImpl       = deployCreate3(abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.PIX, DATA_PROVIDER)), SALT_PIX_IMPL);
        address cardOrderImpl = deployCreate3(abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.CardOrder, DATA_PROVIDER)), SALT_CARD_ORDER_IMPL);

        vm.stopBroadcast();

        console.log("  Reap impl:      ", reapImpl);
        console.log("  Rain impl:      ", rainImpl);
        console.log("  PIX impl:       ", pixImpl);
        console.log("  CardOrder impl: ", cardOrderImpl);

        // Verify predicted addresses match
        require(reapImpl == CREATE3.predictDeterministicAddress(SALT_REAP_IMPL, NICKS_FACTORY), "Reap impl address mismatch");
        require(rainImpl == CREATE3.predictDeterministicAddress(SALT_RAIN_IMPL, NICKS_FACTORY), "Rain impl address mismatch");
        require(pixImpl == CREATE3.predictDeterministicAddress(SALT_PIX_IMPL, NICKS_FACTORY), "PIX impl address mismatch");
        require(cardOrderImpl == CREATE3.predictDeterministicAddress(SALT_CARD_ORDER_IMPL, NICKS_FACTORY), "CardOrder impl address mismatch");

        // ── 2. Build Gnosis Safe upgrade bundle ──
        console.log("");
        console.log("=== Building Gnosis Upgrade Bundle ===");

        string memory txs = _getGnosisHeader(chainId, addressToHex(safeAddress));

        // Upgrade proxies
        txs = string(abi.encodePacked(txs, _upgradeTransaction(REAP_PROXY, reapImpl, false)));
        txs = string(abi.encodePacked(txs, _upgradeTransaction(RAIN_PROXY, rainImpl, false)));
        txs = string(abi.encodePacked(txs, _upgradeTransaction(PIX_PROXY, pixImpl, false)));
        txs = string(abi.encodePacked(txs, _upgradeTransaction(CARD_ORDER_PROXY, cardOrderImpl, false)));

        // Frax config (per-sponsor deposit addresses)
        txs = _addFraxConfigTransactions(txs, REAP_PROXY, RAIN_PROXY, PIX_PROXY, CARD_ORDER_PROXY);

        // Liquid USD boring queue (all 4 dispatchers)
        txs = _addLiquidQueueTransactions(txs, REAP_PROXY, RAIN_PROXY, PIX_PROXY, CARD_ORDER_PROXY);

        // Settlement recipients for USDC + USDT (3 dispatchers excluding pix)
        txs = _addSettlementRecipientTransactions(txs, REAP_PROXY, RAIN_PROXY, CARD_ORDER_PROXY);

        // CCTP config for PIX dispatcher (USDC → Base)
        txs = _addPixCCTPTransactions(txs);

        string memory path = string.concat("./output/UpgradeSettlementDispatcherV2OP-", chainId, ".json");
        vm.writeFile(path, txs);
        console.log("  Bundle written to:", path);

        // ── 3. Simulate the bundle ──
        console.log("");
        console.log("=== Simulating Gnosis Bundle ===");
        executeGnosisTransactionBundle(path);
        console.log("  Simulation OK");

        // ── 4. Post-upgrade verification ──
        console.log("");
        console.log("=== Post-Upgrade Verification ===");

        _verifyProxy("Reap", REAP_PROXY, reapImpl, ROLE_REGISTRY);
        _verifyProxy("Rain", RAIN_PROXY, rainImpl, ROLE_REGISTRY);
        _verifyProxy("PIX", PIX_PROXY, pixImpl, ROLE_REGISTRY);
        _verifyProxy("CardOrder", CARD_ORDER_PROXY, cardOrderImpl, ROLE_REGISTRY);

        // Verify Frax config
        _verifyFraxConfig("Reap", REAP_PROXY, FRAX_DEPOSIT_REAP);
        _verifyFraxConfig("Rain", RAIN_PROXY, FRAX_DEPOSIT_RAIN);
        _verifyFraxConfig("PIX", PIX_PROXY, FRAX_DEPOSIT_PIX);
        _verifyFraxConfig("CardOrder", CARD_ORDER_PROXY, FRAX_DEPOSIT_CARD_ORDER);

        // Verify Liquid queue
        _verifyLiquidQueue("Reap", REAP_PROXY);
        _verifyLiquidQueue("Rain", RAIN_PROXY);
        _verifyLiquidQueue("PIX", PIX_PROXY);
        _verifyLiquidQueue("CardOrder", CARD_ORDER_PROXY);

        // Verify settlement recipients
        _verifySettlementRecipients("Reap", REAP_PROXY);
        _verifySettlementRecipients("Rain", RAIN_PROXY);
        _verifySettlementRecipients("CardOrder", CARD_ORDER_PROXY);

        // Verify PIX CCTP config
        _verifyPixCCTP();

        // Rule 6: verify ownership unchanged
        address currentOwner = RoleRegistry(ROLE_REGISTRY).owner();
        require(currentOwner == safeAddress, "CRITICAL: RoleRegistry owner changed!");
        console.log("  [OK] RoleRegistry owner unchanged:", currentOwner);

        console.log("");
        console.log("=== ALL CHECKS PASSED ===");
    }

    // ═══════════════════════════════════════════════════════════════
    //  CREATE3 deployment (idempotent)
    // ═══════════════════════════════════════════════════════════════

    function deployCreate3(bytes memory creationCode, bytes32 _salt) internal returns (address deployed) {
        deployed = CREATE3.predictDeterministicAddress(_salt, NICKS_FACTORY);

        if (deployed.code.length > 0) {
            console.log("  [SKIP] already deployed at", deployed);
            return deployed;
        }

        address proxy = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", NICKS_FACTORY, _salt, CREATE3.PROXY_INITCODE_HASH)))));

        bool ok;
        if (proxy.code.length == 0) {
            (ok,) = NICKS_FACTORY.call(abi.encodePacked(_salt, hex"67363d3d37363d34f03d5260086018f3"));
            require(ok, "CREATE3 proxy deploy failed");
        }

        (ok,) = proxy.call(creationCode);
        require(ok, "CREATE3 contract deploy failed");

        require(deployed.code.length > 0, "CREATE3 deployment verification failed");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Gnosis transaction helpers
    // ═══════════════════════════════════════════════════════════════

    function _upgradeTransaction(address proxy, address impl, bool isLast) internal pure returns (string memory) {
        string memory data = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, impl, ""));
        return _getGnosisTransaction(addressToHex(proxy), data, "0", isLast);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Config transaction builders
    // ═══════════════════════════════════════════════════════════════

    function _addFraxConfigTransactions(
        string memory txs,
        address reapProxy,
        address rainProxy,
        address pixProxy,
        address cardOrderProxy
    ) internal pure returns (string memory) {
        string memory fraxData;

        fraxData = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setFraxConfig.selector, FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_REAP));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(reapProxy), fraxData, "0", false)));

        fraxData = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setFraxConfig.selector, FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_RAIN));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(rainProxy), fraxData, "0", false)));

        fraxData = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setFraxConfig.selector, FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_PIX));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(pixProxy), fraxData, "0", false)));

        fraxData = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setFraxConfig.selector, FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_CARD_ORDER));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cardOrderProxy), fraxData, "0", false)));

        return txs;
    }

    function _addLiquidQueueTransactions(
        string memory txs,
        address reapProxy,
        address rainProxy,
        address pixProxy,
        address cardOrderProxy
    ) internal pure returns (string memory) {
        string memory queueData = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setLiquidAssetWithdrawQueue.selector, LIQUID_USD, LIQUID_USD_BORING_QUEUE));

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(reapProxy), queueData, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(rainProxy), queueData, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(pixProxy), queueData, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cardOrderProxy), queueData, "0", false)));

        return txs;
    }

    function _addSettlementRecipientTransactions(
        string memory txs,
        address reapProxy,
        address rainProxy,
        address cardOrderProxy
    ) internal pure returns (string memory) {
        address[] memory tokens = new address[](2);
        tokens[0] = USDC_OP;
        tokens[1] = USDT_OP;

        address[] memory recipients = new address[](2);
        recipients[0] = SETTLEMENT_RECIPIENT;
        recipients[1] = SETTLEMENT_RECIPIENT;

        string memory data = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setSettlementRecipients.selector, tokens, recipients));

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(reapProxy), data, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(rainProxy), data, "0", false)));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cardOrderProxy), data, "0", false)));

        return txs;
    }

    function _addPixCCTPTransactions(string memory txs) internal pure returns (string memory) {
        // 1. Set CCTP config on PIX dispatcher
        string memory cctpConfigData = iToHex(abi.encodeWithSelector(
            SettlementDispatcherV2.setCCTPConfig.selector,
            CCTP_TOKEN_MESSENGER, CCTP_DEST_DOMAIN_BASE, CCTP_MAX_FEE, CCTP_MIN_FINALITY
        ));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(PIX_PROXY), cctpConfigData, "0", false)));

        // 2. Set USDC destination data on PIX to use CCTP → Base
        address[] memory tokens = new address[](1);
        tokens[0] = USDC_OP;

        SettlementDispatcherV2.DestinationData[] memory destDatas = new SettlementDispatcherV2.DestinationData[](1);
        destDatas[0] = SettlementDispatcherV2.DestinationData({
            destEid: 0,
            destRecipient: PIX_CCTP_RECIPIENT_BASE,
            stargate: address(0),
            useCanonicalBridge: false,
            minGasLimit: 0,
            isOFT: false,
            remoteToken: address(0),
            useCCTP: true
        });

        string memory destData = iToHex(abi.encodeWithSelector(
            SettlementDispatcherV2.setDestinationData.selector,
            tokens, destDatas
        ));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(PIX_PROXY), destData, "0", true)));

        return txs;
    }

    // ═══════════════════════════════════════════════════════════════
    //  Post-upgrade verification
    // ═══════════════════════════════════════════════════════════════

    function _verifyProxy(string memory name, address proxy, address expectedImpl, address expectedRoleRegistry) internal view {
        // Check EIP-1967 impl slot matches the CREATE3-deployed impl
        address actualImpl = address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
        require(actualImpl == expectedImpl, string.concat(name, ": impl slot mismatch - possible hijack"));
        require(actualImpl.code.length > 0, string.concat(name, ": impl has no code"));

        // Check roleRegistry slot points to our RoleRegistry
        address storedRR = address(uint160(uint256(vm.load(proxy, ROLE_REGISTRY_SLOT))));
        require(storedRR == expectedRoleRegistry, string.concat(name, ": roleRegistry mismatch - possible hijack"));

        console.log(string.concat("  [OK] ", name, " impl="), actualImpl);
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
        address usdcRecipient = sd.getSettlementRecipient(USDC_OP);
        address usdtRecipient = sd.getSettlementRecipient(USDT_OP);
        require(usdcRecipient == SETTLEMENT_RECIPIENT, string.concat(name, ": USDC settlement recipient mismatch"));
        require(usdtRecipient == SETTLEMENT_RECIPIENT, string.concat(name, ": USDT settlement recipient mismatch"));
        console.log(string.concat("  [OK] ", name, " settlement recipients"));
    }

    function _verifyPixCCTP() internal view {
        SettlementDispatcherV2 sd = SettlementDispatcherV2(payable(PIX_PROXY));

        // CCTP config
        (address messenger_, uint32 domain_, uint256 maxFee_, uint32 minFinality_) = sd.getCCTPConfig();
        require(messenger_ == CCTP_TOKEN_MESSENGER, "PIX: CCTP messenger mismatch");
        require(domain_ == CCTP_DEST_DOMAIN_BASE, "PIX: CCTP domain mismatch");
        require(maxFee_ == CCTP_MAX_FEE, "PIX: CCTP maxFee mismatch");
        require(minFinality_ == CCTP_MIN_FINALITY, "PIX: CCTP minFinality mismatch");
        console.log("  [OK] PIX CCTP config");

        // USDC destination data uses CCTP
        SettlementDispatcherV2.DestinationData memory dest = sd.destinationData(USDC_OP);
        require(dest.useCCTP == true, "PIX: USDC not set to CCTP");
        require(dest.destRecipient == PIX_CCTP_RECIPIENT_BASE, "PIX: USDC CCTP recipient mismatch");
        console.log("  [OK] PIX USDC destination -> CCTP Base");
    }
}
