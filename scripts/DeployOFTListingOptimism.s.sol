// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { UUPSProxy } from "../src/UUPSProxy.sol";
import { EtherFiShadowOFT } from "../src/oft/EtherFiShadowOFT.sol";
import { ShadowOFTFactory } from "../src/oft/ShadowOFTFactory.sol";
import { OFTConfigRegistry } from "../src/oft/OFTConfigRegistry.sol";
import { OracleSink } from "../src/oracle/OracleSink.sol";

import { Utils } from "./utils/Utils.sol";

/**
 * @title DeployOFTListingOptimism
 * @author ether.fi
 * @notice Single-shot Optimism-side infra deploy for the cross-chain listing primitive:
 *           - OFT factory stack: {OFTConfigRegistry}, the {EtherFiShadowOFT} beacon impl, {ShadowOFTFactory}
 *           - Oracle receiver: the {OracleSink} LayerZero receiver
 *         The OracleSink (an OApp) is deployed deterministically via CREATE3/Nick's factory and its
 *         peer is wired to the CREATE3-predicted {PriceRelay} address on Ethereum in the same run, so
 *         the two sides can be deployed in any order.
 * @dev Reuses the chain's existing cash {RoleRegistry} (read from deployments.json) rather than a
 *      dedicated one. The deployer EOA owns the OApp during bring-up so it can setPeer in one pass,
 *      then hands ownership + the LZ delegate to OFT_OWNER_OPTIMISM (the protocol Safe) if set; on dev
 *      OFT_OWNER_OPTIMISM is left unset so the EOA keeps ownership.
 *
 *      Per-asset listing, pathway config and rate limits are NOT done here — run the per-asset
 *      scripts (ConfigureAndListOFTOptimism / SetOFTRateLimits) afterwards. Oracle role grants
 *      (ORACLE_SINK_ADMIN_ROLE) and per-token staleness windows are set by the RoleRegistry owner
 *      after deploy.
 *
 *      Run on Optimism:
 *        ENV=<dev|mainnet> [OFT_OWNER_OPTIMISM=<safe>] PRIVATE_KEY=<deployer> \
 *          forge script scripts/DeployOFTListingOptimism.s.sol --rpc-url $OPTIMISM_RPC --broadcast --verify
 */
contract DeployOFTListingOptimism is Utils {
    /// @dev LayerZero V2 endpoint on Optimism (EID 30111).
    address constant LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    /// @dev Keyless CREATE2 (Nick's) factory; the CREATE3 deployer namespace shared across chains.
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev LayerZero endpoint IDs.
    uint32 constant ETH_EID = 30_101;
    uint32 constant OP_EID = 30_111;

    // Deployed addresses (state vars to keep run() under the stack limit).
    address internal roleRegistry;
    address internal configRegistry;
    address internal configRegistryImpl;
    address internal shadowImpl;
    address internal shadowFactory;
    address internal shadowFactoryImpl;
    address internal oracleSink;
    address internal oracleSinkImpl;

    function run() public {
        require(block.chainid == 10, "run on Optimism (chainId 10)");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        // OApp owner / LZ delegate after bring-up. Defaults to the deployer (dev) when unset.
        address owner = vm.envOr("OFT_OWNER_OPTIMISM", deployer);

        roleRegistry = stdJson.readAddress(readDeploymentFile(), ".addresses.RoleRegistry");
        require(roleRegistry != address(0), "RoleRegistry not found in deployments.json");

        // OracleSink (here) and PriceRelay (Ethereum) addresses are CREATE3-deterministic; predict the
        // counterpart so we can wire the peer without knowing the Ethereum run's result.
        address predictedPriceRelay = CREATE3.predictDeterministicAddress(_salt("PriceRelay"), NICKS_FACTORY);

        // One-shot deploy guard: the CREATE3 OApp can only be deployed once per (salt, ENV), but the
        // non-CREATE3 infra (config registry, factory) would redeploy fresh on a re-run and overwrite
        // deployments.json while OracleSink keeps its original wiring. Abort up front so we never
        // produce that split state. To redeploy, bump ENV/salt or upgrade in place.
        require(
            CREATE3.predictDeterministicAddress(_salt("OracleSink"), NICKS_FACTORY).code.length == 0,
            "OracleSink already deployed for this ENV; this is a one-shot deploy (bump ENV/salt or upgrade in place)"
        );

        vm.startBroadcast(pk);
        _deployFactoryStack();
        _deployOracleReceiver(deployer, owner, predictedPriceRelay);
        vm.stopBroadcast();

        require(
            oracleSink == CREATE3.predictDeterministicAddress(_salt("OracleSink"), NICKS_FACTORY),
            "OracleSink CREATE3 address mismatch"
        );

        _logAndPersist(owner, predictedPriceRelay);
    }

    function _deployFactoryStack() internal {
        // Canonical LayerZero DVN/library config registry; bridges pull from it via syncConfig.
        configRegistryImpl = address(new OFTConfigRegistry());
        configRegistry = address(
            new UUPSProxy(configRegistryImpl, abi.encodeCall(OFTConfigRegistry.initialize, (roleRegistry)))
        );

        // Single beacon implementation reused by every per-asset iTOKEN proxy.
        shadowImpl = address(new EtherFiShadowOFT(LZ_ENDPOINT, configRegistry));

        // Factory. initialize() creates the shared UpgradeableBeacon internally.
        shadowFactoryImpl = address(new ShadowOFTFactory());
        shadowFactory = address(
            new UUPSProxy(shadowFactoryImpl, abi.encodeCall(ShadowOFTFactory.initialize, (roleRegistry, shadowImpl)))
        );
    }

    function _deployOracleReceiver(address deployer, address owner, address predictedPriceRelay) internal {
        // OracleSink (OApp). Deployed via CREATE3 for a cross-chain-predictable address; owner/delegate
        // start as the EOA so we can setPeer in this same broadcast.
        oracleSinkImpl = address(new OracleSink(LZ_ENDPOINT));
        bytes memory initData = abi.encodeCall(OracleSink.initialize, (roleRegistry, deployer));
        oracleSink = deployCreate3(
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(oracleSinkImpl, initData)), _salt("OracleSink")
        );

        // Wire the OApp peer to the predicted PriceRelay on Ethereum.
        OracleSink(oracleSink).setPeer(ETH_EID, _toBytes32(predictedPriceRelay));

        // Hand off OApp ownership + LZ delegate to the Safe (skipped on dev where owner == deployer).
        if (owner != deployer) {
            OracleSink(oracleSink).setDelegate(owner);
            OracleSink(oracleSink).transferOwnership(owner);
        }
    }

    function _logAndPersist(address owner, address predictedPriceRelay) internal {
        console.log("OFT listing (Optimism) deployed on chainId", block.chainid);
        console.log("  RoleRegistry (reused): ", roleRegistry);
        console.log("  OApp owner / delegate: ", owner);
        console.log("  OFTConfigRegistry:     ", configRegistry);
        console.log("  EtherFiShadowOFTImpl:  ", shadowImpl);
        console.log("  ShadowOFTFactory:      ", shadowFactory);
        console.log("  Beacon:                ", ShadowOFTFactory(shadowFactory).beacon());
        console.log("  OracleSink:            ", oracleSink);
        console.log("  peer -> PriceRelay(ETH):", predictedPriceRelay);

        string memory path =
            string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/deployments.json");
        vm.writeJson(vm.toString(configRegistry), path, ".addresses.OFTConfigRegistry");
        vm.writeJson(vm.toString(configRegistryImpl), path, ".addresses.OFTConfigRegistryImpl");
        vm.writeJson(vm.toString(shadowImpl), path, ".addresses.EtherFiShadowOFTImpl");
        vm.writeJson(vm.toString(shadowFactory), path, ".addresses.ShadowOFTFactory");
        vm.writeJson(vm.toString(shadowFactoryImpl), path, ".addresses.ShadowOFTFactoryImpl");
        vm.writeJson(vm.toString(oracleSink), path, ".addresses.OracleSink");
        vm.writeJson(vm.toString(oracleSinkImpl), path, ".addresses.OracleSinkImpl");
    }

    /// @dev Env-scoped CREATE3 salt so dev and mainnet get distinct deterministic addresses on the
    ///      same physical chain. Must match the Ethereum script for cross-side peer prediction.
    function _salt(string memory name) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("etherfi.oft-listing.", name, ".", getEnv()));
    }

    function _toBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// @dev CREATE3 deploy via Nick's factory (repo convention): address depends only on (NICKS_FACTORY, salt).
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
