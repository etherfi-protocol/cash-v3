// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { Utils } from "../../utils/Utils.sol";
import { MockERC20 } from "../../../src/mocks/MockERC20.sol";
import { BeaconFactory } from "../../../src/top-up/TopUpFactory.sol";

/**
 * @notice DEV-ONLY, Step 7a of the opBNB rehearsal (run on opBNB). Deploys an unsupported mock ERC20
 *         and mints it to the safe/TopUp address for SAFE_SALT — the address the OP-side recover()
 *         will target. (Safe on OP and TopUp on opBNB share the same CREATE3 address, both factories
 *         at 0xDe69…) The mock is CREATE3-deployed (raw call) to dodge forge's ctor-arg decode bug.
 *
 * Env: ENV=dev, PRIVATE_KEY
 * Run: ENV=dev forge script scripts/recovery/dev/SeedDevOpBnbRecovery.s.sol --rpc-url $OPBNB_RPC --broadcast
 */
contract SeedDevOpBnbRecovery is Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant SAFE_SALT  = keccak256("etherfi.dev.recovery.opbnb.e2e.v1");
    bytes32 constant TOKEN_SALT = keccak256("etherfi.dev.recovery.opbnb.mocktoken.v1");
    uint256 constant AMOUNT = 1000e18;

    function run() external {
        require(block.chainid == 204, "run on opBNB");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        string memory deployments = readDeploymentFile();
        address factory = stdJson.readAddress(deployments, ".addresses.TopUpSourceFactory");
        require(factory != address(0), "TopUpSourceFactory missing in dev/204");
        address topUp = BeaconFactory(factory).getDeterministicAddress(SAFE_SALT);

        vm.startBroadcast(pk);
        address token = _deployCreate3(
            abi.encodePacked(type(MockERC20).creationCode, abi.encode("RecoveryTest", "RCVT", uint8(18))),
            TOKEN_SALT
        );
        MockERC20(token).mint(topUp, AMOUNT);
        vm.stopBroadcast();

        console.log("Safe/TopUp address (fund target): %s", topUp);
        console.log("Mock token (unsupported)        : %s", token);
        console.log("Minted (wei)                    : %s", AMOUNT);
        console.log("");
        console.log("Next (on OP): TOKEN=%s forge script .../RunDevOpBnbRecovery.s.sol --rpc-url $OPTIMISM_RPC --broadcast", token);
    }

    function _deployCreate3(bytes memory creationCode, bytes32 salt) internal returns (address deployed) {
        deployed = CREATE3.predictDeterministicAddress(salt, NICKS_FACTORY);
        if (deployed.code.length > 0) {
            console.log("  [SKIP] token already deployed at", deployed);
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
