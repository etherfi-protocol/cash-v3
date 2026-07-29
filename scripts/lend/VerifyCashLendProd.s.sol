// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { BeaconFactory, UpgradeableBeacon } from "../../src/beacon-factory/BeaconFactory.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { IAaveV4Spoke } from "../../src/interfaces/IAaveV4Spoke.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title VerifyCashLendProd
 * @notice Companion verification for DeployCashLendProd. Run read-only against live Optimism AFTER
 *         the prod Safe executes output/CashLendProd-10.json. Every check is a require, so the
 *         script reverts (non-zero exit) on any failure.
 *
 *         Every expected implementation and module address is recomputed from the CREATE3 salts —
 *         not read from a mutable record — so this catches a swapped-in impl at an unexpected
 *         address (hijack detection), stale pointers, and missing configuration.
 *
 * Usage:
 *   source .env && ENV=mainnet forge script scripts/lend/VerifyCashLendProd.s.sol:VerifyCashLendProd \
 *     --rpc-url $OPTIMISM_RPC -vvvv
 */
contract VerifyCashLendProd is Utils {
    bytes32 internal constant EIP1967_IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // roleRegistry slot of UpgradeableProxy's ERC-7201 namespaced storage (hijack detection).
    bytes32 internal constant UPGRADEABLE_PROXY_ROLE_REGISTRY_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;
    address internal constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    function run() public view {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "mainnet"), "ENV must be mainnet");

        string memory json = readDeploymentFile();
        address cashModule = _addr(json, "CashModule");
        address dataProvider = _addr(json, "EtherFiDataProvider");
        address debtManager = _addr(json, "DebtManager");
        address roleRegistry = _addr(json, "RoleRegistry");

        // ── Proxy implementations: EIP-1967 slots must hold the EXACT CREATE3-predicted impls ──
        _requireImpl(cashModule, "CashModuleCoreImpl", "CashModule");
        _requireImpl(_addr(json, "CashLens"), "CashLensImpl", "CashLens");
        _requireImpl(_addr(json, "CashEventEmitter"), "CashEventEmitterImpl", "CashEventEmitter");
        _requireImpl(debtManager, "DebtManagerCoreImpl", "DebtManager");
        _requireImpl(_addr(json, "EtherFiHook"), "EtherFiHookImpl", "EtherFiHook");
        _requireImpl(_addr(json, "TopUpDest"), "TopUpDestImpl", "TopUpDest");
        _requireImpl(_addr(json, "LiquidUSDLiquifierModule"), "LiquifierImpl", "Liquifier");

        string memory trading = vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet/10/trading-account.json"));
        _requireImpl(stdJson.readAddress(trading, ".EnsoSwapModule"), "EnsoImpl", "Enso");
        _requireImpl(stdJson.readAddress(trading, ".AcrossSwapModule"), "AcrossImpl", "Across");

        // ── Delegated implementation pointers ──
        require(CashModuleCore(cashModule).getCashModuleSetters() == _predicted("CashModuleSettersImpl"), "CashModule setters mismatch");
        require(IDebtManager(debtManager).getDebtManagerAdmin() == _predicted("DebtManagerAdminImpl"), "DebtManager admin mismatch");

        // ── Safe beacon ──
        address beacon = BeaconFactory(_addr(json, "EtherFiSafeFactory")).beacon();
        require(UpgradeableBeacon(beacon).implementation() == _predicted("EtherFiSafeImpl"), "Safe beacon impl mismatch");

        // ── LendGateway: address, impl, ownership, activation ──
        address gatewayProxy = _predicted("LendGatewayProxy");
        require(gatewayProxy.code.length != 0, "LendGateway proxy not deployed");
        require(_implementationOf(gatewayProxy) == _predicted("LendGatewayImpl"), "LendGateway impl mismatch");
        require(_roleRegistryOf(gatewayProxy) == roleRegistry, "LendGateway roleRegistry mismatch - possible hijack");
        require(address(ICashModule(cashModule).getLendGateway()) == gatewayProxy, "LendGateway not set on CashModule");
        require(EtherFiDataProvider(dataProvider).isDefaultModule(gatewayProxy), "LendGateway not a default module");

        LendGateway gateway = LendGateway(gatewayProxy);
        IAaveV4Spoke spoke = IAaveV4Spoke(stdJson.readAddress(vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet/10/summer-lend.json")), ".spoke"));
        require(address(gateway.spoke()) == address(spoke), "gateway spoke mismatch");
        require(spoke.isPositionManagerActive(gatewayProxy), "gateway not an active position manager");
        uint256 reserveCount = spoke.getReserveCount();
        require(reserveCount > 0, "spoke has no reserves");
        for (uint256 reserveId = 0; reserveId < reserveCount; ++reserveId) {
            require(gateway.isRegistered(spoke.getReserve(reserveId).underlying), "reserve not mirrored");
        }
        require(gateway.isSpendAsset(_fixtureAsset("usdc")), "USDC not a spend asset");
        require(gateway.isSpendAsset(_fixtureAsset("usdt")), "USDC not a spend asset");
        require(gateway.isSpendAsset(_fixtureAsset("eurc")), "USDC not a spend asset");
        require(gateway.isSpendAsset(_fixtureAsset("liquidUsd")), "USDC not a spend asset");
        require(gateway.isSpendAsset(_fixtureAsset("liquidReserve")), "USDC not a spend asset");
        require(gateway.isSpendAsset(_fixtureAsset("liquidEUR")), "USDC not a spend asset");
        require(gateway.isSpendAsset(_fixtureAsset("fraxusd")), "USDC not a spend asset");
        
        require(gateway.isDriver(debtManager), "DebtManager not a driver");
        require(gateway.isDriver(_addr(json, "TopUpDest")), "TopUpDest not a driver");
        require(gateway.isDriver(_addr(json, "LiquidUSDLiquifierModule")), "Liquifier not a driver");
        require(gateway.isDriver(stdJson.readAddress(trading, ".EnsoSwapModule")), "Enso not a driver");
        require(gateway.isDriver(stdJson.readAddress(trading, ".AcrossSwapModule")), "Across not a driver");

        // ── AaveV4Lens: read aggregator behind our UUPS proxy ──
        address lensProxy = _predicted("AaveV4LensProxy");
        require(lensProxy.code.length != 0, "AaveV4Lens proxy not deployed");
        require(_implementationOf(lensProxy) == _predicted("AaveV4LensImpl"), "AaveV4Lens impl mismatch");
        require(_roleRegistryOf(lensProxy) == roleRegistry, "AaveV4Lens roleRegistry mismatch - possible hijack");

        // ── Replacement modules: deployed, drivers, and policy mirrored from their predecessors ──
        _verifyModules(json, cashModule, dataProvider, gateway);

        // ── Governance unchanged; keep this the final check ──
        require(RoleRegistry(roleRegistry).owner() == SAFE, "CRITICAL: RoleRegistry owner changed");

        console.log("All checks passed");
    }

    function _verifyModules(string memory json, address cashModule, address dataProvider, LendGateway gateway) internal view {
        string[7] memory names = ["OpenOceanModule", "LiquidModule", "LiquidReferrerModule", "FraxModule", "StakeModule", "MidasModule", "BeHYPEModule"];
        string[7] memory oldKeys = ["OpenOceanSwapModule", "EtherFiLiquidModule", "EtherFiLiquidModuleWithReferrer", "FraxModule", "EtherFiStakeModule", "MidasModule", "BeHYPEStakeModule"];
        address[] memory requesters = ICashModule(cashModule).getWhitelistedModulesCanRequestWithdraw();

        for (uint256 i = 0; i < 7; ++i) {
            address newModule = _predicted(names[i]);
            address oldModule = _addr(json, oldKeys[i]);
            require(newModule.code.length != 0, string.concat(names[i], " not deployed"));
            require(gateway.isDriver(newModule), string.concat(names[i], " not a driver"));
            require(
                EtherFiDataProvider(dataProvider).isDefaultModule(newModule) == EtherFiDataProvider(dataProvider).isDefaultModule(oldModule),
                string.concat(names[i], " default policy not mirrored")
            );
            require(
                EtherFiDataProvider(dataProvider).isWhitelistedModule(newModule) == EtherFiDataProvider(dataProvider).isWhitelistedModule(oldModule),
                string.concat(names[i], " whitelist policy not mirrored")
            );
            require(
                _contains(requesters, newModule) == _contains(requesters, oldModule),
                string.concat(names[i], " requester policy not mirrored")
            );
            // Old modules stay live for gradual migration and must never be gateway drivers.
            require(EtherFiDataProvider(dataProvider).isWhitelistedModule(oldModule), string.concat(oldKeys[i], " old module no longer whitelisted"));
            require(!gateway.isDriver(oldModule), string.concat(oldKeys[i], " old module unexpectedly a driver"));
        }
    }

    function _requireImpl(address proxy, string memory saltName, string memory label) internal view {
        address expected = _predicted(saltName);
        require(_implementationOf(proxy) == expected, string.concat(label, " impl mismatch - possible hijack"));
        require(expected.code.length != 0, string.concat(label, " impl has no code"));
    }

    function _predicted(string memory name) internal pure returns (address) {
        return CREATE3.predictDeterministicAddress(keccak256(bytes(string.concat("CashLendProd.", name))), NICKS_FACTORY);
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPLEMENTATION_SLOT))));
    }

    function _roleRegistryOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, UPGRADEABLE_PROXY_ROLE_REGISTRY_SLOT))));
    }

    function _addr(string memory json, string memory name) internal pure returns (address) {
        return stdJson.readAddress(json, string.concat(".addresses.", name));
    }

    /// @dev Utils.getChainConfig parses fixture keys chain 10 doesn't have, so read directly.
    function _fixtureAsset(string memory key) internal view returns (address) {
        string memory fixtures = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/fixtures/fixtures.json"));
        return stdJson.readAddress(fixtures, string.concat(".", vm.toString(block.chainid), ".", key));
    }

    function _contains(address[] memory values, address value) internal pure returns (bool) {
        for (uint256 i = 0; i < values.length; ++i) {
            if (values[i] == value) return true;
        }
        return false;
    }
}
