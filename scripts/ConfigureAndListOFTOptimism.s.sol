// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { IOFTConfigRegistry } from "../src/interfaces/IOFTConfigRegistry.sol";
import { OFTConfigRegistry } from "../src/oft/OFTConfigRegistry.sol";
import { ShadowOFTFactory } from "../src/oft/ShadowOFTFactory.sol";
import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";

import { Utils } from "./utils/Utils.sol";

/**
 * @title ConfigureAndListOFTOptimism
 * @author ether.fi
 * @notice EOA-driven bring-up of the Optimism OFT side: grants the OFT roles, sets the LayerZero
 *         pathway config for the Ethereum destination, and lists the first asset by deploying its
 *         mintable iTOKEN (iPEPE). Reads the infra addresses from deployments.json.
 * @dev The deployer EOA must own the OFTRoleRegistry (deploy with OFT_OWNER_OPTIMISM unset so it
 *      falls back to the deployer). All steps are idempotent: role grants are no-ops if already
 *      held, and the iTOKEN is only deployed if its deterministic address is not already used.
 *      Run on Optimism:
 *
 *        PRIVATE_KEY=<deployer> forge script scripts/ConfigureAndListOFTOptimism.s.sol --rpc-url optimism --broadcast
 */
contract ConfigureAndListOFTOptimism is Utils {
    // LayerZero pathway: Optimism (EID 30111) -> Ethereum mainnet (EID 30101).
    // Libraries/DVN from lz-address-book LayerZeroV2{,DVN}OptimismMainnet.
    uint32 constant DST_EID = 30101;
    address constant SEND_LIB = 0x1322871e4ab09Bc7f5717189434f97bBD9546e95; // SEND_ULN_302
    address constant RECEIVE_LIB = 0x3c4962Ff6258dcfCafD23a814237B7d6Eb712063; // RECEIVE_ULN_302
    address constant DVN_LAYERZERO = 0x6A02D83e8d433304bba74EF1c427913958187142;
    uint64 constant CONFIRMATIONS = 20;

    // First listed asset mirrors mainnet PEPE (18 decimals). The mainnet token address is only
    // used to derive the same CREATE3 salt as the mainnet adapter (cross-chain address match is a
    // non-goal; this just keeps the salt convention consistent).
    address constant PEPE_MAINNET = 0x6982508145454Ce325dDbE47a25d4ec3d2311933;
    string constant SHADOW_NAME = "EtherFi Pepe";
    string constant SHADOW_SYMBOL = "iPEPE";
    uint8 constant SHADOW_DECIMALS = 18;

    bytes32 constant CONFIG_REGISTRAR_ROLE = keccak256("OFT_CONFIG_REGISTRAR_ROLE");
    bytes32 constant CONFIG_ADMIN_ROLE = keccak256("OFT_CONFIG_ADMIN_ROLE");
    bytes32 constant SHADOW_OFT_FACTORY_ADMIN_ROLE = keccak256("SHADOW_OFT_FACTORY_ADMIN_ROLE");

    function run() public {
        require(block.chainid == 10, "run on Optimism (chainId 10)");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        // OApp owner that can setPeer/options later. Defaults to the deployer for the EOA flow.
        address delegate = vm.envOr("OFT_DELEGATE", deployer);

        string memory deployments = readDeploymentFile();
        RoleRegistry roleRegistry = RoleRegistry(stdJson.readAddress(deployments, ".addresses.OFTRoleRegistry"));
        OFTConfigRegistry configRegistry = OFTConfigRegistry(stdJson.readAddress(deployments, ".addresses.OFTConfigRegistry"));
        ShadowOFTFactory factory = ShadowOFTFactory(stdJson.readAddress(deployments, ".addresses.ShadowOFTFactory"));

        require(
            roleRegistry.owner() == deployer,
            "deployer must own OFTRoleRegistry (deploy with OFT_OWNER_OPTIMISM unset for the EOA wiring path)"
        );

        // CREATE3 salt convention: keccak256(abi.encode("EtherFiOFT", underlyingToken)).
        bytes32 salt = keccak256(abi.encode("EtherFiOFT", PEPE_MAINNET));
        bool alreadyListed = factory.isShadowOFT(factory.getDeterministicAddress(salt));

        vm.startBroadcast(pk);
        // Factory needs CONFIG_REGISTRAR (to auto-register the bridge on deploy); the EOA needs
        // CONFIG_ADMIN (setPathwayConfig) and the factory-admin role (deployShadowOFT).
        roleRegistry.grantRole(CONFIG_REGISTRAR_ROLE, address(factory));
        roleRegistry.grantRole(CONFIG_ADMIN_ROLE, deployer);
        roleRegistry.grantRole(SHADOW_OFT_FACTORY_ADMIN_ROLE, deployer);
        // Canonical LayerZero config for the ETH pathway. Bridges pull this via syncConfig.
        configRegistry.setPathwayConfig(DST_EID, _pathwayConfig());
        // List iPEPE. Factory auto-registers the bridge and pulls the config just set.
        address shadow = _listShadow(factory, salt, delegate, alreadyListed);
        vm.stopBroadcast();

        if (alreadyListed) console.log("iPEPE already listed; skipped deployShadowOFT");
        console.log("Configured + listed iPEPE on Optimism (chainId", block.chainid, ")");
        console.log("  delegate (OApp owner):", delegate);
        console.log("  iPEPE shadow OFT:     ", shadow);

        string memory path =
            string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/deployments.json");
        vm.writeJson(vm.toString(shadow), path, ".addresses.ShadowOFT_iPEPE");
    }

    /// @dev Deploys the iTOKEN, or returns the existing deterministic address if already listed.
    function _listShadow(ShadowOFTFactory factory, bytes32 salt, address delegate, bool alreadyListed)
        internal
        returns (address)
    {
        if (alreadyListed) return factory.getDeterministicAddress(salt);
        return factory.deployShadowOFT(salt, SHADOW_NAME, SHADOW_SYMBOL, SHADOW_DECIMALS, delegate);
    }

    /// @dev The canonical pathway config for DST_EID: 1-of-1 LayerZero DVN, no optional DVNs.
    function _pathwayConfig() internal pure returns (IOFTConfigRegistry.PathwayConfig memory cfg) {
        address[] memory requiredDVNs = new address[](1);
        requiredDVNs[0] = DVN_LAYERZERO;
        cfg = IOFTConfigRegistry.PathwayConfig({
            sendLib: SEND_LIB,
            receiveLib: RECEIVE_LIB,
            confirmations: CONFIRMATIONS,
            optionalDVNThreshold: 0,
            requiredDVNs: requiredDVNs,
            optionalDVNs: new address[](0)
        });
    }
}
