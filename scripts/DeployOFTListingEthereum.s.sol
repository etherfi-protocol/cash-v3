// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { UUPSProxy } from "../src/UUPSProxy.sol";
import { EtherFiOFTAdapter } from "../src/oft/EtherFiOFTAdapter.sol";
import { OFTAdapterFactory } from "../src/oft/OFTAdapterFactory.sol";
import { OFTConfigRegistry } from "../src/oft/OFTConfigRegistry.sol";
import { PriceProvider } from "../src/oracle/PriceProvider.sol";
import { PriceRelay } from "../src/oracle/PriceRelay.sol";

import { Utils } from "./utils/Utils.sol";

/**
 * @title DeployOFTListingEthereum
 * @author ether.fi
 * @notice Single-shot Ethereum-side infra deploy for the cross-chain listing primitive:
 *           - OFT factory stack: {OFTConfigRegistry}, the {EtherFiOFTAdapter} beacon impl, {OFTAdapterFactory}
 *           - Oracle sender: a dedicated {PriceProvider} source + the {PriceRelay} LayerZero sender
 *         The PriceRelay (an OApp) is deployed deterministically via CREATE3/Nick's factory and its
 *         peer is wired to the CREATE3-predicted {OracleSink} address on Optimism in the same run, so
 *         the two sides can be deployed in any order.
 * @dev Reuses the chain's existing cash {RoleRegistry} (read from deployments.json) rather than a
 *      dedicated one. The deployer EOA owns the OApp during bring-up so it can setPeer in one pass,
 *      then hands ownership + the LZ delegate to OFT_OWNER_MAINNET (the protocol Safe) if set; on dev
 *      OFT_OWNER_MAINNET is left unset so the EOA keeps ownership.
 *
 *      Per-asset listing, pathway config and rate limits are NOT done here — run the per-asset
 *      scripts (ConfigureAndListOFTMainnet / SetOFTRateLimits) afterwards. Oracle role grants
 *      (PRICE_RELAY_ADMIN_ROLE, PRICE_PROVIDER_ADMIN_ROLE) and token subscriptions are performed by
 *      the RoleRegistry owner after deploy.
 *
 *      Run on Ethereum mainnet:
 *        ENV=<dev|mainnet> [OFT_OWNER_MAINNET=<safe>] PRIVATE_KEY=<deployer> \
 *          forge script scripts/DeployOFTListingEthereum.s.sol --rpc-url $MAINNET_RPC --broadcast --verify
 */
contract DeployOFTListingEthereum is Utils {
    /// @dev LayerZero V2 endpoint on Ethereum mainnet (EID 30101).
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
    address internal adapterImpl;
    address internal adapterFactory;
    address internal adapterFactoryImpl;
    address internal priceProvider;
    address internal priceProviderImpl;
    address internal priceRelay;
    address internal priceRelayImpl;

    function run() public {
        require(block.chainid == 1, "run on Ethereum mainnet (chainId 1)");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        // OApp owner / LZ delegate after bring-up. Defaults to the deployer (dev) when unset.
        address owner = vm.envOr("OFT_OWNER_MAINNET", deployer);

        roleRegistry = stdJson.readAddress(readDeploymentFile(), ".addresses.RoleRegistry");
        require(roleRegistry != address(0), "RoleRegistry not found in deployments.json");

        // PriceRelay (here) and OracleSink (Optimism) addresses are CREATE3-deterministic; predict the
        // counterpart so we can wire the peer without knowing the OP run's result.
        address predictedOracleSink = CREATE3.predictDeterministicAddress(_salt("OracleSink"), NICKS_FACTORY);

        // One-shot deploy guard: the CREATE3 OApp can only be deployed once per (salt, ENV), but the
        // non-CREATE3 infra (config registry, factory, RelayPriceProvider) would redeploy fresh on a
        // re-run and overwrite deployments.json while PriceRelay keeps its original wiring. Abort up
        // front so we never produce that split state. To redeploy, bump ENV/salt or upgrade in place.
        require(
            CREATE3.predictDeterministicAddress(_salt("PriceRelay"), NICKS_FACTORY).code.length == 0,
            "PriceRelay already deployed for this ENV; this is a one-shot deploy (bump ENV/salt or upgrade in place)"
        );

        vm.startBroadcast(pk);
        _deployFactoryStack();
        _deployOracleSender(deployer, owner, predictedOracleSink);
        vm.stopBroadcast();

        require(
            priceRelay == CREATE3.predictDeterministicAddress(_salt("PriceRelay"), NICKS_FACTORY),
            "PriceRelay CREATE3 address mismatch"
        );

        _logAndPersist(owner, predictedOracleSink);
    }

    function _deployFactoryStack() internal {
        // Canonical LayerZero DVN/library config registry; bridges pull from it via syncConfig.
        configRegistryImpl = address(new OFTConfigRegistry());
        configRegistry = address(
            new UUPSProxy(configRegistryImpl, abi.encodeCall(OFTConfigRegistry.initialize, (roleRegistry)))
        );

        // Single beacon implementation reused by every per-asset adapter proxy.
        adapterImpl = address(new EtherFiOFTAdapter(LZ_ENDPOINT, configRegistry));

        // Factory. initialize() creates the shared UpgradeableBeacon internally.
        adapterFactoryImpl = address(new OFTAdapterFactory());
        adapterFactory = address(
            new UUPSProxy(adapterFactoryImpl, abi.encodeCall(OFTAdapterFactory.initialize, (roleRegistry, adapterImpl)))
        );
    }

    function _deployOracleSender(address deployer, address owner, address predictedOracleSink) internal {
        // Dedicated price source for the relay; tokens are configured post-deploy by the registry owner.
        priceProviderImpl = address(new PriceProvider());
        priceProvider = address(
            new UUPSProxy(
                priceProviderImpl,
                abi.encodeCall(PriceProvider.initialize, (roleRegistry, new address[](0), new PriceProvider.Config[](0)))
            )
        );

        // PriceRelay (OApp). Deployed via CREATE3 for a cross-chain-predictable address; owner/delegate
        // start as the EOA so we can setPeer in this same broadcast.
        priceRelayImpl = address(new PriceRelay(LZ_ENDPOINT));
        bytes memory initData =
            abi.encodeCall(PriceRelay.initialize, (roleRegistry, priceProvider, deployer, OP_EID));
        priceRelay = deployCreate3(
            abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(priceRelayImpl, initData)), _salt("PriceRelay")
        );

        // Wire the OApp peer to the predicted OracleSink on Optimism.
        PriceRelay(priceRelay).setPeer(OP_EID, _toBytes32(predictedOracleSink));

        // Hand off OApp ownership + LZ delegate to the Safe (skipped on dev where owner == deployer).
        if (owner != deployer) {
            PriceRelay(priceRelay).setDelegate(owner);
            PriceRelay(priceRelay).transferOwnership(owner);
        }
    }

    function _logAndPersist(address owner, address predictedOracleSink) internal {
        console.log("OFT listing (Ethereum) deployed on chainId", block.chainid);
        console.log("  RoleRegistry (reused): ", roleRegistry);
        console.log("  OApp owner / delegate: ", owner);
        console.log("  OFTConfigRegistry:     ", configRegistry);
        console.log("  EtherFiOFTAdapterImpl: ", adapterImpl);
        console.log("  OFTAdapterFactory:     ", adapterFactory);
        console.log("  Beacon:                ", OFTAdapterFactory(adapterFactory).beacon());
        console.log("  RelayPriceProvider:    ", priceProvider);
        console.log("  PriceRelay:            ", priceRelay);
        console.log("  peer -> OracleSink(OP):", predictedOracleSink);

        string memory path =
            string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/deployments.json");
        vm.writeJson(vm.toString(configRegistry), path, ".addresses.OFTConfigRegistry");
        vm.writeJson(vm.toString(configRegistryImpl), path, ".addresses.OFTConfigRegistryImpl");
        vm.writeJson(vm.toString(adapterImpl), path, ".addresses.EtherFiOFTAdapterImpl");
        vm.writeJson(vm.toString(adapterFactory), path, ".addresses.OFTAdapterFactory");
        vm.writeJson(vm.toString(adapterFactoryImpl), path, ".addresses.OFTAdapterFactoryImpl");
        vm.writeJson(vm.toString(priceProvider), path, ".addresses.RelayPriceProvider");
        vm.writeJson(vm.toString(priceProviderImpl), path, ".addresses.RelayPriceProviderImpl");
        vm.writeJson(vm.toString(priceRelay), path, ".addresses.PriceRelay");
        vm.writeJson(vm.toString(priceRelayImpl), path, ".addresses.PriceRelayImpl");
    }

    /// @dev Env-scoped CREATE3 salt so dev and mainnet get distinct deterministic addresses on the
    ///      same physical chain. Must match the Optimism script for cross-side peer prediction.
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
