// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { StargateAdapter } from "../../src/top-up/bridge/StargateAdapter.sol";
import { EtherFiLiquidBridgeAdapter } from "../../src/top-up/bridge/EtherFiLiquidBridgeAdapter.sol";
import { EtherFiOFTBridgeAdapter } from "../../src/top-up/bridge/EtherFiOFTBridgeAdapter.sol";
import { CCTPAdapter } from "../../src/top-up/bridge/CCTPAdapter.sol";
import { TopUpConfigHelper } from "../utils/TopUpConfigHelper.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";

/**
 * @title UpgradeTopUpFactoryBase
 * @notice Upgrades TopUpFactory on Base and deploys 4 fresh bridge adapters.
 *         Reuses existing BaseWithdrawERC20BridgeAdapter.
 *
 *         Deploys via CREATE3:
 *         - New TopUpFactory impl
 *         - CCTPAdapter
 *         - EtherFiLiquidBridgeAdapter
 *         - EtherFiOFTBridgeAdapter
 *         - StargateAdapter
 *
 *         Reuses from existing deployment:
 *         - BaseWithdrawERC20BridgeAdapter
 *
 * Usage:
 *   ENV=mainnet forge script scripts/topups-migration/UpgradeTopUpFactoryBase.s.sol \
 *     --rpc-url $BASE_RPC --broadcast
 */
contract UpgradeTopUpFactoryBase is TopUpConfigHelper, GnosisHelpers {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant CASH_CONTROLLER_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address constant BASE_WETH = 0x4200000000000000000000000000000000000006;

    // CREATE3 salts
    bytes32 constant SALT_FACTORY_IMPL   = keccak256("TopupsMigration.Prod.TopUpFactoryBaseImpl");
    bytes32 constant SALT_CCTP_ADAPTER   = keccak256("TopupsMigration.Prod.CCTPAdapterBase");
    bytes32 constant SALT_LIQUID_ADAPTER = keccak256("TopupsMigration.Prod.EtherFiLiquidBridgeAdapterBase");
    bytes32 constant SALT_OFT_ADAPTER    = keccak256("TopupsMigration.Prod.EtherFiOFTBridgeAdapterBase");
    bytes32 constant SALT_STARGATE       = keccak256("TopupsMigration.Prod.StargateAdapterBase");

    function run() public {
        require(block.chainid == 8453, "Must run on Base (8453)");

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

        address liquid = deployCreate3(abi.encodePacked(type(EtherFiLiquidBridgeAdapter).creationCode), SALT_LIQUID_ADAPTER);
        console.log("EtherFiLiquidBridgeAdapter:", liquid);

        address oft = deployCreate3(abi.encodePacked(type(EtherFiOFTBridgeAdapter).creationCode), SALT_OFT_ADAPTER);
        console.log("EtherFiOFTBridgeAdapter:", oft);

        address sg = deployCreate3(abi.encodePacked(type(StargateAdapter).creationCode, abi.encode(BASE_WETH)), SALT_STARGATE);
        console.log("StargateAdapter:", sg);

        vm.stopBroadcast();

        // Load existing BaseWithdrawERC20BridgeAdapter, override the rest
        baseWithdrawERC20BridgeAdapter = _tryAddr(deployments, "BaseWithdrawERC20BridgeAdapter");
        require(baseWithdrawERC20BridgeAdapter != address(0), "BaseWithdrawERC20BridgeAdapter not in deployments");
        console.log("BaseWithdrawERC20BridgeAdapter (reused):", baseWithdrawERC20BridgeAdapter);

        cctpAdapter = cctp;
        etherFiLiquidBridgeAdapter = liquid;
        etherFiOFTBridgeAdapter = oft;
        stargateAdapter = sg;

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
        string memory path = string.concat("./output/UpgradeTopUpFactoryBase-", chainId, ".json");
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
