// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";
import { console } from "forge-std/console.sol";

import { UUPSProxy } from "../../../src/UUPSProxy.sol";
import { Utils } from "../../utils/Utils.sol";
import { TopUpFactory } from "../../../src/top-up/TopUpFactory.sol";
import { TopUp } from "../../../src/top-up/TopUp.sol";

/**
 * @notice DEV-ONLY. Deploys the dev TopUp `BeaconFactory` on opBNB at the **canonical dev address**
 *         `0xDe69649e21DDceeC86738211dCe6f7Bb4DEcd27B` using the dev safe-factory CREATE3 salts (same
 *         salts as the dev factory on OP/Base/Polygon). Mirrors `DeployDevPolygonTopUpFactory` with
 *         opBNB WBNB. Landing at the canonical address makes `getDeterministicAddress(salt)` match a
 *         real dev safe, so the recovery dispatcher can resolve + sweep it. On dev opBNB this slot is
 *         empty, so we deploy fresh (no placeholder/reinitializer).
 *
 * Env:
 *   ENV=dev       — required (reads/writes deployments/dev/204)
 *   PRIVATE_KEY   — dev deployer (RoleRegistry owner: 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E)
 *   WBNB          — opBNB wrapped native (default below)
 */
contract DeployDevOpBnbTopUpFactory is Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant EXPECTED_FACTORY = 0xDe69649e21DDceeC86738211dCe6f7Bb4DEcd27B;
    // opBNB wrapped native (OP-stack predeploy) — symbol "WBNB", verified on-chain.
    address constant DEFAULT_WBNB = 0x4200000000000000000000000000000000000006;

    // Dev safe-factory CREATE3 salts (identical across chains -> same canonical dev address).
    bytes32 constant SALT_FACTORY_PROXY = 0xf8a17770967b5e97224007959b54d404185c01430bf45f1048077170756cf305;
    bytes32 constant SALT_TOPUP_IMPL    = 0x46c5c6bcff9d7a0c52cab6e0c76f094300cb0d93a9ee3b69b5f18d2f51217458;
    bytes32 constant SALT_FACTORY_IMPL  = 0xc8e64830043c6ed113c4b9f1ff41f8a859a0a99b497a8ea4468021dc5ddf717f;

    function run() external {
        require(block.chainid == 204, "must be opBNB");
        require(keccak256(bytes(getEnv())) == keccak256("dev"), "ENV must be dev");

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address wbnb = vm.envOr("WBNB", DEFAULT_WBNB);
        require(wbnb.code.length > 0, "WBNB has no code");

        string memory deployments = readDeploymentFile();
        address roleRegistry = stdJson.readAddress(deployments, ".addresses.RoleRegistry");
        require(roleRegistry != address(0) && roleRegistry.code.length > 0, "dev RoleRegistry missing (deploy it first)");

        address predictedProxy = CREATE3.predictDeterministicAddress(SALT_FACTORY_PROXY, NICKS_FACTORY);
        require(predictedProxy == EXPECTED_FACTORY, "salt no longer predicts canonical dev factory address");

        vm.startBroadcast(deployerPk);

        address factoryImpl = _deployCreate3(abi.encodePacked(type(TopUpFactory).creationCode), SALT_FACTORY_IMPL);
        address topUpImpl   = _deployCreate3(abi.encodePacked(type(TopUp).creationCode, abi.encode(wbnb)), SALT_TOPUP_IMPL);

        bytes memory initData = abi.encodeWithSelector(TopUpFactory.initialize.selector, roleRegistry, topUpImpl);
        address proxy = _deployCreate3(
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(factoryImpl, initData)),
            SALT_FACTORY_PROXY
        );

        vm.stopBroadcast();

        require(proxy == EXPECTED_FACTORY, "factory proxy did not land at canonical dev address");
        require(address(TopUpFactory(payable(proxy)).roleRegistry()) == roleRegistry, "roleRegistry wiring failed");
        require(TopUpFactory(payable(proxy)).beacon() != address(0), "beacon not set");

        console.log("=== Dev opBNB TopUp factory ===");
        console.log("TopUpFactory proxy : %s (canonical dev)", proxy);
        console.log("TopUpFactory impl  : %s", factoryImpl);
        console.log("TopUp impl (WBNB)  : %s", topUpImpl);
        console.log("RoleRegistry       : %s", roleRegistry);
        console.log("");
        console.log("Record proxy under .addresses.TopUpSourceFactory in deployments/dev/204/deployments.json");
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
