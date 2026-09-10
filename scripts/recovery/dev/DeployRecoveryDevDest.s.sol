// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { UUPSProxy } from "../../../src/UUPSProxy.sol";
import { BeaconFactory } from "../../../src/top-up/TopUpFactory.sol";
import { AssetRecoveryDispatcher } from "../../../src/top-up/AssetRecoveryDispatcher.sol";
import { TopUpV2 } from "../../../src/top-up/TopUpV2.sol";
import { Utils } from "../../utils/Utils.sol";

/**
 * @notice DEV-ONLY. Deploys the dest-chain half of the recovery flow (dispatcher impl +
 *         proxy + TopUpV2 impl) on a single dest chain (Base in our test) and wires the
 *         dest-side state: dispatcher.setPeer(OP) + BeaconFactory.upgradeBeaconImplementation.
 *         Deployer EOA is used as delegate/owner everywhere.
 *
 * Env:
 *   ENV=dev       — required so Utils reads from deployments/dev/<chainId>/
 *   PRIVATE_KEY   — deployer (must be RoleRegistry owner on this dest chain)
 *   LZ_ENDPOINT   — LayerZero v2 endpoint on this chain
 *   MODULE_OP     — AssetRecoveryModule address from DeployRecoveryDevOp
 *   WETH          — WETH address on this chain (Base superchain WETH = 0x4200...0006)
 */
contract DeployRecoveryDevDest is Utils {
    uint32 internal constant OP_EID = 30_111;
    address internal constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    // Dev dispatcher proxy via CREATE3 (raw call -> forge doesn't decode ctor args; also deterministic).
    bytes32 internal constant SALT_DEV_DISPATCHER_PROXY = keccak256("etherfi.dev.recovery.dispatcher.v1");

    function run() external {
        require(block.chainid != 10, "must NOT be Optimism");

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address lzEndpoint = vm.envAddress("LZ_ENDPOINT");
        address moduleOp = vm.envAddress("MODULE_OP");
        address weth = vm.envAddress("WETH");

        string memory deployments = readDeploymentFile();
        address roleRegistry = stdJson.readAddress(deployments, ".addresses.RoleRegistry");
        address topUpFactory = stdJson.readAddress(deployments, ".addresses.TopUpSourceFactory");
        require(roleRegistry != address(0), "RoleRegistry missing");
        require(topUpFactory != address(0), "TopUpSourceFactory missing");
        require(topUpFactory.code.length > 0, "TopUpSourceFactory has no code");

        vm.startBroadcast(deployerPk);

        AssetRecoveryDispatcher dispatcherImpl = new AssetRecoveryDispatcher(lzEndpoint, OP_EID, topUpFactory);
        address dispatcherProxy = _deployCreate3(
            abi.encodePacked(
                type(UUPSProxy).creationCode,
                abi.encode(
                    address(dispatcherImpl),
                    abi.encodeCall(AssetRecoveryDispatcher.initialize, (deployer, roleRegistry))
                )
            ),
            SALT_DEV_DISPATCHER_PROXY
        );
        AssetRecoveryDispatcher dispatcher = AssetRecoveryDispatcher(dispatcherProxy);

        TopUpV2 topUpV2Impl = new TopUpV2(weth, address(dispatcher));

        dispatcher.setPeer(OP_EID, bytes32(uint256(uint160(moduleOp))));
        BeaconFactory(topUpFactory).upgradeBeaconImplementation(address(topUpV2Impl));

        vm.stopBroadcast();

        console.log("=== Dev dest-chain recovery deployed ===");
        console.log("chainId             : %s", block.chainid);
        console.log("Dispatcher impl     : %s", address(dispatcherImpl));
        console.log("Dispatcher proxy    : %s", address(dispatcher));
        console.log("TopUpV2 impl        : %s", address(topUpV2Impl));
        console.log("TopUpFactory beacon : %s (upgraded to TopUpV2)", topUpFactory);
        console.log("RoleRegistry        : %s", roleRegistry);
        console.log("LZ endpoint         : %s", lzEndpoint);
        console.log("Module on OP (peer) : %s", moduleOp);
        console.log("Owner / delegate    : %s (deployer EOA)", deployer);
        console.log("");
        console.log("Pass DISPATCHER=%s into WireRecoveryDevOp", address(dispatcher));
    }

    function _deployCreate3(bytes memory creationCode, bytes32 salt) internal returns (address deployed) {
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
}
