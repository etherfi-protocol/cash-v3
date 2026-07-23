// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console2 } from "forge-std/console2.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { AcrossSwapModule } from "../../src/across/AcrossSwapModule.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { EnsoSwapModule } from "../../src/enso/EnsoSwapModule.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiSafe } from "../../src/safe/EtherFiSafe.sol";
import { EtherFiSafeFactory } from "../../src/safe/EtherFiSafeFactory.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";
import { Utils } from "../utils/Utils.sol";
import { TradingAccountProdConfig as Prod } from "./TradingAccountProdConfig.sol";

/// @notice Fresh DevV2 OP module deployment plus removal of the active ownership bridge.
/// @dev Upgrades the existing dev DataProvider and EtherFiSafe beacon to the current
///      chain-local implementations, then deploys and configures fresh swap modules.
contract DeployTradingAccountOptimismDevV2 is Utils {
    using stdJson for string;

    EtherFiDeployer private constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);
    address private constant DEV_ADMIN = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;
    bytes32 private constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    EtherFiDataProvider private dataProvider;
    RoleRegistry private roleRegistry;
    ICashModule private cashModule;
    EtherFiSafeFactory private safeFactory;
    address private dataProviderImpl;
    address private safeImpl;
    address private acrossProxy;
    address private ensoProxy;

    function run() external {
        require(block.chainid == 10, "must run on Optimism");
        require(DEPLOYER.isDeployer(DEV_ADMIN), "dev admin is not an EtherFiDeployer");

        string memory deployments = readDeploymentFile();
        dataProvider = EtherFiDataProvider(deployments.readAddress(".addresses.EtherFiDataProvider"));
        roleRegistry = RoleRegistry(deployments.readAddress(".addresses.RoleRegistry"));
        cashModule = ICashModule(deployments.readAddress(".addresses.CashModule"));
        safeFactory = EtherFiSafeFactory(deployments.readAddress(".addresses.EtherFiSafeFactory"));

        require(roleRegistry.owner() == DEV_ADMIN, "dev admin is not RoleRegistry owner");
        require(roleRegistry.hasRole(dataProvider.DATA_PROVIDER_ADMIN_ROLE(), DEV_ADMIN), "dev admin lacks DataProvider role");
        require(roleRegistry.hasRole(cashModule.CASH_MODULE_CONTROLLER_ROLE(), DEV_ADMIN), "dev admin lacks CashModule role");

        _startBroadcast();
        _removeOwnershipBridge();
        _deployAndConfigureModules();
        vm.stopBroadcast();

        _assertConfigured();
        _writeManifest();
    }

    function _removeOwnershipBridge() private {
        dataProviderImpl = _deploy("Cash.DevV2.EtherFiDataProviderImpl.NoBridge", type(EtherFiDataProvider).creationCode, "");
        dataProvider.upgradeToAndCall(dataProviderImpl, "");

        safeImpl = _deploy("Cash.DevV2.EtherFiSafeImpl.NoBridge", type(EtherFiSafe).creationCode, abi.encode(address(dataProvider)));
        safeFactory.upgradeBeaconImplementation(safeImpl);
    }

    function _deployAndConfigureModules() private {
        address acrossImpl = _deploy("TradingAccount.DevV2.AcrossSwapModuleImpl", type(AcrossSwapModule).creationCode, abi.encode(address(dataProvider)));
        acrossProxy = _deploy("TradingAccount.DevV2.AcrossSwapModuleProxy", type(UUPSProxy).creationCode, abi.encode(acrossImpl, abi.encodeWithSelector(AcrossSwapModule.initialize.selector, address(roleRegistry), Prod.OP_SPOKE_POOL, Prod.MULTICALL_HANDLER)));

        address ensoImpl = _deploy("TradingAccount.DevV2.EnsoSwapModuleImpl", type(EnsoSwapModule).creationCode, abi.encode(address(dataProvider)));
        ensoProxy = _deploy("TradingAccount.DevV2.EnsoSwapModuleProxy", type(UUPSProxy).creationCode, abi.encode(ensoImpl, abi.encodeWithSelector(EnsoSwapModule.initialize.selector, address(roleRegistry), Prod.ENSO_ROUTER)));

        address[] memory modules = new address[](2);
        modules[0] = acrossProxy;
        modules[1] = ensoProxy;
        bool[] memory enable = new bool[](2);
        enable[0] = true;
        enable[1] = true;

        dataProvider.configureDefaultModules(modules, enable);
        cashModule.configureModulesCanRequestWithdraw(modules, enable);
        roleRegistry.grantRole(AcrossSwapModule(acrossProxy).ACROSS_SWAP_MODULE_ADMIN_ROLE(), DEV_ADMIN);
        roleRegistry.grantRole(EnsoSwapModule(ensoProxy).ENSO_SWAP_MODULE_ADMIN_ROLE(), DEV_ADMIN);
        AcrossSwapModule(acrossProxy).setPeriphery(Prod.ACROSS_PERIPHERY);
    }

    function _assertConfigured() private view {
        require(address(uint160(uint256(vm.load(address(dataProvider), EIP1967_IMPL_SLOT)))) == dataProviderImpl, "DataProvider implementation mismatch");
        (bool bridgeGetterExists,) = address(dataProvider).staticcall(abi.encodeWithSignature("getOwnershipBridgeSender()"));
        require(!bridgeGetterExists, "ownership bridge API still active");

        address beacon = safeFactory.beacon();
        require(UpgradeableBeaconLike(beacon).implementation() == safeImpl, "EtherFiSafe implementation mismatch");
        require(dataProvider.isDefaultModule(acrossProxy), "Across not default");
        require(dataProvider.isDefaultModule(ensoProxy), "Enso not default");
        require(roleRegistry.hasRole(AcrossSwapModule(acrossProxy).ACROSS_SWAP_MODULE_ADMIN_ROLE(), DEV_ADMIN), "missing Across admin role");
        require(roleRegistry.hasRole(EnsoSwapModule(ensoProxy).ENSO_SWAP_MODULE_ADMIN_ROLE(), DEV_ADMIN), "missing Enso admin role");
        require(AcrossSwapModule(acrossProxy).getPeriphery() == Prod.ACROSS_PERIPHERY, "Across periphery mismatch");

        address[] memory withdrawModules = cashModule.getWhitelistedModulesCanRequestWithdraw();
        require(_contains(withdrawModules, acrossProxy), "Across cannot request withdrawals");
        require(_contains(withdrawModules, ensoProxy), "Enso cannot request withdrawals");
    }

    function _writeManifest() private {
        string memory key = "trading-account-dev-v2-op";
        vm.serializeAddress(key, "EtherFiDataProviderImpl", dataProviderImpl);
        vm.serializeAddress(key, "EtherFiSafeImpl", safeImpl);
        vm.serializeAddress(key, "AcrossSwapModule", acrossProxy);
        string memory json = vm.serializeAddress(key, "EnsoSwapModule", ensoProxy);
        string memory path = "./deployments/dev/10/trading-account-v2.json";
        vm.writeJson(json, path);
        console2.log("Wrote", path);
    }

    function _startBroadcast() private {
        uint256 privateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (privateKey == 0) {
            vm.startBroadcast(DEV_ADMIN);
        } else {
            require(vm.addr(privateKey) == DEV_ADMIN, "PRIVATE_KEY is not the dev admin");
            vm.startBroadcast(privateKey);
        }
    }

    function _deploy(string memory saltName, bytes memory creationCode, bytes memory constructorArgs) private returns (address) {
        return DEPLOYER.deploy(getSalt(saltName), abi.encodePacked(creationCode, constructorArgs));
    }

    function _contains(address[] memory values, address needle) private pure returns (bool) {
        for (uint256 i = 0; i < values.length; ++i) {
            if (values[i] == needle) return true;
        }
        return false;
    }
}

interface UpgradeableBeaconLike {
    function implementation() external view returns (address);
}
