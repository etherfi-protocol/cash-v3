// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { DebtManagerAdmin } from "../../src/debt-manager/DebtManagerAdmin.sol";
import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";
import { IAaveV4Spoke } from "../../src/interfaces/IAaveV4Spoke.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { CashEventEmitter } from "../../src/modules/cash/CashEventEmitter.sol";
import { CashLens } from "../../src/modules/cash/CashLens.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { Utils } from "../utils/Utils.sol";
import { CashLendDevModules } from "./CashLendDevModules.sol";

/**
 * @title VerifyCashLendDev
 * @notice Verifies the deployment produced by DeployCashLendDev
 * @dev Dev-only and read-only. Run it right after deploying, or any time later; it checks the live
 *      chain against the deployment record and reverts on the first mismatch.
 *
 * Usage:
 *   source .env && ENV=dev forge script \
 *     scripts/lend/VerifyCashLendDev.s.sol:VerifyCashLendDev \
 *     --rpc-url $OPTIMISM_RPC -vvvv
 */
contract VerifyCashLendDev is Utils {
    bytes32 internal constant EIP1967_IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 internal constant MIN_HEALTH_FACTOR = 1.05e18;
    /// @dev The legacy liquidRESERVE OFT remains listed on the test Spoke at reserve 12 but is
    ///      not registered in LendGateway. Its migration target is the active Midas token.
    address internal constant UNREGISTERED_LEGACY_LIQUID_RESERVE = 0xE5d3854736e0D513aAE2D8D708Ad94d14Fd56A6a;

    struct Deployment {
        address admin;
        address cashEventEmitter;
        address cashEventEmitterImpl;
        address cashLens;
        address cashLensImpl;
        address cashModule;
        address cashModuleCoreImpl;
        address cashModuleSettersImpl;
        address dataProvider;
        address debtManager;
        address debtManagerAdminImpl;
        address debtManagerCoreImpl;
        address deployer;
        address etherFiHook;
        address etherFiHookImpl;
        address lendGateway;
        address lendGatewayImpl;
        address roleRegistry;
        address spoke;
        address topUpDest;
        address topUpDestImpl;
        address[] newModules;
        address liquifier;
        address liquifierImplementation;
        CashLendDevModules.OldModules oldModules;
    }

    /// @dev Loads the deployment record and runs every post-deployment verification check.
    function run() public view {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "dev"), "ENV must be dev");

        Deployment memory d = _readDeployment();
        _verifyCode(d);
        _verifyImplementations(d);
        _verifyImmutables(d);
        _verifyGateway(d);
        _verifyModules(d);
        console.log("Cash Lend dev deployment verified");
    }

    /// @dev Reads the canonical proxies from the base file and the new addresses from the deployment record.
    function _readDeployment() internal view returns (Deployment memory) {
        Deployment memory d;

        string memory baseJson = readDeploymentFile();
        d.cashEventEmitter = stdJson.readAddress(baseJson, ".addresses.CashEventEmitter");
        d.cashLens = stdJson.readAddress(baseJson, ".addresses.CashLens");
        d.cashModule = stdJson.readAddress(baseJson, ".addresses.CashModule");
        d.dataProvider = stdJson.readAddress(baseJson, ".addresses.EtherFiDataProvider");
        d.debtManager = stdJson.readAddress(baseJson, ".addresses.DebtManager");
        d.etherFiHook = stdJson.readAddress(baseJson, ".addresses.EtherFiHook");
        d.roleRegistry = stdJson.readAddress(baseJson, ".addresses.RoleRegistry");
        d.topUpDest = stdJson.readAddress(baseJson, ".addresses.TopUpDest");
        d.oldModules = CashLendDevModules.readOld(baseJson);
        d.liquifier = d.oldModules.liquifier;

        string memory record = vm.readFile(string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/cash-lend.json"));
        require(stdJson.readUint(record, ".chainId") == block.chainid, "deployment record chain mismatch");
        d.admin = stdJson.readAddress(record, ".admin");
        d.deployer = stdJson.readAddress(record, ".deployer");
        d.cashEventEmitterImpl = stdJson.readAddress(record, ".cashEventEmitterImpl");
        d.cashLensImpl = stdJson.readAddress(record, ".cashLensImpl");
        d.cashModuleCoreImpl = stdJson.readAddress(record, ".cashModuleCoreImpl");
        d.cashModuleSettersImpl = stdJson.readAddress(record, ".cashModuleSettersImpl");
        d.debtManagerAdminImpl = stdJson.readAddress(record, ".debtManagerAdminImpl");
        d.debtManagerCoreImpl = stdJson.readAddress(record, ".debtManagerCoreImpl");
        d.etherFiHookImpl = stdJson.readAddress(record, ".etherFiHookImpl");
        d.topUpDestImpl = stdJson.readAddress(record, ".topUpDestImpl");
        d.lendGateway = stdJson.readAddress(record, ".lendGateway");
        d.lendGatewayImpl = stdJson.readAddress(record, ".lendGatewayImpl");
        d.spoke = stdJson.readAddress(record, ".spoke");
        d.newModules = CashLendDevModules.readNew(record);
        d.liquifierImplementation = stdJson.readAddress(record, ".liquifierImplementation");

        string memory aaveJson = vm.readFile(string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/aave-v4-test.json"));
        require(d.spoke == stdJson.readAddress(aaveJson, ".spoke"), "non-canonical Aave Spoke");
        require(d.admin == stdJson.readAddress(aaveJson, ".admin"), "non-canonical dev admin");
        return d;
    }

    /// @dev Confirms that every expected proxy and implementation address contains bytecode.
    function _verifyCode(Deployment memory d) internal view {
        require(d.cashEventEmitter.code.length != 0 && d.cashEventEmitterImpl.code.length != 0, "CashEventEmitter code missing");
        require(d.cashLens.code.length != 0 && d.cashLensImpl.code.length != 0, "CashLens code missing");
        require(d.cashModule.code.length != 0 && d.cashModuleCoreImpl.code.length != 0 && d.cashModuleSettersImpl.code.length != 0, "CashModule code missing");
        require(d.debtManager.code.length != 0 && d.debtManagerCoreImpl.code.length != 0 && d.debtManagerAdminImpl.code.length != 0, "DebtManager code missing");
        require(d.etherFiHook.code.length != 0 && d.etherFiHookImpl.code.length != 0, "EtherFiHook code missing");
        require(d.lendGateway.code.length != 0 && d.lendGatewayImpl.code.length != 0, "LendGateway code missing");
        require(d.topUpDest.code.length != 0 && d.topUpDestImpl.code.length != 0, "TopUpDest code missing");
    }

    /// @dev Confirms that each proxy and delegated implementation pointer matches the record.
    function _verifyImplementations(Deployment memory d) internal view {
        require(_implementationOf(d.cashEventEmitter) == d.cashEventEmitterImpl, "CashEventEmitter implementation mismatch");
        require(_implementationOf(d.cashLens) == d.cashLensImpl, "CashLens implementation mismatch");
        require(_implementationOf(d.cashModule) == d.cashModuleCoreImpl, "CashModule implementation mismatch");
        require(CashModuleCore(d.cashModule).getCashModuleSetters() == d.cashModuleSettersImpl, "CashModule setters mismatch");
        require(_implementationOf(d.debtManager) == d.debtManagerCoreImpl, "DebtManager implementation mismatch");
        require(IDebtManager(d.debtManager).getDebtManagerAdmin() == d.debtManagerAdminImpl, "DebtManager admin mismatch");
        require(_implementationOf(d.etherFiHook) == d.etherFiHookImpl, "EtherFiHook implementation mismatch");
        require(_implementationOf(d.lendGateway) == d.lendGatewayImpl, "LendGateway implementation mismatch");
        require(_implementationOf(d.topUpDest) == d.topUpDestImpl, "TopUpDest implementation mismatch");
        require(_implementationOf(d.liquifier) == d.liquifierImplementation, "liquifier implementation mismatch");
    }

    /// @dev Reads a UUPS proxy's implementation directly from its EIP-1967 storage slot.
    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPLEMENTATION_SLOT))));
    }

    /// @dev Confirms constructor-set references on upgraded implementations still point to dev dependencies.
    function _verifyImmutables(Deployment memory d) internal view {
        require(address(CashModuleCore(d.cashModule).etherFiDataProvider()) == d.dataProvider, "CashModule core dataProvider mismatch");
        require(address(CashModuleSetters(d.cashModuleSettersImpl).etherFiDataProvider()) == d.dataProvider, "CashModule setters dataProvider mismatch");
        require(address(CashLens(d.cashLens).cashModule()) == d.cashModule, "CashLens cashModule mismatch");
        require(address(CashLens(d.cashLens).dataProvider()) == d.dataProvider, "CashLens dataProvider mismatch");
        require(CashEventEmitter(d.cashEventEmitter).cashModule() == d.cashModule, "CashEventEmitter cashModule mismatch");
        require(address(DebtManagerCore(d.debtManager).etherFiDataProvider()) == d.dataProvider, "DebtManager core dataProvider mismatch");
        require(address(DebtManagerAdmin(d.debtManagerAdminImpl).etherFiDataProvider()) == d.dataProvider, "DebtManager admin dataProvider mismatch");
        require(address(EtherFiHook(d.etherFiHook).dataProvider()) == d.dataProvider, "EtherFiHook dataProvider mismatch");
        require(address(TopUpDest(payable(d.topUpDest)).etherFiDataProvider()) == d.dataProvider, "TopUpDest dataProvider mismatch");
        require(address(TopUpDest(payable(d.topUpDest)).weth()) == getChainConfig(vm.toString(block.chainid)).weth, "TopUpDest WETH mismatch");
    }

    /// @dev Confirms gateway roles, policy, reserve mappings, drivers, and Aave position-manager activation.
    function _verifyGateway(Deployment memory d) internal view {
        LendGateway gateway = LendGateway(d.lendGateway);
        IAaveV4Spoke spoke = IAaveV4Spoke(d.spoke);
        address usdc = getChainConfig(vm.toString(block.chainid)).usdc;

        require(address(gateway.etherFiDataProvider()) == d.dataProvider, "gateway dataProvider mismatch");
        require(address(gateway.spoke()) == d.spoke, "gateway Spoke mismatch");
        require(address(gateway.roleRegistry()) == d.roleRegistry, "gateway role registry mismatch");
        require(address(ICashModule(d.cashModule).getLendGateway()) == d.lendGateway, "CashModule gateway mismatch");
        require(EtherFiDataProvider(d.dataProvider).isDefaultModule(d.lendGateway), "gateway not default module");
        require(gateway.minHealthFactor() == MIN_HEALTH_FACTOR, "minimum health factor mismatch");
        require(gateway.isSpendAsset(usdc), "USDC not spendable");
        require(gateway.isDriver(d.debtManager), "DebtManager not a driver");
        require(gateway.isDriver(d.topUpDest), "TopUpDest not a driver");
        require(gateway.isDriver(d.liquifier), "liquifier not a driver");
        require(spoke.isPositionManagerActive(d.lendGateway), "gateway not active on Spoke");
        require(EtherFiDataProvider(d.dataProvider).isDefaultModule(d.lendGateway), "gateway not a default module");
        require(d.deployer == d.admin, "deployer is not dev admin");
        require(RoleRegistry(d.roleRegistry).owner() == d.admin, "dev admin mismatch");
        require(RoleRegistry(d.roleRegistry).hasRole(gateway.LEND_GATEWAY_ADMIN_ROLE(), d.admin), "gateway admin role missing");
        require(RoleRegistry(d.roleRegistry).hasRole(DebtManagerCore(d.debtManager).ETHER_FI_WALLET_ROLE(), d.admin), "wallet role missing for migration");

        uint256 count = spoke.getReserveCount();
        require(gateway.registeredAssets().length + 1 == count, "registered reserve count mismatch");
        for (uint256 reserveId = 0; reserveId < count; ++reserveId) {
            address asset = spoke.getReserve(reserveId).underlying;
            if (asset == UNREGISTERED_LEGACY_LIQUID_RESERVE) {
                require(!gateway.isRegistered(asset), "legacy liquidRESERVE unexpectedly registered");
                continue;
            }
            require(gateway.isRegistered(asset), "reserve asset not registered");
            require(gateway.reserveIdOf(asset) == reserveId, "reserve ID mismatch");
        }
    }

    /// @dev Confirms the new modules copied the old configuration and run alongside the still-enabled old ones.
    function _verifyModules(Deployment memory d) internal view {
        CashLendDevModules.NewModules memory next = CashLendDevModules.newFromAddresses(d.newModules, d.liquifierImplementation);
        CashLendDevModules.verifyNewConfig(d.dataProvider, d.debtManager, d.oldModules, next);
        CashLendDevModules.verifyActive(d.dataProvider, d.cashModule, LendGateway(d.lendGateway), CashLendDevModules.oldAddresses(d.oldModules), d.newModules);
        require(EtherFiDataProvider(d.dataProvider).isDefaultModule(d.liquifier), "liquifier not default");
    }
}
