// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CREATE3 } from "solady/utils/CREATE3.sol";
import { console } from "forge-std/console.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { Utils } from "../utils/Utils.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";

/**
 * @notice Deploys a RoleRegistry for Asset Recovery on a chain that has no protocol presence
 *         (empty canonical factory slot — e.g. opBNB, X-Layer). The recovery dispatcher + TopUp
 *         factory both authorize against this RoleRegistry, so one must exist on the dest chain.
 *
 *         Owner is the **operating safe** (not the deployer), so all RoleRegistry-owner-gated
 *         operations (grantRole PAUSER/UNPAUSER, TopUpFactory.upgradeBeaconImplementation, the
 *         reserved-proxy upgrade where applicable) are signed via the operating safe's 3CP — the
 *         same signer flow as every existing recovery chain.
 *
 *         CREATE3 via Nick's factory with a recovery-specific salt, so the RoleRegistry lands at
 *         the same address on every new recovery chain (deployer-independent). The address is NOT
 *         canonical with the main-protocol RoleRegistry and does not need to be — the dispatcher
 *         takes RoleRegistry as an init param.
 *
 * Env:
 *   ENV=mainnet     — required
 *   OWNER           — optional override; defaults to the operating safe below
 *
 * Signer: pass via the CLI (e.g. `--ledger`, `--account`, or `--private-key`) like the other
 *         prod recovery scripts — the broadcast uses the default sender, so this works with the
 *         hardware-custodied prod deployer (0x8D5AAc…Bb150).
 */
contract DeployRecoveryRoleRegistry is Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    /// @notice Operating safe (RoleRegistry owner / pauser / 3CP signer) — same address on every chain.
    address constant OPERATING_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    // Recovery-specific CREATE3 salts (distinct from the main-protocol RoleRegistry salts).
    bytes32 constant SALT_RR_IMPL  = keccak256("etherfi.recovery.RoleRegistryImpl.v1");
    bytes32 constant SALT_RR_PROXY = keccak256("etherfi.recovery.RoleRegistryProxy.v1");

    function run() external {
        require(keccak256(bytes(getEnv())) == keccak256("mainnet"), "ENV must be mainnet");

        address owner = vm.envOr("OWNER", OPERATING_SAFE);
        require(owner.code.length > 0, "owner (operating safe) must be deployed on this chain");

        address predictedProxy = CREATE3.predictDeterministicAddress(SALT_RR_PROXY, NICKS_FACTORY);

        vm.startBroadcast();

        // _etherFiDataProvider is unused for recovery-only RoleRegistry → address(0).
        address rrImpl = _deployCreate3(
            abi.encodePacked(type(RoleRegistry).creationCode, abi.encode(address(0))),
            SALT_RR_IMPL
        );

        address proxy = _deployCreate3(
            abi.encodePacked(
                type(UUPSProxy).creationCode,
                abi.encode(rrImpl, abi.encodeCall(RoleRegistry.initialize, (owner)))
            ),
            SALT_RR_PROXY
        );

        vm.stopBroadcast();

        require(proxy == predictedProxy, "RoleRegistry proxy address mismatch");
        require(RoleRegistry(proxy).owner() == owner, "RoleRegistry owner not set to operating safe");

        console.log("=== Recovery RoleRegistry deployed ===");
        console.log("chainId            : %s", block.chainid);
        console.log("RoleRegistry proxy : %s", proxy);
        console.log("RoleRegistry impl  : %s", rrImpl);
        console.log("Owner              : %s (operating safe)", owner);
        console.log("");
        console.log("Record proxy under .addresses.RoleRegistry in deployments/mainnet/%s/deployments.json", vm.toString(block.chainid));
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
