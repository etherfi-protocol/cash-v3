// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { LiquidUSDLiquifierModule } from "../src/modules/etherfi/LiquidUSDLiquifier.sol";
import { EtherFiLiquidModule } from "../src/modules/etherfi/EtherFiLiquidModule.sol";
import { EtherFiLiquidModuleWithReferrer } from "../src/modules/etherfi/EtherFiLiquidModuleWithReferrer.sol";
import { StargateModule } from "../src/modules/stargate/StargateModule.sol";
import { FraxModule } from "../src/modules/frax/FraxModule.sol";
import { EtherFiStakeModule } from "../src/modules/etherfi/EtherFiStakeModule.sol";
import { PriceProvider } from "../src/oracle/PriceProvider.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";
import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";
import { GnosisHelpers } from "./utils/GnosisHelpers.sol";
import { Utils } from "./utils/Utils.sol";

/// @title VerifyOptimismProdModules
/// @notice Post-deployment verification for DeployOptimismProdModules.
///         If gnosis bundle hasn't been executed yet, simulates it on a fork first.
///         Reverts on any failed check so CI/scripts can rely on exit code.
///
/// Usage:
///   ENV=mainnet forge script scripts/VerifyOptimismProdModules.s.sol --rpc-url $OPTIMISM_RPC
contract VerifyOptimismProdModules is GnosisHelpers, Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    bytes32 constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant OZ_INIT_SLOT      = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    // Must match DeployOptimismProdModules salts exactly
    bytes32 constant SALT_LIQUID_MODULE            = keccak256("DeployOptimismProdModules.EtherFiLiquidModule");
    bytes32 constant SALT_LIQUID_MODULE_REFERRER   = keccak256("DeployOptimismProdModules.EtherFiLiquidModuleWithReferrer");
    bytes32 constant SALT_STARGATE_MODULE          = keccak256("DeployOptimismProdModules.StargateModule");
    bytes32 constant SALT_FRAX_MODULE              = keccak256("DeployOptimismProdModules.FraxModule");
    bytes32 constant SALT_LIQUIFIER_IMPL           = keccak256("DeployOptimismProdModules.LiquidUSDLiquifierImpl");
    bytes32 constant SALT_LIQUIFIER_PROXY          = keccak256("DeployOptimismProdModules.LiquidUSDLiquifierProxy");
    bytes32 constant SALT_STAKE_MODULE             = keccak256("DeployOptimismProdModules.EtherFiStakeModule");

    address constant weth = 0x4200000000000000000000000000000000000006;
    address constant sethfi = 0x86B5780b606940Eb59A062aA85a07959518c0161;
    address constant sETHFIBoringQueue = 0xF03352da1536F31172A7F7cB092D4717DeDDd3CB;
    address constant frxUSD = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
    address constant liquidEth = 0xf0bb20865277aBd641a307eCe5Ee04E79073416C;
    address constant ebtc = 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;

    struct Predicted {
        address liquidModule;
        address liquidModuleReferrer;
        address stargateModule;
        address fraxModule;
        address stakeModule;
        address liquifierProxy;
        address liquifierImpl;
        address roleRegistry;
        address dataProvider;
        address priceProvider;
        address debtManager;
    }

    function _predict() internal view returns (Predicted memory p) {
        p.liquidModule = CREATE3.predictDeterministicAddress(SALT_LIQUID_MODULE, NICKS_FACTORY);
        p.liquidModuleReferrer = CREATE3.predictDeterministicAddress(SALT_LIQUID_MODULE_REFERRER, NICKS_FACTORY);
        p.stargateModule = CREATE3.predictDeterministicAddress(SALT_STARGATE_MODULE, NICKS_FACTORY);
        p.fraxModule = CREATE3.predictDeterministicAddress(SALT_FRAX_MODULE, NICKS_FACTORY);
        p.liquifierProxy = CREATE3.predictDeterministicAddress(SALT_LIQUIFIER_PROXY, NICKS_FACTORY);
        p.liquifierImpl = CREATE3.predictDeterministicAddress(SALT_LIQUIFIER_IMPL, NICKS_FACTORY);
        p.stakeModule = CREATE3.predictDeterministicAddress(SALT_STAKE_MODULE, NICKS_FACTORY);

        string memory deployments = readDeploymentFile();
        p.roleRegistry = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "RoleRegistry"));
        p.dataProvider = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "EtherFiDataProvider"));
        p.priceProvider = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "PriceProvider"));
        p.debtManager = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "DebtManager"));
    }

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (chain ID 10)");

        Predicted memory p = _predict();

        console.log("==========================================");
        console.log("  Verify Optimism Prod Modules (Post-Deploy)");
        console.log("==========================================");

        // If gnosis bundle hasn't been executed yet, simulate it on the fork
        _simulateGnosisBundleIfNeeded(p);

        _checkOwnership(p);
        _checkExistence(p);
        _checkProxy(p);
        _checkImmutables(p);
        _checkConfig(p);

        console.log("");
        console.log("==========================================");
        console.log("  ALL CHECKS PASSED");
        console.log("==========================================");
    }

    function _simulateGnosisBundleIfNeeded(Predicted memory p) internal {
        // Check if config has been applied by testing one of the gnosis effects
        bool gnosisExecuted = IDebtManager(p.debtManager).isCollateralToken(frxUSD);

        if (gnosisExecuted) {
            console.log("  Gnosis bundle already executed on-chain, verifying live state.");
            return;
        }

        console.log("  Gnosis bundle NOT yet executed. Simulating on fork...");

        string memory path = "./output/DeployOptimismProdModules.json";
        executeGnosisTransactionBundle(path);

        console.log("  Gnosis bundle simulated successfully.");
        console.log("");
    }

    function _checkOwnership(Predicted memory p) internal view {
        console.log("");
        console.log("--- 1. Ownership ---");
        address rrOwner = RoleRegistry(p.roleRegistry).owner();
        require(rrOwner == cashControllerSafe, "CRITICAL: RoleRegistry owner changed!");
        console.log("  [OK] RoleRegistry owner:", rrOwner);
    }

    function _checkExistence(Predicted memory p) internal view {
        console.log("");
        console.log("--- 2. Contract existence ---");
        require(p.liquidModule.code.length > 0, "EtherFiLiquidModule has no code");
        console.log("  [OK] EtherFiLiquidModule:", p.liquidModule);
        require(p.liquidModuleReferrer.code.length > 0, "EtherFiLiquidModuleWithReferrer has no code");
        console.log("  [OK] EtherFiLiquidModuleWithReferrer:", p.liquidModuleReferrer);
        require(p.stargateModule.code.length > 0, "StargateModule has no code");
        console.log("  [OK] StargateModule:", p.stargateModule);
        require(p.fraxModule.code.length > 0, "FraxModule has no code");
        console.log("  [OK] FraxModule:", p.fraxModule);
        require(p.liquifierProxy.code.length > 0, "LiquidUSDLiquifierModule proxy has no code");
        console.log("  [OK] LiquidUSDLiquifierModule proxy:", p.liquifierProxy);
        require(p.stakeModule.code.length > 0, "EtherFiStakeModule has no code");
        console.log("  [OK] EtherFiStakeModule:", p.stakeModule);
    }

    function _checkProxy(Predicted memory p) internal view {
        console.log("");
        console.log("--- 3. Proxy impl slot + initialization ---");

        address actualImpl = address(uint160(uint256(vm.load(p.liquifierProxy, EIP1967_IMPL_SLOT))));
        require(actualImpl == p.liquifierImpl, "LiquidUSDLiquifier impl mismatch - possible hijack");
        require(p.liquifierImpl.code.length > 0, "LiquidUSDLiquifier impl has no code");
        console.log("  [OK] LiquidUSDLiquifier impl:", actualImpl);

        require(uint256(vm.load(p.liquifierProxy, OZ_INIT_SLOT)) > 0, "LiquidUSDLiquifier NOT initialized");
        console.log("  [OK] LiquidUSDLiquifier initialized");
    }

    function _checkImmutables(Predicted memory p) internal view {
        console.log("");
        console.log("--- 4. Immutable values ---");

        require(EtherFiLiquidModule(p.liquidModule).weth() == weth, "LiquidModule weth wrong");
        console.log("  [OK] EtherFiLiquidModule weth correct (OP)");

        require(EtherFiLiquidModuleWithReferrer(p.liquidModuleReferrer).weth() == weth, "LiquidModuleReferrer weth wrong");
        console.log("  [OK] EtherFiLiquidModuleWithReferrer weth correct (OP)");

        require(EtherFiStakeModule(p.stakeModule).weth() == weth, "StakeModule weth wrong");
        require(address(EtherFiStakeModule(p.stakeModule).weETH()) == 0x5A7fACB970D094B6C7FF1df0eA68D99E6e73CBFF, "StakeModule weETH wrong");
        console.log("  [OK] EtherFiStakeModule weth + weETH correct (OP)");
    }

    function _checkConfig(Predicted memory p) internal view {
        console.log("");
        console.log("--- 5. Gnosis config effects ---");

        address storedQueue = EtherFiLiquidModuleWithReferrer(p.liquidModuleReferrer).liquidWithdrawQueue(sethfi);
        require(storedQueue == sETHFIBoringQueue, "sETHFI boring queue not set");
        console.log("  [OK] sETHFI boring queue set");

        require(PriceProvider(p.priceProvider).price(frxUSD) != 0, "frxUSD price is 0");
        console.log("  [OK] frxUSD oracle configured");

        require(PriceProvider(p.priceProvider).price(liquidEth) != 0, "liquidEth price is 0");
        console.log("  [OK] liquidEth oracle configured");

        require(IDebtManager(p.debtManager).isCollateralToken(frxUSD), "frxUSD not collateral");
        console.log("  [OK] frxUSD collateral supported");

        require(IDebtManager(p.debtManager).isCollateralToken(liquidEth), "liquidEth not collateral");
        console.log("  [OK] liquidEth collateral supported");

        require(IDebtManager(p.debtManager).isCollateralToken(ebtc), "ebtc not collateral");
        console.log("  [OK] ebtc collateral supported");
    }
}
