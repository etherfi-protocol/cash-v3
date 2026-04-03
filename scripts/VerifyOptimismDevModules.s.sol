// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { SettlementDispatcherV2 } from "../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { LiquidUSDLiquifierModule } from "../src/modules/etherfi/LiquidUSDLiquifier.sol";
import { EtherFiLiquidModule } from "../src/modules/etherfi/EtherFiLiquidModule.sol";
import { EtherFiLiquidModuleWithReferrer } from "../src/modules/etherfi/EtherFiLiquidModuleWithReferrer.sol";
import { StargateModule } from "../src/modules/stargate/StargateModule.sol";
import { FraxModule } from "../src/modules/frax/FraxModule.sol";
import { BinSponsor } from "../src/interfaces/ICashModule.sol";
import { Utils } from "./utils/Utils.sol";

/// @title VerifyOptimismDevModules
/// @notice Post-deployment verification for DeployOptimismDevModules.
///         Reverts on any failed check so CI/scripts can rely on exit code.
///
/// Usage:
///   ENV=dev forge script scripts/VerifyOptimismDevModules.s.sol --rpc-url $OPTIMISM_RPC
contract VerifyOptimismDevModules is Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    bytes32 constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant OZ_INIT_SLOT      = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    // Must match DeployOptimismDevModules salts exactly
    bytes32 constant SALT_SETTLEMENT_PIX_IMPL          = keccak256("DeployOptimismDevModules.SettlementPixImpl");
    bytes32 constant SALT_SETTLEMENT_PIX_PROXY         = keccak256("DeployOptimismDevModules.SettlementPixProxy");
    bytes32 constant SALT_SETTLEMENT_CARD_ORDER_IMPL   = keccak256("DeployOptimismDevModules.SettlementCardOrderImpl");
    bytes32 constant SALT_SETTLEMENT_CARD_ORDER_PROXY  = keccak256("DeployOptimismDevModules.SettlementCardOrderProxy");
    bytes32 constant SALT_LIQUIFIER_IMPL               = keccak256("DeployOptimismDevModules.LiquidUSDLiquifierImpl");
    bytes32 constant SALT_LIQUIFIER_PROXY              = keccak256("DeployOptimismDevModules.LiquidUSDLiquifierProxy");
    bytes32 constant SALT_LIQUID_MODULE                = keccak256("DeployOptimismDevModules.EtherFiLiquidModule");
    bytes32 constant SALT_LIQUID_MODULE_REFERRER       = keccak256("DeployOptimismDevModules.EtherFiLiquidModuleWithReferrer");
    bytes32 constant SALT_STARGATE_MODULE              = keccak256("DeployOptimismDevModules.StargateModule");
    bytes32 constant SALT_FRAX_MODULE                  = keccak256("DeployOptimismDevModules.FraxModule");

    // Expected external addresses
    address constant sethfi = 0x86B5780b606940Eb59A062aA85a07959518c0161;
    address constant sETHFIBoringQueue = 0xF03352da1536F31172A7F7cB092D4717DeDDd3CB;
    address constant frxUSD = 0x80Eede496655FB9047dd39d9f418d5483ED600df;

    struct Predicted {
        address pixProxy;
        address pixImpl;
        address cardOrderProxy;
        address cardOrderImpl;
        address liquifierProxy;
        address liquifierImpl;
        address liquidModule;
        address liquidModuleReferrer;
        address stargateModule;
        address fraxModule;
        address dataProvider;
        address roleRegistry;
    }

    function _predict() internal view returns (Predicted memory p) {
        p.pixProxy = CREATE3.predictDeterministicAddress(SALT_SETTLEMENT_PIX_PROXY, NICKS_FACTORY);
        p.pixImpl = CREATE3.predictDeterministicAddress(SALT_SETTLEMENT_PIX_IMPL, NICKS_FACTORY);
        p.cardOrderProxy = CREATE3.predictDeterministicAddress(SALT_SETTLEMENT_CARD_ORDER_PROXY, NICKS_FACTORY);
        p.cardOrderImpl = CREATE3.predictDeterministicAddress(SALT_SETTLEMENT_CARD_ORDER_IMPL, NICKS_FACTORY);
        p.liquifierProxy = CREATE3.predictDeterministicAddress(SALT_LIQUIFIER_PROXY, NICKS_FACTORY);
        p.liquifierImpl = CREATE3.predictDeterministicAddress(SALT_LIQUIFIER_IMPL, NICKS_FACTORY);
        p.liquidModule = CREATE3.predictDeterministicAddress(SALT_LIQUID_MODULE, NICKS_FACTORY);
        p.liquidModuleReferrer = CREATE3.predictDeterministicAddress(SALT_LIQUID_MODULE_REFERRER, NICKS_FACTORY);
        p.stargateModule = CREATE3.predictDeterministicAddress(SALT_STARGATE_MODULE, NICKS_FACTORY);
        p.fraxModule = CREATE3.predictDeterministicAddress(SALT_FRAX_MODULE, NICKS_FACTORY);

        string memory deployments = readDeploymentFile();
        p.dataProvider = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "EtherFiDataProvider"));
        p.roleRegistry = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "RoleRegistry"));
    }

    function run() public view {
        require(block.chainid == 10, "Must run on Optimism (chain ID 10)");

        Predicted memory p = _predict();

        console.log("==========================================");
        console.log("  Verify Optimism Dev Modules (Post-Deploy)");
        console.log("==========================================");
        console.log("Chain ID:", block.chainid);
        console.log("");

        _checkExistence(p);
        _checkImplSlots(p);
        _checkInitialization(p);
        _checkImmutables(p);
        _checkConfig(p);

        console.log("");
        console.log("==========================================");
        console.log("  ALL CHECKS PASSED");
        console.log("==========================================");
    }

    function _checkExistence(Predicted memory p) internal view {
        console.log("--- 1. Contract existence ---");
        require(p.pixProxy.code.length > 0, "SettlementDispatcherPix proxy has no code");
        console.log("  [OK] SettlementDispatcherPix proxy:", p.pixProxy);
        require(p.cardOrderProxy.code.length > 0, "SettlementDispatcherCardOrder proxy has no code");
        console.log("  [OK] SettlementDispatcherCardOrder proxy:", p.cardOrderProxy);
        require(p.liquifierProxy.code.length > 0, "LiquidUSDLiquifierModule proxy has no code");
        console.log("  [OK] LiquidUSDLiquifierModule proxy:", p.liquifierProxy);
        require(p.liquidModule.code.length > 0, "EtherFiLiquidModule has no code");
        console.log("  [OK] EtherFiLiquidModule:", p.liquidModule);
        require(p.liquidModuleReferrer.code.length > 0, "EtherFiLiquidModuleWithReferrer has no code");
        console.log("  [OK] EtherFiLiquidModuleWithReferrer:", p.liquidModuleReferrer);
        require(p.stargateModule.code.length > 0, "StargateModule has no code");
        console.log("  [OK] StargateModule:", p.stargateModule);
        require(p.fraxModule.code.length > 0, "FraxModule has no code");
        console.log("  [OK] FraxModule:", p.fraxModule);
    }

    function _checkImplSlots(Predicted memory p) internal view {
        console.log("");
        console.log("--- 2. Impl addresses (EIP-1967) ---");

        address actualPixImpl = address(uint160(uint256(vm.load(p.pixProxy, EIP1967_IMPL_SLOT))));
        require(actualPixImpl == p.pixImpl, "SettlementDispatcherPix impl mismatch - possible hijack");
        require(p.pixImpl.code.length > 0, "SettlementDispatcherPix impl has no code");
        console.log("  [OK] SettlementDispatcherPix impl:", actualPixImpl);

        address actualCardOrderImpl = address(uint160(uint256(vm.load(p.cardOrderProxy, EIP1967_IMPL_SLOT))));
        require(actualCardOrderImpl == p.cardOrderImpl, "SettlementDispatcherCardOrder impl mismatch - possible hijack");
        require(p.cardOrderImpl.code.length > 0, "SettlementDispatcherCardOrder impl has no code");
        console.log("  [OK] SettlementDispatcherCardOrder impl:", actualCardOrderImpl);

        address actualLiquifierImpl = address(uint160(uint256(vm.load(p.liquifierProxy, EIP1967_IMPL_SLOT))));
        require(actualLiquifierImpl == p.liquifierImpl, "LiquidUSDLiquifierModule impl mismatch - possible hijack");
        require(p.liquifierImpl.code.length > 0, "LiquidUSDLiquifierModule impl has no code");
        console.log("  [OK] LiquidUSDLiquifierModule impl:", actualLiquifierImpl);
    }

    function _checkInitialization(Predicted memory p) internal view {
        console.log("");
        console.log("--- 3. Initialization ---");

        require(uint256(vm.load(p.pixProxy, OZ_INIT_SLOT)) > 0, "SettlementDispatcherPix NOT initialized");
        console.log("  [OK] SettlementDispatcherPix initialized");

        require(uint256(vm.load(p.cardOrderProxy, OZ_INIT_SLOT)) > 0, "SettlementDispatcherCardOrder NOT initialized");
        console.log("  [OK] SettlementDispatcherCardOrder initialized");

        require(uint256(vm.load(p.liquifierProxy, OZ_INIT_SLOT)) > 0, "LiquidUSDLiquifierModule NOT initialized");
        console.log("  [OK] LiquidUSDLiquifierModule initialized");
    }

    function _checkImmutables(Predicted memory p) internal view {
        console.log("");
        console.log("--- 4. Immutable values ---");

        require(SettlementDispatcherV2(payable(p.pixProxy)).binSponsor() == BinSponsor.PIX, "Pix binSponsor wrong");
        console.log("  [OK] SettlementDispatcherPix binSponsor = PIX");
        require(address(SettlementDispatcherV2(payable(p.pixProxy)).dataProvider()) == p.dataProvider, "Pix dataProvider wrong");
        console.log("  [OK] SettlementDispatcherPix dataProvider correct");

        require(SettlementDispatcherV2(payable(p.cardOrderProxy)).binSponsor() == BinSponsor.CardOrder, "CardOrder binSponsor wrong");
        console.log("  [OK] SettlementDispatcherCardOrder binSponsor = CardOrder");
        require(address(SettlementDispatcherV2(payable(p.cardOrderProxy)).dataProvider()) == p.dataProvider, "CardOrder dataProvider wrong");
        console.log("  [OK] SettlementDispatcherCardOrder dataProvider correct");

        require(EtherFiLiquidModule(p.liquidModule).weth() == 0x4200000000000000000000000000000000000006, "LiquidModule weth wrong");
        console.log("  [OK] EtherFiLiquidModule weth correct (OP)");

        require(EtherFiLiquidModuleWithReferrer(p.liquidModuleReferrer).weth() == 0x4200000000000000000000000000000000000006, "LiquidModuleReferrer weth wrong");
        console.log("  [OK] EtherFiLiquidModuleWithReferrer weth correct (OP)");
    }

    function _checkConfig(Predicted memory p) internal view {
        console.log("");
        console.log("--- 5. Module configuration ---");

        address storedQueue = EtherFiLiquidModuleWithReferrer(p.liquidModuleReferrer).liquidWithdrawQueue(sethfi);
        require(storedQueue == sETHFIBoringQueue, "sETHFI boring queue not set");
        console.log("  [OK] sETHFI boring queue set correctly");

        console.log("");
        console.log("--- 6. Cross-references ---");

        require(p.roleRegistry.code.length > 0, "RoleRegistry has no code");
        require(p.dataProvider.code.length > 0, "EtherFiDataProvider has no code");
        console.log("  [OK] RoleRegistry and DataProvider exist");
    }
}
