// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { ContractCodeChecker } from "./utils/ContractCodeChecker.sol";

import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";
import { CashModuleSetters } from "../src/modules/cash/CashModuleSetters.sol";
import { CashModuleCore } from "../src/modules/cash/CashModuleCore.sol";
import { PriceProvider } from "../src/oracle/PriceProvider.sol";
import { CashbackDispatcher } from "../src/cashback-dispatcher/CashbackDispatcher.sol";
import { CashLens } from "../src/modules/cash/CashLens.sol";
import { EtherFiHook } from "../src/hook/EtherFiHook.sol";
import { OpenOceanSwapModule } from "../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { EtherFiSafe } from "../src/safe/EtherFiSafe.sol";
import { EtherFiSafeFactory } from "../src/safe/EtherFiSafeFactory.sol";
import { DebtManagerCore } from "../src/debt-manager/DebtManagerCore.sol";
import { DebtManagerAdmin } from "../src/debt-manager/DebtManagerAdmin.sol";
import { DebtManagerInitializer } from "../src/debt-manager/DebtManagerInitializer.sol";
import { SettlementDispatcherV2 } from "../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { CashEventEmitter } from "../src/modules/cash/CashEventEmitter.sol";
import { TopUpDest } from "../src/top-up/TopUpDest.sol";
import { BinSponsor } from "../src/interfaces/ICashModule.sol";

/// @title Bytecode verification for OP Mainnet prod deployment
/// @notice Deploys each impl locally with the same constructor args and compares bytecode
///         against the on-chain deployed impls.
///
/// Usage:
///   forge script scripts/VerifyOptimismProdBytecode.s.sol --rpc-url <OP_RPC> -vvv
contract VerifyOptimismProdBytecode is Script, ContractCodeChecker {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    bytes32 constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // ── Predicted proxy addresses ──
    bytes32 constant SALT_DATA_PROVIDER_PROXY         = 0x307f29e4d8b2893f186304a4b3aaa5ea9e7e6cddbcd75abc4b30edb1b4c939e9;
    bytes32 constant SALT_ROLE_REGISTRY_PROXY         = 0x6cae761c5315d96c88fdeb2bdf7f689cb66abc92a4e823b7954d41f88321bd0e;
    bytes32 constant SALT_CASH_MODULE_PROXY           = 0xd485ab52f7eb6ae6746c1b5a90eb92d689d87341677d1c4a8ee974492b708e70;
    bytes32 constant SALT_PRICE_PROVIDER_PROXY        = 0xe256577e04087bb0b33fe81ae0afcee684ec2a88ff642b2d8e3facd885c4fee2;
    bytes32 constant SALT_CASHBACK_DISPATCHER_PROXY   = 0x06e587da24f92e8e0e0e16610a27705bdbee83ca07df3ace65507f0dd7f98b68;
    bytes32 constant SALT_CASH_LENS_PROXY             = 0x698110fb74c5af739d2291b8eb324ef7b3727788689e7486d7073f2aa6310bde;
    bytes32 constant SALT_HOOK_PROXY                  = 0x80709e224fc61f855f496af607a59a6e936ec718a156096af7b5b35f47de7824;
    bytes32 constant SALT_SAFE_FACTORY_PROXY          = 0x4039d84c2c2b96cb1babbf2ca5c0b7be213be8ad0110e70d6e2d570741ef168b;
    bytes32 constant SALT_DEBT_MANAGER_PROXY          = 0x6610dc15616a5f676fa3e670615ee9dfb656e8902313948c7c64a3edb3ab0a1a;
    bytes32 constant SALT_SETTLEMENT_REAP_PROXY       = 0xaa1e057d426deb6be4575e8f04f28ae380f223cdb64f3a8c75f794b692125955;
    bytes32 constant SALT_SETTLEMENT_RAIN_PROXY       = 0xe1a06328ed2194684d37568395abeed7fdc26c5b17c010b73ac6c0bd2eb84260;
    bytes32 constant SALT_SETTLEMENT_PIX_PROXY        = 0xb41c7d6d164a5805864d248441939a2d76f98a2294296f0f9c96f4fd28d8c738;
    bytes32 constant SALT_SETTLEMENT_CARD_ORDER_PROXY = 0x21f29b6246a6d23c4712db519298c542183be48de47f73d858b0a29169a32de6;
    bytes32 constant SALT_CASH_EVENT_EMITTER_PROXY    = 0xed6998f3c2ea6f567620976e6461add101a8ce47510c4c8aef17b4ec28296f84;
    bytes32 constant SALT_TOP_UP_DEST_PROXY           = 0x8572fe39434c3eb6f1e3b26d39a4f217b17bfba72ba042972cb4341f6de513eb;
    bytes32 constant SALT_OPEN_OCEAN_SWAP_MODULE      = 0xf23758838c89a5bb66a4addbe794a2f1ea17017821239e8a2195e71afc8ed6e3;
    bytes32 constant SALT_SAFE_IMPL                   = 0xff29656f33cc018695c4dadfbd883155f1ef30d667ca50827a9b9c56a50fe803;

    // ── OP Mainnet addresses (constructor args) ──
    address constant openOceanSwapRouter = 0x6352a56caadC4F1E25CD6c75970Fa768A3304e64;

    // Precomputed proxy addresses
    address dp;
    address cm;
    address ce;

    function run() public {
        require(block.chainid == 10, "Must run on OP Mainnet (chain 10)");

        dp = _proxy(SALT_DATA_PROVIDER_PROXY);
        cm = _proxy(SALT_CASH_MODULE_PROXY);
        ce = _proxy(SALT_CASH_EVENT_EMITTER_PROXY);

        console2.log("======================================");
        console2.log("  OP Mainnet Bytecode Verification");
        console2.log("======================================\n");

        _verifyCoreContracts();
        _verifyModules();
        _verifyDebtManager();
        _verifySettlementDispatchers();
        _verifyRemaining();

        console2.log("\n======================================");
        console2.log("  Bytecode Verification Complete");
        console2.log("======================================");
    }

    function _verifyCoreContracts() internal {
        console2.log("1. EtherFiDataProvider");
        verifyContractByteCodeMatch(_getImpl(dp), address(new EtherFiDataProvider()));

        console2.log("2. RoleRegistry (impl: 0xBbdfD3a5)");
        verifyContractByteCodeMatch(0xBbdfD3a5f661698f44276c8Af600B76AE9A506dC, address(new RoleRegistry(dp)));

        console2.log("3. CashModuleCore");
        verifyContractByteCodeMatch(_getImpl(cm), address(new CashModuleCore(dp)));

        console2.log("4. CashModuleSetters");
        verifyContractByteCodeMatch(
            _implCreate3(0x6ef7c305c72e716956d108ae8afca5f89a4ce45a74918b403f75d104122ba8d7),
            address(new CashModuleSetters(dp))
        );

        console2.log("5. PriceProvider");
        verifyContractByteCodeMatch(_getImpl(_proxy(SALT_PRICE_PROVIDER_PROXY)), address(new PriceProvider()));

        console2.log("6. CashbackDispatcher");
        verifyContractByteCodeMatch(_getImpl(_proxy(SALT_CASHBACK_DISPATCHER_PROXY)), address(new CashbackDispatcher(dp)));
    }

    function _verifyModules() internal {
        console2.log("7. CashLens");
        verifyContractByteCodeMatch(_getImpl(_proxy(SALT_CASH_LENS_PROXY)), address(new CashLens(cm, dp)));

        console2.log("8. EtherFiHook");
        verifyContractByteCodeMatch(_getImpl(_proxy(SALT_HOOK_PROXY)), address(new EtherFiHook(dp)));

        console2.log("9. OpenOceanSwapModule");
        verifyContractByteCodeMatch(_proxy(SALT_OPEN_OCEAN_SWAP_MODULE), address(new OpenOceanSwapModule(openOceanSwapRouter, dp)));

        console2.log("10. EtherFiSafe");
        verifyContractByteCodeMatch(_proxy(SALT_SAFE_IMPL), address(new EtherFiSafe(dp)));

        console2.log("11. EtherFiSafeFactory (impl: 0xAE143062)");
        verifyContractByteCodeMatch(0xAE143062e65EDBEBfc4EdED8a31092e3FdB496B8, address(new EtherFiSafeFactory()));
    }

    function _verifyDebtManager() internal {
        console2.log("12. DebtManagerCore (impl via CREATE3)");
        verifyContractByteCodeMatch(
            _implCreate3(0xd7d8accf3671d756a509daca0abd0356c4079376519f8b6e1796646b98b5f9bc),
            address(new DebtManagerCore(dp))
        );

        console2.log("13. DebtManagerAdmin");
        verifyContractByteCodeMatch(
            _implCreate3(0xc3a0307fe194705a7248e1e199e6a1d405af038d07b82c61a736ad23635bfc9b),
            address(new DebtManagerAdmin(dp))
        );

        console2.log("14. DebtManagerInitializer");
        verifyContractByteCodeMatch(
            _implCreate3(0x28d742794ce3c98e369e64a2f28494c25176e89a2682486b90aea435bd2a0a6f),
            address(new DebtManagerInitializer(dp))
        );
    }

    function _verifySettlementDispatchers() internal {
        console2.log("15. SettlementDispatcherV2 (Reap)");
        verifyContractByteCodeMatch(_getImpl(_proxy(SALT_SETTLEMENT_REAP_PROXY)), address(new SettlementDispatcherV2(BinSponsor.Reap, dp)));

        console2.log("16. SettlementDispatcherV2 (Rain)");
        verifyContractByteCodeMatch(_getImpl(_proxy(SALT_SETTLEMENT_RAIN_PROXY)), address(new SettlementDispatcherV2(BinSponsor.Rain, dp)));

        console2.log("17. SettlementDispatcherV2 (PIX)");
        verifyContractByteCodeMatch(_getImpl(_proxy(SALT_SETTLEMENT_PIX_PROXY)), address(new SettlementDispatcherV2(BinSponsor.PIX, dp)));

        console2.log("18. SettlementDispatcherV2 (CardOrder)");
        verifyContractByteCodeMatch(_getImpl(_proxy(SALT_SETTLEMENT_CARD_ORDER_PROXY)), address(new SettlementDispatcherV2(BinSponsor.CardOrder, dp)));
    }

    function _verifyRemaining() internal {
        console2.log("19. CashEventEmitter");
        verifyContractByteCodeMatch(_getImpl(ce), address(new CashEventEmitter(cm)));

        console2.log("20. TopUpDest");
        verifyContractByteCodeMatch(_getImpl(_proxy(SALT_TOP_UP_DEST_PROXY)), address(new TopUpDest(dp)));
    }

    function _proxy(bytes32 salt) internal pure returns (address) {
        return CREATE3.predictDeterministicAddress(salt, NICKS_FACTORY);
    }

    function _implCreate3(bytes32 salt) internal pure returns (address) {
        return CREATE3.predictDeterministicAddress(salt, NICKS_FACTORY);
    }

    function _getImpl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
    }
}
