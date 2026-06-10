// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { UUPSProxy } from "../src/UUPSProxy.sol";
import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";
import { OFTConfigRegistry } from "../src/oft/OFTConfigRegistry.sol";
import { EtherFiShadowOFT } from "../src/oft/EtherFiShadowOFT.sol";
import { ShadowOFTFactory } from "../src/oft/ShadowOFTFactory.sol";

import { Utils } from "./utils/Utils.sol";

/**
 * @title DeployOFTShadowSide
 * @author ether.fi
 * @notice Deploys the Optimism (mint/burn iTOKEN) side of the OFT listing primitive with an EOA:
 *         a dedicated {RoleRegistry}, the {OFTConfigRegistry}, the {EtherFiShadowOFT} beacon
 *         implementation, and the {ShadowOFTFactory}. Per-asset iTOKENs are listed afterwards
 *         via {ShadowOFTFactory-deployShadowOFT}; that and all other privileged wiring (role
 *         grants, setPathwayConfig, setPeer) is performed by the RoleRegistry owner, not the EOA.
 * @dev The deployer EOA only deploys. Ownership of the RoleRegistry is set to OFT_REGISTRY_OWNER
 *      (the protocol Safe) so no privileged power is retained by an EOA. Run on Optimism:
 *
 *      Set OFT_OWNER_OPTIMISM (and PRIVATE_KEY / OPTIMISM_RPC) in .env, then:
 *          forge script scripts/DeployOFTShadowSide.s.sol --rpc-url optimism --broadcast --verify
 */
contract DeployOFTShadowSide is Utils {
    /// @dev LayerZero V2 endpoint on Optimism (EID 30111).
    ///      Source: lz-address-book `LayerZeroV2OptimismMainnet.ENDPOINT_V2`.
    address constant LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;

    function run() public {
        require(block.chainid == 10, "run on Optimism (chainId 10)");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        // RoleRegistry owner = the protocol Safe on this chain (recommended). Falls back to the
        // deployer only if OFT_OWNER_OPTIMISM is unset (a transient bring-up; hand off to the
        // Safe after). Per-chain var name so the mainnet and Optimism owners can coexist in .env.
        address owner = vm.envOr("OFT_OWNER_OPTIMISM", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Dedicated RoleRegistry for the OFT subsystem. The data provider is only used by
        //    configureSafeAdmins, which the OFT system never calls, so it is left as address(0).
        address roleRegistryImpl = address(new RoleRegistry(address(0)));
        RoleRegistry roleRegistry =
            RoleRegistry(address(new UUPSProxy(roleRegistryImpl, abi.encodeCall(RoleRegistry.initialize, (owner)))));

        // 2. Canonical LayerZero DVN/library config registry; bridges pull from it via syncConfig.
        address configRegistryImpl = address(new OFTConfigRegistry());
        OFTConfigRegistry configRegistry = OFTConfigRegistry(
            address(new UUPSProxy(configRegistryImpl, abi.encodeCall(OFTConfigRegistry.initialize, (address(roleRegistry)))))
        );

        // 3. Single beacon implementation reused by every per-asset iTOKEN proxy.
        address shadowImpl = address(new EtherFiShadowOFT(LZ_ENDPOINT, address(configRegistry)));

        // 4. Factory. initialize() creates the shared UpgradeableBeacon internally.
        address shadowFactoryImpl = address(new ShadowOFTFactory());
        ShadowOFTFactory shadowFactory = ShadowOFTFactory(
            address(
                new UUPSProxy(
                    shadowFactoryImpl, abi.encodeCall(ShadowOFTFactory.initialize, (address(roleRegistry), shadowImpl))
                )
            )
        );

        vm.stopBroadcast();

        console.log("OFT Optimism (shadow) side deployed on chainId", block.chainid);
        console.log("  RoleRegistry owner:    ", owner);
        console.log("  OFTRoleRegistry:       ", address(roleRegistry));
        console.log("  OFTRoleRegistryImpl:   ", roleRegistryImpl);
        console.log("  OFTConfigRegistry:     ", address(configRegistry));
        console.log("  OFTConfigRegistryImpl: ", configRegistryImpl);
        console.log("  EtherFiShadowOFTImpl:  ", shadowImpl);
        console.log("  ShadowOFTFactory:      ", address(shadowFactory));
        console.log("  ShadowOFTFactoryImpl:  ", shadowFactoryImpl);
        console.log("  Beacon:                ", shadowFactory.beacon());

        // Persist into the existing per-chain deployments.json, preserving all existing keys.
        string memory path =
            string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/deployments.json");
        vm.writeJson(vm.toString(address(roleRegistry)), path, ".addresses.OFTRoleRegistry");
        vm.writeJson(vm.toString(roleRegistryImpl), path, ".addresses.OFTRoleRegistryImpl");
        vm.writeJson(vm.toString(address(configRegistry)), path, ".addresses.OFTConfigRegistry");
        vm.writeJson(vm.toString(configRegistryImpl), path, ".addresses.OFTConfigRegistryImpl");
        vm.writeJson(vm.toString(shadowImpl), path, ".addresses.EtherFiShadowOFTImpl");
        vm.writeJson(vm.toString(address(shadowFactory)), path, ".addresses.ShadowOFTFactory");
        vm.writeJson(vm.toString(shadowFactoryImpl), path, ".addresses.ShadowOFTFactoryImpl");
    }
}
