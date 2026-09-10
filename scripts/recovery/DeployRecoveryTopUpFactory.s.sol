// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";
import { console } from "forge-std/console.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { Utils } from "../utils/Utils.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { TopUp } from "../../src/top-up/TopUp.sol";

/**
 * @notice Deploys a working TopUp `BeaconFactory` at the canonical CREATE3 address
 *         `0xF4e147…D8CF` on a recovery dest chain whose slot is **empty** (no prior reservation —
 *         e.g. opBNB, X-Layer). Because the slot is empty, the proxy initializes through the
 *         already-audited `TopUpFactory.initialize` — no `reinitialize`, no new audit. (Chains that
 *         were pre-reserved with an EtherFiPlaceholder instead need the reinitialize upgrade path —
 *         see DeployPolygonTopUpFactory.s.sol.)
 *
 *         Landing at the canonical address is what makes `getDeterministicAddress(salt)` resolve a
 *         user's stuck-funds address, so the recovery dispatcher can lazily deploy + sweep it.
 *
 *         Wrapped-native is REQUIRED via env (no default) — it is baked into the TopUp `weth`
 *         immutable forever, so it must be passed explicitly and correctly per chain:
 *           opBNB  → WBNB 0x4200000000000000000000000000000000000006
 *           X-Layer→ WOKB 0xe538905cf8410324e03A5A23C1c177a474D59b2b
 *
 * Env:
 *   ENV=mainnet        — required
 *   WRAPPED_NATIVE     — required; the chain's canonical wrapped-native (TopUp.weth immutable)
 *
 * Signer: pass via the CLI (`--ledger` / `--account` / `--private-key`) like the other prod
 *         recovery scripts. Prereq: RoleRegistry already deployed + recorded in
 *         deployments/mainnet/<id>/deployments.json (run DeployRecoveryRoleRegistry.s.sol first).
 */
contract DeployRecoveryTopUpFactory is Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant EXPECTED_FACTORY = 0xF4e147Db314947fC1275a8CbB6Cde48c510cd8CF;

    // Prod safe-factory CREATE3 salts (from DeployTopUpFactoryHyperEVM.s.sol).
    // SALT_FACTORY_PROXY produces the canonical 0xF4e147…D8CF via Nick's factory.
    bytes32 constant SALT_TOPUP_IMPL    = 0xff29656f33cc018695c4dadfbd883155f1ef30d667ca50827a9b9c56a50fe803;
    bytes32 constant SALT_FACTORY_IMPL  = 0x89a0cb186faf1ec3240a4a2bdefe0124bd4fac7547ef1d07ad0d1f1a9f30cafe;
    bytes32 constant SALT_FACTORY_PROXY = 0x4039d84c2c2b96cb1babbf2ca5c0b7be213be8ad0110e70d6e2d570741ef168b;

    function run() external {
        require(keccak256(bytes(getEnv())) == keccak256("mainnet"), "ENV must be mainnet");

        address wrappedNative = vm.envAddress("WRAPPED_NATIVE");
        require(wrappedNative.code.length > 0, "WRAPPED_NATIVE has no code on this chain");

        string memory deployments = readDeploymentFile();
        address roleRegistry = stdJson.readAddress(deployments, ".addresses.RoleRegistry");
        require(roleRegistry != address(0) && roleRegistry.code.length > 0, "RoleRegistry missing (deploy it first)");

        address predictedProxy = CREATE3.predictDeterministicAddress(SALT_FACTORY_PROXY, NICKS_FACTORY);
        require(predictedProxy == EXPECTED_FACTORY, "salt no longer predicts canonical factory address");
        require(EXPECTED_FACTORY.code.length == 0, "canonical factory slot is not empty (reserved? use the placeholder-upgrade path)");

        vm.startBroadcast();

        address factoryImpl = _deployCreate3(abi.encodePacked(type(TopUpFactory).creationCode), SALT_FACTORY_IMPL);
        address topUpImpl   = _deployCreate3(abi.encodePacked(type(TopUp).creationCode, abi.encode(wrappedNative)), SALT_TOPUP_IMPL);

        bytes memory initData = abi.encodeCall(TopUpFactory.initialize, (roleRegistry, topUpImpl));
        address proxy = _deployCreate3(
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(factoryImpl, initData)),
            SALT_FACTORY_PROXY
        );

        vm.stopBroadcast();

        require(proxy == EXPECTED_FACTORY, "factory proxy did not land at canonical address");
        require(address(TopUpFactory(payable(proxy)).roleRegistry()) == roleRegistry, "roleRegistry wiring failed");
        require(TopUpFactory(payable(proxy)).beacon() != address(0), "beacon not set");
        require(TopUp(payable(topUpImpl)).weth() == wrappedNative, "TopUp weth immutable mismatch");

        console.log("=== Recovery TopUp factory deployed ===");
        console.log("chainId             : %s", block.chainid);
        console.log("TopUpFactory proxy  : %s (canonical)", proxy);
        console.log("TopUpFactory impl   : %s", factoryImpl);
        console.log("TopUp impl          : %s", topUpImpl);
        console.log("Wrapped native      : %s", wrappedNative);
        console.log("RoleRegistry        : %s", roleRegistry);
        console.log("");
        console.log("Record proxy under .addresses.TopUpSourceFactory in deployments/mainnet/%s/deployments.json", vm.toString(block.chainid));
        console.log("Beacon still points at base TopUp impl; the dest 3CP upgrades it to TopUpV2.");
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
