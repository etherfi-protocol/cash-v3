// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console2 } from "forge-std/console2.sol";

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { RoleRegistry } from "../../../src/role-registry/RoleRegistry.sol";
import { EtherFiDataProvider } from "../../../src/data-provider/EtherFiDataProvider.sol";
import { PriceProviderV2 } from "../../../src/oracle/PriceProviderV2.sol";
import { AcrossSwapModule } from "../../../src/across/AcrossSwapModule.sol";
import { EnsoSwapModule } from "../../../src/enso/EnsoSwapModule.sol";
import { TradingLens } from "../../../src/trading-safe/TradingLens.sol";
import { EtherFiDeployer } from "../../../src/utils/EtherFiDeployer.sol";
import { Utils } from "../../utils/Utils.sol";

/**
 * @notice Re-gates the Ethereum dev trading stack - its own RoleRegistry, EtherFiDataProvider,
 *         PriceProvider (V2), AcrossSwapModule, EnsoSwapModule and TradingLens, matching the
 *         prod trading stacks.
 *
 *         The trading RoleRegistry is a separate registry from the cash one (its
 *         `etherFiDataProvider` immutable points at the trading data provider, which has no
 *         CashModule), and none of it is re-gated yet. Order matters: the registry must be
 *         re-gated and DEV_ADMIN granted ADMIN_ROLE / ADMIN_TIMELOCK_ROLE before any consumer
 *         whose re-gated code gates on those roles is upgraded, or DEV_ADMIN would lock itself
 *         out of configuring it. This script does the registry first.
 *
 *         Idempotent - every deploy, upgrade and grant is skipped when already in the target
 *         state. With PRIVATE_KEY unset the run impersonates DEV_ADMIN (fork simulation); a real
 *         broadcast must supply the dev admin key.
 *
 * Usage (simulate):
 *   source .env && forge script scripts/dev/role-regating/DeployRoleRegatingTradingEthDev.s.sol \
 *     --rpc-url $MAINNET_RPC
 *
 * Usage (broadcast):
 *   source .env && forge script scripts/dev/role-regating/DeployRoleRegatingTradingEthDev.s.sol \
 *     --rpc-url $MAINNET_RPC --broadcast --verify
 */
contract DeployRoleRegatingTradingEthDev is Utils {
    EtherFiDeployer private constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);
    address private constant DEV_ADMIN = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;

    address private constant ROLE_REGISTRY = 0x823a20D7e0586423dD2f99724479C74d8B65794E;
    address private constant DATA_PROVIDER = 0x2e2790AaE33b8f287D6eEB479011bF655D9738D4;
    address private constant PRICE_PROVIDER = 0x18120B84dF313BB486B0713A07e2401A56F22Df1;
    address private constant ACROSS_SWAP_MODULE = 0xCBF1aBb10FC6909470a55DEcaFC31DFBF6cf7A92;
    address private constant ENSO_SWAP_MODULE = 0xa8eFf5BcC6De83d8B482049287b9C94ed7baA018;
    address private constant TRADING_LENS = 0xC6d33e123164e540431165C22dC9D9f09cFb00e9;

    string private constant SALT_PREFIX = "RoleRegating.Dev.v1.TradingEth.";

    function run() external {
        require(block.chainid == 1, "must run on Ethereum");
        require(DEPLOYER.isDeployer(DEV_ADMIN), "dev admin is not an EtherFiDeployer");

        RoleRegistry registry = RoleRegistry(ROLE_REGISTRY);
        require(registry.owner() == DEV_ADMIN, "dev admin does not own the trading RoleRegistry");
        require(address(registry.etherFiDataProvider()) == DATA_PROVIDER, "registry points at the wrong trading data provider");
        require(EtherFiDataProvider(DATA_PROVIDER).getCashModule() == address(0), "unexpected cash module on trading stack");

        _startBroadcast();

        _regateRoleRegistry(registry);
        _upgradeConsumers();

        vm.stopBroadcast();

        require(registry.owner() == DEV_ADMIN, "CRITICAL: trading RoleRegistry owner changed!");
        require(registry.hasRole(registry.ADMIN_ROLE(), DEV_ADMIN), "CRITICAL: DEV_ADMIN lost ADMIN_ROLE!");
        require(registry.hasRole(registry.ADMIN_TIMELOCK_ROLE(), DEV_ADMIN), "CRITICAL: DEV_ADMIN lost ADMIN_TIMELOCK_ROLE!");
        console2.log("  [OK] trading governance unchanged");
    }

    function _regateRoleRegistry(RoleRegistry registry) internal {
        console2.log("=== Re-gating trading RoleRegistry ===");
        address newImpl = _deploy("RoleRegistryImpl", abi.encodePacked(type(RoleRegistry).creationCode, abi.encode(DATA_PROVIDER)));

        if (_currentImpl(address(registry)) != newImpl) {
            UUPSUpgradeable(address(registry)).upgradeToAndCall(newImpl, "");
            require(_currentImpl(address(registry)) == newImpl, "trading RoleRegistry upgrade did not stick");
            console2.log("  [OK] trading RoleRegistry upgraded");
        } else {
            console2.log("  [SKIP] trading RoleRegistry already on target impl");
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

    function _upgradeConsumers() internal returns (address dataProviderImpl, address priceProviderImpl, address acrossImpl, address ensoImpl, address tradingLensImpl) {
        console2.log("=== Upgrading trading stack consumers ===");

        dataProviderImpl = _deploy("EtherFiDataProviderImpl", abi.encodePacked(type(EtherFiDataProvider).creationCode));
        _upgrade("EtherFiDataProvider (trading)", DATA_PROVIDER, dataProviderImpl);

        priceProviderImpl = _deploy("PriceProviderV2Impl", abi.encodePacked(type(PriceProviderV2).creationCode));
        _upgrade("PriceProvider (trading)", PRICE_PROVIDER, priceProviderImpl);

        acrossImpl = _deploy("AcrossSwapModuleImpl", abi.encodePacked(type(AcrossSwapModule).creationCode, abi.encode(DATA_PROVIDER)));
        _upgrade("AcrossSwapModule (trading)", ACROSS_SWAP_MODULE, acrossImpl);

        ensoImpl = _deploy("EnsoSwapModuleImpl", abi.encodePacked(type(EnsoSwapModule).creationCode, abi.encode(DATA_PROVIDER)));
        _upgrade("EnsoSwapModule (trading)", ENSO_SWAP_MODULE, ensoImpl);

        tradingLensImpl = _deploy("TradingLensImpl", abi.encodePacked(type(TradingLens).creationCode, abi.encode(PRICE_PROVIDER)));
        _upgrade("TradingLens", TRADING_LENS, tradingLensImpl);
    }


    function _upgrade(string memory label, address proxy, address newImpl) internal {
        if (_currentImpl(proxy) == newImpl) {
            console2.log(string.concat("  [SKIP] ", label, " already on target impl"));
            return;
        }
        UUPSUpgradeable(proxy).upgradeToAndCall(newImpl, "");
        require(_currentImpl(proxy) == newImpl, string.concat(label, ": upgrade did not stick"));
        console2.log(string.concat("  [OK] ", label, " upgraded"));
    }

    function _deploy(string memory name, bytes memory creationCode) internal returns (address deployed) {
        bytes32 salt = getSalt(string.concat(SALT_PREFIX, name));
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
