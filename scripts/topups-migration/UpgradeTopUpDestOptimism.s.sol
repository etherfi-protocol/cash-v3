// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { Utils } from "../utils/Utils.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";

/**
 * @title UpgradeTopUpDestOptimism
 * @notice Upgrades TopUpDest on OP Mainnet (vanilla TopUpDest, no migration support).
 *         Deploys new TopUpDest impl via CREATE3, then generates a Gnosis Safe TX bundle
 *         for the multisig to upgrade the proxy.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/topups-migration/UpgradeTopUpDestOptimism.s.sol \
 *     --rpc-url $OPTIMISM_RPC --broadcast
 */
contract UpgradeTopUpDestOptimism is GnosisHelpers, Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant CASH_CONTROLLER_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address constant OP_WETH = 0x4200000000000000000000000000000000000006;

    bytes32 constant SALT_TOPUP_DEST_IMPL = keccak256("TopupsMigration.Prod.TopUpDestOptimismImpl");

    function run() public {
        require(block.chainid == 10, "Must run on OP Mainnet (10)");

        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        string memory deployments = readDeploymentFile();
        address dataProviderAddr = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        address topUpDestProxy   = stdJson.readAddress(deployments, ".addresses.TopUpDest");
        address roleRegistryAddr = stdJson.readAddress(deployments, ".addresses.RoleRegistry");
        string memory chainId    = vm.toString(block.chainid);

        console.log("DataProvider:", dataProviderAddr);
        console.log("TopUpDest proxy:", topUpDestProxy);

        // ════════════════════════════════════════════════════════════
        //  BROADCAST: deploy new TopUpDest impl via CREATE3
        // ════════════════════════════════════════════════════════════

        vm.startBroadcast(privateKey);

        address topUpDestImpl = deployCreate3(
            abi.encodePacked(
                type(TopUpDest).creationCode,
                abi.encode(dataProviderAddr, OP_WETH)
            ),
            SALT_TOPUP_DEST_IMPL
        );
        console.log("TopUpDest new impl:", topUpDestImpl);

        vm.stopBroadcast();

        // ════════════════════════════════════════════════════════════
        //  GNOSIS: generate TX bundle for cashControllerSafe
        // ════════════════════════════════════════════════════════════

        string memory txs = _getGnosisHeader(chainId, addressToHex(CASH_CONTROLLER_SAFE));

        // TX 1: Upgrade TopUpDest proxy
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(topUpDestProxy),
            iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, topUpDestImpl, "")),
            "0", true
        )));

        vm.createDir("./output", true);
        string memory path = string.concat("./output/UpgradeTopUpDestOptimism-", chainId, ".json");
        vm.writeFile(path, txs);
        console.log("\nGnosis bundle written to:", path);

        // ════════════════════════════════════════════════════════════
        //  SIMULATE: execute gnosis bundle on fork
        // ════════════════════════════════════════════════════════════

        executeGnosisTransactionBundle(path);
        console.log("[OK] Gnosis bundle simulation passed");

        // Post-execution ownership check
        address currentOwner = IRoleRegistry(roleRegistryAddr).owner();
        require(currentOwner == CASH_CONTROLLER_SAFE, "CRITICAL: RoleRegistry owner changed!");
        console.log("[OK] RoleRegistry owner unchanged:", currentOwner);
    }

    function deployCreate3(bytes memory creationCode, bytes32 salt) internal returns (address deployed) {
        deployed = CREATE3.predictDeterministicAddress(salt, NICKS_FACTORY);

        if (deployed.code.length > 0) {
            console.log("  [SKIP] already deployed at", deployed);
            return deployed;
        }

        address proxy = address(uint160(uint256(keccak256(abi.encodePacked(
            hex"ff", NICKS_FACTORY, salt, CREATE3.PROXY_INITCODE_HASH
        )))));

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
