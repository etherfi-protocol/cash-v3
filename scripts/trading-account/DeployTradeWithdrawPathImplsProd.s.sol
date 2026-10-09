// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console2 } from "forge-std/console2.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { AcrossSwapModule } from "../../src/across/AcrossSwapModule.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { EnsoSwapModule } from "../../src/enso/EnsoSwapModule.sol";
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { OpenOceanSwapModule } from "../../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";
import { TradingAccountProdConfig as C } from "./TradingAccountProdConfig.sol";

/**
 * @notice Atomically deploys the trade recipient guard and trading withdraw path contracts through
 *         the permissioned EtherFiDeployer. Deploy only: the proxies are upgraded and the module
 *         delays are set by a separate 3CP.
 * @dev Optimism: CashModuleCore, CashModuleSetters, CashEventEmitter, AcrossSwapModule, EnsoSwapModule
 *      and a new OpenOceanSwapModule (not a proxy). Ethereum: AcrossSwapModule and EnsoSwapModule.
 *      Constructor dependencies are read off the live proxies. Enso and Across share a salt across
 *      chains, so both chains land the same implementation address despite different data providers.
 *
 * Simulate by dropping `--broadcast`; run once per chain with the registered production Ledger:
 *   source .env && forge script scripts/trading-account/DeployTradeWithdrawPathImplsProd.s.sol \
 *     --rpc-url $OPTIMISM_RPC --ledger --sender 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E \
 *     --broadcast --verify
 *   source .env && forge script scripts/trading-account/DeployTradeWithdrawPathImplsProd.s.sol \
 *     --rpc-url $MAINNET_RPC --ledger --sender 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E \
 *     --broadcast --verify
 */
contract DeployTradeWithdrawPathImplsProd is Script {
    using stdJson for string;

    EtherFiDeployer internal constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);
    address internal constant PROD_DEPLOYER = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;

    bytes32 internal constant SALT_ACROSS_IMPL = keccak256("TradingAccount.Prod.v1.AcrossSwapModuleImplTradeWithdrawPath");
    bytes32 internal constant SALT_ENSO_IMPL = keccak256("TradingAccount.Prod.v1.EnsoSwapModuleImplTradeWithdrawPath");
    bytes32 internal constant SALT_CASH_MODULE_CORE_IMPL = keccak256("Cash.Prod.CashModuleCoreImplTradeWithdrawPath");
    bytes32 internal constant SALT_CASH_MODULE_SETTERS_IMPL = keccak256("Cash.Prod.CashModuleSettersImplTradeWithdrawPath");
    bytes32 internal constant SALT_CASH_EVENT_EMITTER_IMPL = keccak256("Cash.Prod.CashEventEmitterImplTradeWithdrawPath");
    bytes32 internal constant SALT_OPEN_OCEAN_MODULE = keccak256("Cash.Prod.OpenOceanSwapModuleTradeWithdrawPath");

    bytes32 internal constant ETH_ACROSS_RUNTIME_HASH = 0xa187cfc13d51da30a50b79ea76867a7d068c9a2920a538f8f63a3ee65c587bb9;
    bytes32 internal constant ETH_ENSO_RUNTIME_HASH = 0x4d7eadcba6e7eadf81755b04cd18e5365605ba8bbdc496173c2efd26e09219ff;
    bytes32 internal constant OP_ACROSS_RUNTIME_HASH = 0xb15801beafbefb247180dbe7499f2f12d1d2bd060466bc5a91673fbd6cea192f;
    bytes32 internal constant OP_ENSO_RUNTIME_HASH = 0xb14d103dcd03f84f77388f78db36b9320e90c9913dc8a9a4edaa4a43649b61c9;
    bytes32 internal constant OP_CASH_MODULE_CORE_RUNTIME_HASH = 0x0477d777413ee391a76ca77a742b2c7df6b74165cd0485f8d93126f21fe3e747;
    bytes32 internal constant OP_CASH_MODULE_SETTERS_RUNTIME_HASH = 0x4cf1d7bb3cb58a0e8275ea8b5c1834f76ee60d4e5c011c8e22203a8288a7b2ef;
    bytes32 internal constant OP_CASH_EVENT_EMITTER_RUNTIME_HASH = 0xcc75cf4d98f43cca36cdc6a12120545f29addb6f0a34ae86c1d454d0f8817647;
    bytes32 internal constant OP_OPEN_OCEAN_RUNTIME_HASH = 0x2ea807a2efbc2d3bb3fc8ce2d2cf318c625876ac949db83682efb8c992e951fe;

    function run() external {
        require(block.chainid == 1 || block.chainid == 10, "unsupported chain");
        require(address(DEPLOYER).code.length > 0, "EtherFiDeployer not deployed");
        require(DEPLOYER.isDeployer(PROD_DEPLOYER), "production signer is not an EtherFiDeployer");

        address tradingSafeFactory = _predictLegacy(C.SALT_TRADING_SAFE_FACTORY_PROXY);
        address acrossProxy = _predictLegacy(C.SALT_ACROSS_PROXY);
        address ensoProxy = _predictLegacy(C.SALT_ENSO_PROXY);
        require(acrossProxy.code.length > 0 && ensoProxy.code.length > 0, "swap module proxies not deployed");

        address dataProvider = address(EnsoSwapModule(ensoProxy).etherFiDataProvider());
        require(address(AcrossSwapModule(acrossProxy).etherFiDataProvider()) == dataProvider, "swap module data providers differ");
        if (block.chainid == 1) {
            require(EtherFiDataProvider(dataProvider).getEtherFiSafeFactory() == tradingSafeFactory, "Ethereum data provider is not on the TradingSafeFactory");
        }

        string memory key = "trade-withdraw-path";
        address acrossImpl = _deployAtomic(abi.encodePacked(type(AcrossSwapModule).creationCode, abi.encode(dataProvider, tradingSafeFactory)), SALT_ACROSS_IMPL);
        address ensoImpl = _deployAtomic(abi.encodePacked(type(EnsoSwapModule).creationCode, abi.encode(dataProvider, tradingSafeFactory)), SALT_ENSO_IMPL);
        vm.serializeAddress(key, "AcrossSwapModuleImpl", acrossImpl);
        string memory json = vm.serializeAddress(key, "EnsoSwapModuleImpl", ensoImpl);
        if (block.chainid == 10) json = _deployCashContracts(key, dataProvider);

        require(address(AcrossSwapModule(acrossImpl).etherFiDataProvider()) == dataProvider, "Across data provider mismatch");
        require(address(EnsoSwapModule(ensoImpl).etherFiDataProvider()) == dataProvider, "Enso data provider mismatch");

        string memory path = string.concat("./deployments/mainnet/", vm.toString(block.chainid), "/trade-withdraw-path.json");
        vm.writeJson(json, path);
        console2.log("TradingSafeFactory", tradingSafeFactory);
        console2.log("Wrote", path);
    }

    function _deployCashContracts(string memory key, address dataProvider) internal returns (string memory json) {
        string memory deployments = vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet/10/deployments.json"));
        address cashModule = deployments.readAddress(".addresses.CashModule");
        address oldOpenOcean = deployments.readAddress(".addresses.OpenOceanSwapModule");
        require(deployments.readAddress(".addresses.EtherFiDataProvider") == dataProvider, "Optimism data provider mismatch");
        require(EtherFiDataProvider(dataProvider).getCashModule() == cashModule, "data provider cash module mismatch");
        address openOceanRouter = OpenOceanSwapModule(oldOpenOcean).swapRouter();

        address core = _deployAtomic(abi.encodePacked(type(CashModuleCore).creationCode, abi.encode(dataProvider)), SALT_CASH_MODULE_CORE_IMPL);
        address setters = _deployAtomic(abi.encodePacked(type(CashModuleSetters).creationCode, abi.encode(dataProvider)), SALT_CASH_MODULE_SETTERS_IMPL);
        address emitter = _deployAtomic(abi.encodePacked(type(CashEventEmitter).creationCode, abi.encode(cashModule)), SALT_CASH_EVENT_EMITTER_IMPL);
        address openOcean = _deployAtomic(abi.encodePacked(type(OpenOceanSwapModule).creationCode, abi.encode(openOceanRouter, dataProvider)), SALT_OPEN_OCEAN_MODULE);

        require(address(CashModuleCore(core).etherFiDataProvider()) == dataProvider, "CashModuleCore data provider mismatch");
        require(address(CashModuleSetters(setters).etherFiDataProvider()) == dataProvider, "CashModuleSetters data provider mismatch");
        require(CashEventEmitter(emitter).cashModule() == cashModule, "CashEventEmitter cash module mismatch");
        require(OpenOceanSwapModule(openOcean).swapRouter() == openOceanRouter, "OpenOcean router mismatch");
        require(address(OpenOceanSwapModule(openOcean).etherFiDataProvider()) == dataProvider, "OpenOcean data provider mismatch");

        vm.serializeAddress(key, "CashModuleCoreImpl", core);
        vm.serializeAddress(key, "CashModuleSettersImpl", setters);
        vm.serializeAddress(key, "CashEventEmitterImpl", emitter);
        json = vm.serializeAddress(key, "OpenOceanSwapModule", openOcean);
    }

    function _predictLegacy(bytes32 salt) internal pure returns (address) {
        return CREATE3.predictDeterministicAddress(salt, C.NICKS_FACTORY);
    }

    function _deployAtomic(bytes memory creationCode, bytes32 salt) internal returns (address deployed) {
        deployed = DEPLOYER.getDeterministicAddress(salt);
        if (deployed.code.length == 0) {
            vm.broadcast(PROD_DEPLOYER);
            require(DEPLOYER.deploy(salt, creationCode) == deployed, "deployed off the predicted address");
        }
        require(deployed.code.length > 0, "deployment has no runtime bytecode");
        require(deployed.codehash == _expectedRuntimeHash(salt), "runtime bytecode mismatch");
        console2.log("deployed", deployed);
    }

    function _expectedRuntimeHash(bytes32 salt) internal view returns (bytes32) {
        if (salt == SALT_ACROSS_IMPL) return block.chainid == 1 ? ETH_ACROSS_RUNTIME_HASH : OP_ACROSS_RUNTIME_HASH;
        if (salt == SALT_ENSO_IMPL) return block.chainid == 1 ? ETH_ENSO_RUNTIME_HASH : OP_ENSO_RUNTIME_HASH;
        if (salt == SALT_CASH_MODULE_CORE_IMPL && block.chainid == 10) return OP_CASH_MODULE_CORE_RUNTIME_HASH;
        if (salt == SALT_CASH_MODULE_SETTERS_IMPL && block.chainid == 10) return OP_CASH_MODULE_SETTERS_RUNTIME_HASH;
        if (salt == SALT_CASH_EVENT_EMITTER_IMPL && block.chainid == 10) return OP_CASH_EVENT_EMITTER_RUNTIME_HASH;
        if (salt == SALT_OPEN_OCEAN_MODULE && block.chainid == 10) return OP_OPEN_OCEAN_RUNTIME_HASH;
        revert("unexpected deployment salt");
    }
}
