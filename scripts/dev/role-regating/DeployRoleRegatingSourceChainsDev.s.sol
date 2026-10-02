// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console2 } from "forge-std/console2.sol";

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { RoleRegistry } from "../../../src/role-registry/RoleRegistry.sol";
import { TopUpFactory } from "../../../src/top-up/TopUpFactory.sol";
import { StockUnwrapper } from "../../../src/stock-withdraw/StockUnwrapper.sol";
import { EtherFiDeployer } from "../../../src/utils/EtherFiDeployer.sol";
import { Utils } from "../../utils/Utils.sol";

/**
 * @notice Re-gates the dev RoleRegistry and upgrades the dev TopUpSourceFactory (the deployed
 *         name for `TopUpFactory`) on each of the top-up source chains - Ethereum, Arbitrum,
 *         Base and HyperEVM - mirroring prod's role-gating batch 2. Ethereum additionally
 *         upgrades `StockUnwrapper`, which batch 2/3 covered there too.
 *
 *         Unlike OP, none of these RoleRegistries are re-gated yet: this script deploys the new
 *         impl, upgrades the proxy, and grants DEV_ADMIN (who already owns every one of these
 *         registries) ADMIN_ROLE and ADMIN_TIMELOCK_ROLE. That must land before
 *         TopUpSourceFactory / StockUnwrapper are upgraded, since their re-gated code's
 *         `onlyAdmin`/`onlyAdminTimelock` modifiers resolve against those roles - this script
 *         orders it that way.
 *
 *         Run once per chain (block.chainid picks the right addresses). Idempotent - every
 *         deploy, upgrade and grant is skipped when already in the target state. With
 *         PRIVATE_KEY unset the run impersonates DEV_ADMIN (fork simulation); a real broadcast
 *         must supply the dev admin key.
 *
 * Usage (simulate):
 *   source .env && forge script scripts/dev/role-regating/DeployRoleRegatingSourceChainsDev.s.sol \
 *     --rpc-url $MAINNET_RPC   (or $ARBITRUM_RPC / $BASE_RPC / $HYPEREVM_RPC)
 *
 * Usage (broadcast):
 *   source .env && forge script scripts/dev/role-regating/DeployRoleRegatingSourceChainsDev.s.sol \
 *     --rpc-url $MAINNET_RPC --broadcast --verify
 */
contract DeployRoleRegatingSourceChainsDev is Utils {
    EtherFiDeployer private constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);
    address private constant DEV_ADMIN = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;

    address private constant ROLE_REGISTRY_SHARED = 0xa322a04d1e2Cb44672473740F9F35B057FA29CFB; // ETH, Base
    address private constant ROLE_REGISTRY_ARB = 0xf8D1e66850888b97A99c482862211F043E2eC530;
    address private constant ROLE_REGISTRY_HYPEREVM = 0x15385779799bD369f3Af0Df562cB4b3E38586b74;

    address private constant TOP_UP_SOURCE_FACTORY_SHARED = 0xDe69649e21DDceeC86738211dCe6f7Bb4DEcd27B; // ETH, Arb, Base
    address private constant TOP_UP_SOURCE_FACTORY_HYPEREVM = 0x5c361f94a23c015083b48e833D5B2E9c64cFBcf0;

    address private constant STOCK_UNWRAPPER_ETH = 0xd020D5ADCDf0fAD06c853482cfd921a383aeFF12;

    string private constant SALT_PREFIX = "RoleRegating.Dev.v1.";

    function run() external {
        uint256 chainId = block.chainid;
        require(chainId == 1 || chainId == 42161 || chainId == 8453 || chainId == 999, "unsupported chain");
        require(DEPLOYER.isDeployer(DEV_ADMIN), "dev admin is not an EtherFiDeployer");

        address roleRegistry = _roleRegistryFor(chainId);
        address topUpSourceFactory = _topUpSourceFactoryFor(chainId);

        RoleRegistry registry = RoleRegistry(roleRegistry);
        require(registry.owner() == DEV_ADMIN, "dev admin does not own this chain's RoleRegistry");
        require(address(registry.etherFiDataProvider()) == address(0), "this registry unexpectedly has a data provider");

        _startBroadcast();

        address newRegistryImpl = _regateRoleRegistry(registry);
        address newTopUpFactoryImpl = _upgradeTopUpSourceFactory(topUpSourceFactory);
        address newStockUnwrapperImpl;
        if (chainId == 1) {
            newStockUnwrapperImpl = _upgradeStockUnwrapper();
        }

        vm.stopBroadcast();

        require(registry.owner() == DEV_ADMIN, "CRITICAL: RoleRegistry owner changed!");
        require(registry.hasRole(registry.ADMIN_ROLE(), DEV_ADMIN), "CRITICAL: DEV_ADMIN lost ADMIN_ROLE!");
        require(registry.hasRole(registry.ADMIN_TIMELOCK_ROLE(), DEV_ADMIN), "CRITICAL: DEV_ADMIN lost ADMIN_TIMELOCK_ROLE!");
        console2.log("  [OK] governance unchanged");

        _writeManifest(chainId, newRegistryImpl, newTopUpFactoryImpl, newStockUnwrapperImpl);
    }

    function _roleRegistryFor(uint256 chainId) internal pure returns (address) {
        if (chainId == 42161) return ROLE_REGISTRY_ARB;
        if (chainId == 999) return ROLE_REGISTRY_HYPEREVM;
        return ROLE_REGISTRY_SHARED;
    }

    function _topUpSourceFactoryFor(uint256 chainId) internal pure returns (address) {
        if (chainId == 999) return TOP_UP_SOURCE_FACTORY_HYPEREVM;
        return TOP_UP_SOURCE_FACTORY_SHARED;
    }

    function _regateRoleRegistry(RoleRegistry registry) internal returns (address newImpl) {
        console2.log("=== Re-gating RoleRegistry ===");
        newImpl = _deploy("RoleRegistryImpl", abi.encodePacked(type(RoleRegistry).creationCode, abi.encode(address(0))));

        if (_currentImpl(address(registry)) != newImpl) {
            UUPSUpgradeable(address(registry)).upgradeToAndCall(newImpl, "");
            require(_currentImpl(address(registry)) == newImpl, "RoleRegistry upgrade did not stick");
            console2.log("  [OK] RoleRegistry upgraded");
        } else {
            console2.log("  [SKIP] RoleRegistry already on target impl");
        }

        bytes32 adminRole = registry.ADMIN_ROLE();
        bytes32 adminTimelockRole = registry.ADMIN_TIMELOCK_ROLE();
        if (!registry.hasRole(adminRole, DEV_ADMIN)) {
            registry.grantRole(adminRole, DEV_ADMIN);
            console2.log("  [OK] granted ADMIN_ROLE to DEV_ADMIN");
        } else {
            console2.log("  [SKIP] DEV_ADMIN already holds ADMIN_ROLE");
        }
        if (!registry.hasRole(adminTimelockRole, DEV_ADMIN)) {
            registry.grantRole(adminTimelockRole, DEV_ADMIN);
            console2.log("  [OK] granted ADMIN_TIMELOCK_ROLE to DEV_ADMIN");
        } else {
            console2.log("  [SKIP] DEV_ADMIN already holds ADMIN_TIMELOCK_ROLE");
        }
    }

    function _upgradeTopUpSourceFactory(address proxy) internal returns (address newImpl) {
        console2.log("=== Upgrading TopUpSourceFactory (TopUpFactory contract) ===");
        newImpl = _deploy("TopUpFactoryImpl", abi.encodePacked(type(TopUpFactory).creationCode));

        if (_currentImpl(proxy) == newImpl) {
            console2.log("  [SKIP] TopUpSourceFactory already on target impl");
            return newImpl;
        }
        UUPSUpgradeable(proxy).upgradeToAndCall(newImpl, "");
        require(_currentImpl(proxy) == newImpl, "TopUpSourceFactory upgrade did not stick");
        console2.log("  [OK] TopUpSourceFactory upgraded");
    }

    function _upgradeStockUnwrapper() internal returns (address newImpl) {
        console2.log("=== Upgrading StockUnwrapper ===");
        newImpl = _deploy("StockUnwrapperImpl", abi.encodePacked(type(StockUnwrapper).creationCode));

        if (_currentImpl(STOCK_UNWRAPPER_ETH) == newImpl) {
            console2.log("  [SKIP] StockUnwrapper already on target impl");
            return newImpl;
        }
        UUPSUpgradeable(STOCK_UNWRAPPER_ETH).upgradeToAndCall(newImpl, "");
        require(_currentImpl(STOCK_UNWRAPPER_ETH) == newImpl, "StockUnwrapper upgrade did not stick");
        console2.log("  [OK] StockUnwrapper upgraded");
    }

    function _deploy(string memory name, bytes memory creationCode) internal returns (address deployed) {
        bytes32 salt = getSalt(string.concat(SALT_PREFIX, vm.toString(block.chainid), ".", name));
        deployed = DEPLOYER.getDeterministicAddress(salt);
        if (deployed.code.length > 0) {
            console2.log(string.concat("  [SKIP] ", name, " already deployed at"), deployed);
            return deployed;
        }
        address result = DEPLOYER.deploy(salt, creationCode);
        require(result == deployed, string.concat(name, ": deployed off the predicted address"));
        console2.log(string.concat("  [OK] deployed ", name, " at"), deployed);
    }

    function _currentImpl(address proxy) internal view returns (address) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        return address(uint160(uint256(vm.load(proxy, slot))));
    }

    function _writeManifest(uint256 chainId, address registryImpl, address topUpFactoryImpl, address stockUnwrapperImpl) internal {
        string memory path = string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(chainId), "/role-regating.json");
        string memory obj = "role-regating-source-dev";

        string memory json = vm.serializeAddress(obj, "RoleRegistryImpl", registryImpl);
        json = vm.serializeAddress(obj, "TopUpFactoryImpl", topUpFactoryImpl);
        if (chainId == 1) {
            json = vm.serializeAddress(obj, "StockUnwrapperImpl", stockUnwrapperImpl);
        }

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
}
