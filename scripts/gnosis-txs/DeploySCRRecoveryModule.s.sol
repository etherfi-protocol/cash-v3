// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { SCRRecoveryModule } from "../../src/modules/scr/SCRRecoveryModule.sol";
import { EtherFiHook } from "../../src/hook/EtherFiHook.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title DeploySCRRecoveryModule (mainnet / prod)
 * @notice Deploys the SCRRecoveryModule + a fresh EtherFiHook impl via CREATE3 with the
 *         deployer key, then generates a Gnosis Safe TX bundle for the cashControllerSafe
 *         to configure everything (the deployer EOA cannot perform the privileged config).
 *
 *         Bundle transactions (all executed by the Safe):
 *           1. EtherFiDataProvider.configureDefaultModules — register the module.
 *           2. EtherFiHook.upgradeToAndCall — upgrade the hook to the new impl.
 *           3. EtherFiHook.setScrRecoveryModule — wire the hook to bypass the health check.
 *           4. RoleRegistry.grantRole(SCR_RECOVERY_ADMIN_ROLE, safe) — config admin.
 *
 *         ETHER_FI_WALLET_ROLE (the `collect` caller) is a pre-existing global role on
 *         Scroll already held by the ether.fi backend wallets, so it is not re-granted here.
 *
 *         The script simulates the bundle on the live fork and asserts the resulting state,
 *         and verifies the RoleRegistry owner is unchanged (deploy-proxy rule #6).
 *
 * Usage:
 *   ENV=mainnet forge script scripts/gnosis-txs/DeploySCRRecoveryModule.s.sol:DeploySCRRecoveryModuleGnosis \
 *     --rpc-url $SCROLL_RPC --broadcast -vvvv
 */
contract DeploySCRRecoveryModuleGnosis is GnosisHelpers, Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant CASH_CONTROLLER_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    // Destination that receives all recovered SCR.
    address constant COLLECTION_WALLET = 0x86fBaEB3D6b5247F420590D303a6ffC9cd523790;

    // Deterministic salts (prod) so verification can confirm the impl/proxy addresses.
    bytes32 constant SALT_SCR_MODULE_IMPL  = keccak256("SCRRecoveryModule.Prod.Impl");
    bytes32 constant SALT_SCR_MODULE_PROXY = keccak256("SCRRecoveryModule.Prod.Proxy");
    bytes32 constant SALT_HOOK_IMPL        = keccak256("SCRRecoveryModule.Prod.HookImpl");

    function run() public {
        require(block.chainid == 534_352, "Must run on Scroll (534352)");

        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();

        address dataProvider = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        address hook = stdJson.readAddress(deployments, ".addresses.EtherFiHook");
        address roleRegistry = stdJson.readAddress(deployments, ".addresses.RoleRegistry");

        address expectedOwner = IRoleRegistry(roleRegistry).owner();

        // ════════════════════════════════════════════════════════════
        //  BROADCAST: deploy via CREATE3 with deployer key
        // ════════════════════════════════════════════════════════════
        vm.startBroadcast();

        address scrImpl = deployCreate3(
            abi.encodePacked(type(SCRRecoveryModule).creationCode, abi.encode(dataProvider)),
            SALT_SCR_MODULE_IMPL
        );

        // Proxy initialized in the same deploy (deploy-proxy rule #1)
        SCRRecoveryModule scrModule = SCRRecoveryModule(deployCreate3(
            abi.encodePacked(
                type(UUPSProxy).creationCode,
                abi.encode(scrImpl, abi.encodeWithSelector(SCRRecoveryModule.initialize.selector, roleRegistry, COLLECTION_WALLET))
            ),
            SALT_SCR_MODULE_PROXY
        ));

        address newHookImpl = deployCreate3(
            abi.encodePacked(type(EtherFiHook).creationCode, abi.encode(dataProvider)),
            SALT_HOOK_IMPL
        );

        vm.stopBroadcast();

        console.log("SCRRecoveryModule impl: ", scrImpl);
        console.log("SCRRecoveryModule proxy:", address(scrModule));
        console.log("New EtherFiHook impl:   ", newHookImpl);
        console.log("Collection wallet:      ", COLLECTION_WALLET);

        // ════════════════════════════════════════════════════════════
        //  GNOSIS: generate TX bundle for cashControllerSafe
        // ════════════════════════════════════════════════════════════
        string memory txs = _getGnosisHeader(chainId, addressToHex(CASH_CONTROLLER_SAFE));

        // 1. Register as default module
        {
            address[] memory modules = new address[](1);
            modules[0] = address(scrModule);
            bool[] memory shouldWhitelist = new bool[](1);
            shouldWhitelist[0] = true;

            txs = string(abi.encodePacked(txs, _getGnosisTransaction(
                addressToHex(dataProvider),
                iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, modules, shouldWhitelist)),
                "0", false
            )));
        }

        // 2. Upgrade hook
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(hook),
            iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, newHookImpl, "")),
            "0", false
        )));

        // 3. Wire hook -> recovery module (bypasses the post-op health check)
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(hook),
            iToHex(abi.encodeWithSelector(EtherFiHook.setScrRecoveryModule.selector, address(scrModule))),
            "0", false
        )));

        // 4. Grant config admin role to the Safe (last tx)
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(roleRegistry),
            iToHex(abi.encodeWithSelector(IRoleRegistry.grantRole.selector, scrModule.SCR_RECOVERY_ADMIN_ROLE(), CASH_CONTROLLER_SAFE)),
            "0", true
        )));

        vm.createDir("./output", true);
        string memory path = "./output/DeploySCRRecoveryModule.json";
        vm.writeFile(path, txs);
        console.log("Gnosis bundle:", path);

        // ════════════════════════════════════════════════════════════
        //  SIMULATE + VERIFY
        // ════════════════════════════════════════════════════════════
        executeGnosisTransactionBundle(path);

        require(EtherFiDataProvider(dataProvider).isDefaultModule(address(scrModule)), "module not default");
        require(EtherFiHook(hook).scrRecoveryModule() == address(scrModule), "hook not wired");
        require(scrModule.collectionWallet() == COLLECTION_WALLET, "collection wallet mismatch");
        require(IRoleRegistry(roleRegistry).hasRole(scrModule.SCR_RECOVERY_ADMIN_ROLE(), CASH_CONTROLLER_SAFE), "admin role not granted");

        // deploy-proxy rule #6: ownership must be unchanged after the bundle
        require(IRoleRegistry(roleRegistry).owner() == expectedOwner, "CRITICAL: RoleRegistry owner changed!");
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
