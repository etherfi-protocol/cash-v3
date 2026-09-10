// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CREATE3 } from "solady/utils/CREATE3.sol";
import { console } from "forge-std/console.sol";

import { UUPSProxy } from "../../../src/UUPSProxy.sol";
import { Utils } from "../../utils/Utils.sol";
import { RoleRegistry } from "../../../src/role-registry/RoleRegistry.sol";

/**
 * @notice DEV-ONLY, chain-agnostic. Deploys the dev RoleRegistry at the canonical dev address
 *         `0xa322a04d1e2Cb44672473740F9F35B057FA29CFB` using the same CREATE3 salts that produced the
 *         dev RR on OP/Base/Eth/Scroll/Polygon. The **deployer EOA becomes the owner**, so it can
 *         grant roles / setPeer / setConfig / upgrade directly on dev (no 3CP). ENV=dev is the only
 *         guard (no chainid gate) so it works on any new dev chain (opBNB, Avalanche, …).
 *
 * Env:
 *   ENV=dev       — required
 *   PRIVATE_KEY   — dev deployer (becomes RoleRegistry owner)
 */
contract DeployDevRecoveryRoleRegistry is Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant EXPECTED_PROXY = 0xa322a04d1e2Cb44672473740F9F35B057FA29CFB;

    // From scripts/SetupOptimism.s.sol — same salts that produced dev RR on OP/Base/Eth/Scroll/Polygon.
    bytes32 constant SALT_ROLE_REGISTRY_IMPL  = 0x2460801a69e117b026fd3dca86328e4fc8efee57882c83dae34318e84ee193f2;
    bytes32 constant SALT_ROLE_REGISTRY_PROXY = 0x2cdd3a5a6d32bd8202f57f7d2c7a12505bd3ce5d4bf788c5d881fd2dd2e2f06a;

    function run() external {
        require(keccak256(bytes(getEnv())) == keccak256("dev"), "ENV must be dev");

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        address predictedProxy = CREATE3.predictDeterministicAddress(SALT_ROLE_REGISTRY_PROXY, NICKS_FACTORY);
        require(predictedProxy == EXPECTED_PROXY, "salt no longer predicts canonical dev RR address");

        vm.startBroadcast(deployerPk);

        address rrImpl = _deployCreate3(
            abi.encodePacked(type(RoleRegistry).creationCode, abi.encode(address(0))),
            SALT_ROLE_REGISTRY_IMPL
        );

        address proxy = _deployCreate3(
            abi.encodePacked(
                type(UUPSProxy).creationCode,
                abi.encode(rrImpl, abi.encodeCall(RoleRegistry.initialize, (deployer)))
            ),
            SALT_ROLE_REGISTRY_PROXY
        );

        vm.stopBroadcast();

        require(proxy == EXPECTED_PROXY, "proxy did not land at canonical dev address");
        require(RoleRegistry(proxy).owner() == deployer, "owner not set to deployer");

        console.log("=== Dev RoleRegistry (chain %s) ===", block.chainid);
        console.log("RoleRegistry proxy : %s (canonical dev)", proxy);
        console.log("RoleRegistry impl  : %s", rrImpl);
        console.log("Owner              : %s (deployer EOA)", deployer);
        console.log("");
        console.log("Record proxy under .addresses.RoleRegistry in deployments/dev/%s/deployments.json", vm.toString(block.chainid));
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
