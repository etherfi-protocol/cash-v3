// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { EnsoSwapModule } from "../../src/enso/EnsoSwapModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";

/// @notice Upgrades the existing dev EnsoSwapModule proxy on Ethereum or Optimism to the
///         implementation that supports signed, keeper-funded native fees.
///
/// Run once per chain:
///   forge script scripts/trading-account/UpgradeDevEnsoNativeFee.s.sol \
///     --rpc-url optimism --broadcast --verify
///   forge script scripts/trading-account/UpgradeDevEnsoNativeFee.s.sol \
///     --rpc-url mainnet --broadcast --verify
contract UpgradeDevEnsoNativeFee is Script {
    address private constant DEV_ADMIN = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;
    address private constant ETHEREUM_ENSO_PROXY = 0xa8eFf5BcC6De83d8B482049287b9C94ed7baA018;
    address private constant OPTIMISM_ENSO_PROXY = 0xd6B0c55f4F2bFdFe9355e5Af1Bac0f3DAb101DC2;
    bytes32 private constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external {
        address proxy = _proxyForChain();
        EnsoSwapModule current = EnsoSwapModule(proxy);
        address dataProvider = address(current.etherFiDataProvider());
        address cashModule = address(current.cashModule());
        address ensoRouter = current.getEnsoRouter();
        address roleRegistry = address(current.roleRegistry());
        address oldImplementation = _implementationOf(proxy);

        uint256 privateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (privateKey != 0) require(vm.addr(privateKey) == DEV_ADMIN, "PRIVATE_KEY is not the dev admin");
        require(RoleRegistry(roleRegistry).owner() == DEV_ADMIN, "dev admin is not RoleRegistry owner");

        if (privateKey == 0) vm.startBroadcast(DEV_ADMIN);
        else vm.startBroadcast(privateKey);
        EnsoSwapModule newImplementation = new EnsoSwapModule(dataProvider);
        UUPSUpgradeable(proxy).upgradeToAndCall(address(newImplementation), "");
        vm.stopBroadcast();

        require(_implementationOf(proxy) == address(newImplementation), "implementation mismatch");
        require(address(current.etherFiDataProvider()) == dataProvider, "data provider changed");
        require(address(current.cashModule()) == cashModule, "cash module changed");
        require(current.getEnsoRouter() == ensoRouter, "Enso router changed");
        require(address(current.roleRegistry()) == roleRegistry, "RoleRegistry changed");

        console2.log("chainId", block.chainid);
        console2.log("EnsoSwapModule proxy", proxy);
        console2.log("old implementation", oldImplementation);
        console2.log("new implementation", address(newImplementation));
    }

    function _proxyForChain() private view returns (address) {
        if (block.chainid == 1) return ETHEREUM_ENSO_PROXY;
        if (block.chainid == 10) return OPTIMISM_ENSO_PROXY;
        revert("unsupported chain");
    }

    function _implementationOf(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
    }
}
