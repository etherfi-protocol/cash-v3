// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { StockWithdrawModule } from "../../src/stock-withdraw/StockWithdrawModule.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";

/**
 * @notice Deploys the OP-side StockWithdrawModule (CREATE3 impl + CREATE3 UUPS proxy with
 *         atomic init). The mainnet StockUnwrapper does not exist yet at this point:
 *         initialize with stockUnwrapper = address(0); after the mainnet deploy, the module
 *         admin calls setDestination(dstEid, unwrapper).
 *
 * Rollout order:
 *   1. OP:  this script (unwrapper = 0) — run with --verify.
 *   2. ETH: DeployStockUnwrapper with SRC_MODULE = this proxy — run with --verify.
 *   3. OP admin:  module.setDestination(30101, <unwrapper proxy>).
 *   4. OP admin:  module.configureTokens([<iTokens>], [true]).
 *   5. ETH admin: unwrapper.configureAdapters([<OFTAdapters>], [true]).
 *   6. OP governance: dataProvider.configureModules([module], [true]),
 *      cashModule.configureModulesCanRequestWithdraw([module], [true]),
 *      grant STOCK_WITHDRAW_MODULE_ADMIN_ROLE; ETH governance: grant STOCK_UNWRAPPER_ADMIN_ROLE.
 *   7. Per-safe enable via ModuleManager.configureModules (user-signed).
 *
 * Env: PRIVATE_KEY, ETHERFI_DATA_PROVIDER, ROLE_REGISTRY, DST_EID (30101),
 *      COMPOSE_GAS_LIMIT (e.g. 300000)
 *
 * After broadcast, run VerifyStockWithdrawModule.s.sol against the live chain.
 */
contract DeployStockWithdrawModule is Script {
    address internal constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    bytes32 public constant SALT_STOCK_WITHDRAW_MODULE_IMPL = keccak256("DeployStockWithdrawModule.StockWithdrawModuleImpl");
    bytes32 public constant SALT_STOCK_WITHDRAW_MODULE_PROXY = keccak256("DeployStockWithdrawModule.StockWithdrawModuleProxy");

    // --- CREATE3 deploy helper (idempotent — skips if already deployed) ---
    function deployCreate3(bytes memory creationCode, bytes32 salt) internal returns (address deployed) {
        deployed = CREATE3.predictDeterministicAddress(salt, NICKS_FACTORY);

        if (deployed.code.length > 0) {
            console.log("  [SKIP] already deployed at", deployed);
            return deployed;
        }

        address proxy = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", NICKS_FACTORY, salt, CREATE3.PROXY_INITCODE_HASH)))));

        bool ok;
        if (proxy.code.length == 0) {
            (ok,) = NICKS_FACTORY.call(abi.encodePacked(salt, hex"67363d3d37363d34f03d5260086018f3"));
            require(ok, "CREATE3 proxy deploy failed");
        }

        (ok,) = proxy.call(creationCode);
        require(ok, "CREATE3 contract deploy failed");

        require(deployed.code.length > 0, "CREATE3 deployment verification failed");
    }

    function run() public {
        require(block.chainid == 10, "This script must be run on Optimism (chain ID 10)");

        address dataProvider = vm.envAddress("ETHERFI_DATA_PROVIDER");
        address roleRegistry = vm.envAddress("ROLE_REGISTRY");
        uint32 dstEid = uint32(vm.envUint("DST_EID"));
        uint128 composeGasLimit = uint128(vm.envUint("COMPOSE_GAS_LIMIT"));

        address ownerBefore = IRoleRegistry(roleRegistry).owner();

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        address impl = deployCreate3(
            abi.encodePacked(type(StockWithdrawModule).creationCode, abi.encode(dataProvider)),
            SALT_STOCK_WITHDRAW_MODULE_IMPL
        );

        address proxy = deployCreate3(
            abi.encodePacked(
                type(UUPSProxy).creationCode,
                abi.encode(impl, abi.encodeWithSelector(StockWithdrawModule.initialize.selector, roleRegistry, dstEid, address(0), composeGasLimit))
            ),
            SALT_STOCK_WITHDRAW_MODULE_PROXY
        );

        vm.stopBroadcast();

        // Post-operation hook: the timelock/registry owner must be unchanged.
        require(IRoleRegistry(roleRegistry).owner() == ownerBefore, "CRITICAL: role registry owner changed!");

        console.log("StockWithdrawModule impl:", impl);
        console.log("StockWithdrawModule proxy:", proxy);
    }
}
