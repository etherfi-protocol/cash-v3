// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { IOFTConfigRegistry } from "../src/interfaces/IOFTConfigRegistry.sol";
import { OFTAdapterFactory } from "../src/oft/OFTAdapterFactory.sol";
import { OFTConfigRegistry } from "../src/oft/OFTConfigRegistry.sol";
import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";

import { Utils } from "./utils/Utils.sol";

/**
 * @title ConfigureAndListOFTMainnet
 * @author ether.fi
 * @notice EOA-driven bring-up of the mainnet OFT side: grants the OFT roles, sets the LayerZero
 *         pathway config for the Optimism destination, and lists the first asset (PEPE) by
 *         deploying its lock adapter. Reads the infra addresses from deployments.json.
 * @dev The deployer EOA must own the OFTRoleRegistry (deploy with OFT_OWNER_MAINNET unset so it
 *      falls back to the deployer). All steps are idempotent: role grants are no-ops if already
 *      held, and the adapter is only deployed if PEPE is not already listed. Run on mainnet:
 *
 *        PRIVATE_KEY=<deployer> forge script scripts/ConfigureAndListOFTMainnet.s.sol --rpc-url mainnet --broadcast
 */
contract ConfigureAndListOFTMainnet is Utils {
    // LayerZero pathway: Ethereum mainnet (EID 30101) -> Optimism (EID 30111).
    // Libraries/DVN from lz-address-book LayerZeroV2{,DVN}EthereumMainnet.
    uint32 constant DST_EID = 30_111;
    address constant SEND_LIB = 0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1; // SEND_ULN_302
    address constant RECEIVE_LIB = 0xc02Ab410f0734EFa3F14628780e6e695156024C2; // RECEIVE_ULN_302
    address constant DVN_LAYERZERO = 0x589dEDbD617e0CBcB916A9223F4d1300c294236b;
    uint64 constant CONFIRMATIONS = 15;

    // First listed asset: PEPE on Ethereum mainnet (18 decimals).
    address constant PEPE = 0x6982508145454Ce325dDbE47a25d4ec3d2311933;

    bytes32 constant CONFIG_REGISTRAR_ROLE = keccak256("OFT_CONFIG_REGISTRAR_ROLE");
    bytes32 constant CONFIG_ADMIN_ROLE = keccak256("OFT_CONFIG_ADMIN_ROLE");
    bytes32 constant OFT_ADAPTER_FACTORY_ADMIN_ROLE = keccak256("OFT_ADAPTER_FACTORY_ADMIN_ROLE");

    function run() public {
        require(block.chainid == 1, "run on Ethereum mainnet (chainId 1)");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        // OApp owner that can setPeer/options later. Defaults to the deployer for the EOA flow.
        address delegate = vm.envOr("OFT_DELEGATE", deployer);

        string memory deployments = readDeploymentFile();
        RoleRegistry roleRegistry = RoleRegistry(stdJson.readAddress(deployments, ".addresses.OFTRoleRegistry"));
        OFTConfigRegistry configRegistry = OFTConfigRegistry(stdJson.readAddress(deployments, ".addresses.OFTConfigRegistry"));
        OFTAdapterFactory factory = OFTAdapterFactory(stdJson.readAddress(deployments, ".addresses.OFTAdapterFactory"));

        require(roleRegistry.owner() == deployer, "deployer must own OFTRoleRegistry (deploy with OFT_OWNER_MAINNET unset for the EOA wiring path)");
        require(IERC20Metadata(PEPE).decimals() == 18, "unexpected PEPE decimals");

        // CREATE3 salt convention: keccak256(abi.encode("EtherFiOFT", underlyingToken)).
        bytes32 salt = keccak256(abi.encode("EtherFiOFT", PEPE));
        address existing = factory.adapterOf(PEPE);

        vm.startBroadcast(pk);
        // Factory needs CONFIG_REGISTRAR (to auto-register the bridge on deploy); the EOA needs
        // CONFIG_ADMIN (setPathwayConfig) and the factory-admin role (deployAdapter).
        roleRegistry.grantRole(CONFIG_REGISTRAR_ROLE, address(factory));
        roleRegistry.grantRole(CONFIG_ADMIN_ROLE, deployer);
        roleRegistry.grantRole(OFT_ADAPTER_FACTORY_ADMIN_ROLE, deployer);
        // Canonical LayerZero config for the OP pathway. Bridges pull this via syncConfig.
        configRegistry.setPathwayConfig(DST_EID, _pathwayConfig());
        // List PEPE. Factory auto-registers the bridge and pulls the config just set.
        address adapter = existing == address(0) ? factory.deployAdapter(salt, PEPE, delegate) : existing;
        vm.stopBroadcast();

        if (existing != address(0)) console.log("PEPE adapter already listed; skipped deployAdapter");
        console.log("Configured + listed PEPE on mainnet (chainId", block.chainid, ")");
        console.log("  delegate (OApp owner):", delegate);
        console.log("  PEPE adapter:         ", adapter);

        string memory path = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/deployments.json");
        vm.writeJson(vm.toString(adapter), path, ".addresses.OFTAdapter_PEPE");
    }

    /// @dev The canonical pathway config for DST_EID: 1-of-1 LayerZero DVN, no optional DVNs.
    function _pathwayConfig() internal pure returns (IOFTConfigRegistry.PathwayConfig memory cfg) {
        address[] memory requiredDVNs = new address[](1);
        requiredDVNs[0] = DVN_LAYERZERO;
        cfg = IOFTConfigRegistry.PathwayConfig({ sendLib: SEND_LIB, receiveLib: RECEIVE_LIB, confirmations: CONFIRMATIONS, optionalDVNThreshold: 0, requiredDVNs: requiredDVNs, optionalDVNs: new address[](0) });
    }
}
