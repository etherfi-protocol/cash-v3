// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { EtherFiOFTBridgeAdapter } from "../../src/top-up/bridge/EtherFiOFTBridgeAdapter.sol";
import { CCTPAdapter } from "../../src/top-up/bridge/CCTPAdapter.sol";
import { TopUpConfigHelper } from "../utils/TopUpConfigHelper.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";

/**
 * @title UpgradeTopUpFactoryHyperEVM
 * @notice Upgrades TopUpFactory on HyperEVM and deploys 2 bridge adapters.
 *
 *         Deploys via CREATE3:
 *         - New TopUpFactory impl
 *         - CCTPAdapter
 *         - EtherFiOFTBridgeAdapter
 *
 * Usage:
 *   ENV=mainnet forge script scripts/topups-migration/UpgradeTopUpFactoryHyperEVM.s.sol \
 *     --rpc-url $HYPEREVM_RPC --broadcast
 */
contract UpgradeTopUpFactoryHyperEVM is TopUpConfigHelper, GnosisHelpers {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant CASH_CONTROLLER_SAFE = 0xf27128a5b064e8d97EDaa60D24bFa2FD1eeC26eB;

    // CREATE3 salts
    bytes32 constant SALT_FACTORY_IMPL = keccak256("TopupsMigration.Prod.TopUpFactoryHyperEVMImpl");
    bytes32 constant SALT_CCTP_ADAPTER = keccak256("TopupsMigration.Prod.CCTPAdapterHyperEVM");
    bytes32 constant SALT_OFT_ADAPTER  = keccak256("TopupsMigration.Prod.EtherFiOFTBridgeAdapterHyperEVM");

    function run() public {
        require(block.chainid == 999, "Must run on HyperEVM (999)");

        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        string memory deployments = readTopUpSourceDeployment();
        address factoryProxy = stdJson.readAddress(deployments, ".addresses.TopUpSourceFactory");
        address roleRegistryAddr = stdJson.readAddress(deployments, ".addresses.RoleRegistry");
        string memory chainId = vm.toString(block.chainid);

        console.log("TopUpFactory proxy:", factoryProxy);

        vm.startBroadcast(privateKey);

        address factoryImpl = deployCreate3(abi.encodePacked(type(TopUpFactory).creationCode), SALT_FACTORY_IMPL);
        console.log("TopUpFactory impl:", factoryImpl);

        address cctp = deployCreate3(abi.encodePacked(type(CCTPAdapter).creationCode), SALT_CCTP_ADAPTER);
        console.log("CCTPAdapter:", cctp);

        address oft = deployCreate3(abi.encodePacked(type(EtherFiOFTBridgeAdapter).creationCode), SALT_OFT_ADAPTER);
        console.log("EtherFiOFTBridgeAdapter:", oft);

        vm.stopBroadcast();

        // Set all adapter addresses
        cctpAdapter = cctp;
        etherFiOFTBridgeAdapter = oft;

        topUpFactory = TopUpFactory(payable(factoryProxy));
        (address[] memory tokens, uint256[] memory chainIds, TopUpFactory.TokenConfig[] memory configs) = parseAllTokenConfigs();

        string memory txs = _getGnosisHeader(chainId, addressToHex(CASH_CONTROLLER_SAFE));

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(factoryProxy),
            iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, factoryImpl, "")),
            "0", false
        )));

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(factoryProxy),
            iToHex(abi.encodeWithSelector(TopUpFactory.setTokenConfig.selector, tokens, chainIds, configs)),
            "0", true
        )));

        vm.createDir("./output", true);
        string memory path = string.concat("./output/UpgradeTopUpFactoryHyperEVM-", chainId, ".json");
        vm.writeFile(path, txs);
        console.log("\nGnosis bundle written to:", path);

        executeGnosisTransactionBundle(path);
        console.log("[OK] Gnosis bundle simulation passed");

        address currentOwner = IRoleRegistry(roleRegistryAddr).owner();
        require(currentOwner == CASH_CONTROLLER_SAFE, "CRITICAL: RoleRegistry owner changed!");
        console.log("[OK] RoleRegistry owner unchanged:", currentOwner);
        console.log("\nConfigured %s token+chain pairs", tokens.length);
    }

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
}
