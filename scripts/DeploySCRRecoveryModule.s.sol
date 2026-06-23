// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { UUPSProxy } from "../src/UUPSProxy.sol";
import { SCRRecoveryModule } from "../src/modules/scr/SCRRecoveryModule.sol";
import { EtherFiHook } from "../src/hook/EtherFiHook.sol";
import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { IRoleRegistry } from "../src/interfaces/IRoleRegistry.sol";
import { Utils } from "./utils/Utils.sol";

/**
 * @title DeploySCRRecoveryModule (dev)
 * @notice Deploys and fully configures the SCRRecoveryModule on Scroll for the dev
 *         environment using the deployer key (the dev deployer owns the protocol and
 *         can perform every step directly — no Gnosis bundle required).
 *
 *         Steps:
 *           1. Deploy SCRRecoveryModule impl + proxy (proxy initialized in the same tx).
 *           2. Register the module as a default module on EtherFiDataProvider.
 *           3. Deploy a fresh EtherFiHook impl and upgrade the hook proxy to it.
 *           4. Point the hook at the recovery module so `collect` bypasses the
 *              post-op health check.
 *           5. Grant SCR_RECOVERY_ADMIN_ROLE (config) and ETHER_FI_WALLET_ROLE
 *              (the `collect` caller) to the deployer for end-to-end dev testing.
 *
 * Usage:
 *   ENV=dev PRIVATE_KEY=$DEV_KEY \
 *   forge script scripts/DeploySCRRecoveryModule.s.sol:DeploySCRRecoveryModule \
 *     --rpc-url $SCROLL_RPC --broadcast -vvvv
 */
contract DeploySCRRecoveryModule is Utils {
    // ─────────────────────────────────────────────────────────────
    // Destination that receives all recovered SCR.
    // TODO: confirm the dev collection wallet. Defaults to the deployer EOA so the
    //       dev flow is self-contained; override before broadcasting if needed.
    // ─────────────────────────────────────────────────────────────
    address constant COLLECTION_WALLET = address(0);

    function run() public {
        require(block.chainid == 534_352, "Must run on Scroll (534352)");

        string memory deployments = readDeploymentFile();
        address dataProvider = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        address hook = stdJson.readAddress(deployments, ".addresses.EtherFiHook");
        address roleRegistry = stdJson.readAddress(deployments, ".addresses.RoleRegistry");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address collectionWallet = COLLECTION_WALLET == address(0) ? deployer : COLLECTION_WALLET;

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy module impl + proxy (initialize in the same tx — see deploy-proxy rule #1)
        address impl = address(new SCRRecoveryModule(dataProvider));
        SCRRecoveryModule scrModule = SCRRecoveryModule(
            address(
                new UUPSProxy(
                    impl,
                    abi.encodeWithSelector(SCRRecoveryModule.initialize.selector, roleRegistry, collectionWallet)
                )
            )
        );

        // 2. Register as a default module so it is enabled on every safe
        address[] memory modules = new address[](1);
        modules[0] = address(scrModule);
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;
        EtherFiDataProvider(dataProvider).configureDefaultModules(modules, shouldWhitelist);

        // 3. Deploy + upgrade the hook so it knows about the recovery module
        address newHookImpl = address(new EtherFiHook(dataProvider));
        UUPSUpgradeable(hook).upgradeToAndCall(newHookImpl, "");

        // 4. Point the hook at the recovery module (bypasses the health check)
        EtherFiHook(hook).setScrRecoveryModule(address(scrModule));

        // 5. Grant roles for config + collection (dev convenience: deployer can do both)
        IRoleRegistry(roleRegistry).grantRole(scrModule.SCR_RECOVERY_ADMIN_ROLE(), deployer);
        IRoleRegistry(roleRegistry).grantRole(scrModule.ETHER_FI_WALLET_ROLE(), deployer);

        vm.stopBroadcast();

        console.log("SCRRecoveryModule impl: ", impl);
        console.log("SCRRecoveryModule proxy:", address(scrModule));
        console.log("New EtherFiHook impl:   ", newHookImpl);
        console.log("Collection wallet:      ", collectionWallet);

        // Post-deployment sanity
        require(EtherFiDataProvider(dataProvider).isDefaultModule(address(scrModule)), "module not default");
        require(EtherFiHook(hook).scrRecoveryModule() == address(scrModule), "hook not wired");
        require(scrModule.collectionWallet() == collectionWallet, "collection wallet mismatch");
    }
}
