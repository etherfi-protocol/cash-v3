// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { Utils } from "../utils/Utils.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { AcrossSwapModule } from "../../src/across/AcrossSwapModule.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { EtherFiSafe } from "../../src/safe/EtherFiSafe.sol";
import { EtherFiSafeFactory } from "../../src/safe/EtherFiSafeFactory.sol";
import { OwnershipBridgeSender } from "../../src/ownership-bridge/OwnershipBridgeSender.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";

/**
 * @title DeployTradingAccountOptimism
 * @notice Dev/testnet deploy of the source-chain (OP) trading-account pieces against the
 *         EXISTING OP dev stack (read from deployments.json): OwnershipBridgeSender,
 *         AcrossSwapModule (Buy direction), the bridge-wired EtherFiSafe impl upgrade,
 *         module whitelisting, roles, and Across config.
 *
 *         Run the mainnet script first; pass its OwnershipBridgeReceiver address via
 *         MAINNET_BRIDGE_RECEIVER so the sender's LZ peer + destination are configured in
 *         the same broadcast. (The mainnet receiver's peer back to this sender is set by
 *         `WireOwnershipBridge.s.sol`.)
 *
 * Run:
 *   source .env && ENV=dev forge script scripts/trading-account/DeployTradingAccountOptimism.s.sol --rpc-url optimism --broadcast -vvv --verify
 */
contract DeployTradingAccountOptimism is Utils {
    // Our cross-chain CREATE3 deployer — same address on every chain.
    EtherFiDeployer constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);

    // LayerZero v2 endpoint — same address on Ethereum and Optimism.
    address constant LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    // LZ EID of the destination chain (Ethereum) owner-sync publishes to.
    uint32 constant MAINNET_EID = 30101;

    // Across V3 on Optimism.
    address constant SPOKE_POOL = 0x6f26Bf09B1C792e3228e5467807a900A503c0281;
    address constant MULTICALL_HANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address keeper = deployer;
        address mainnetReceiver = 0x13A84ae8bb2b56728B19c86b573c95B4b5Db6f5c;

        string memory deployments = readDeploymentFile();
        EtherFiDataProvider dataProvider = EtherFiDataProvider(
            stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider")
        );
        RoleRegistry roleRegistry = RoleRegistry(
            stdJson.readAddress(deployments, ".addresses.RoleRegistry")
        );
        ICashModule cashModule = ICashModule(
            stdJson.readAddress(deployments, ".addresses.CashModule")
        );
        EtherFiSafeFactory safeFactory = EtherFiSafeFactory(
            stdJson.readAddress(deployments, ".addresses.EtherFiSafeFactory")
        );

        require(DEPLOYER.isDeployer(deployer), "broadcaster not registered on EtherFiDeployer");

        vm.startBroadcast(pk);

        // 1. OwnershipBridgeSender — publishes owner mutations to the mainnet receiver.
        //    Delegate/owner is passed explicitly (CREATE3 means msg.sender during
        //    construction is the deployer's proxy, never the EOA).
        OwnershipBridgeSender sender = OwnershipBridgeSender(_deploy(
            "OwnershipBridgeSenderDev",
            type(OwnershipBridgeSender).creationCode,
            abi.encode(address(dataProvider), LZ_ENDPOINT, deployer)
        ));
        sender.configureDestination(MAINNET_EID, "", true);
        sender.setPeer(MAINNET_EID, bytes32(uint256(uint160(mainnetReceiver))));

        // 2. AcrossSwapModule — Buy direction, behind a UUPS proxy initialised atomically
        //    in its deployment tx (full Across config in the initialize calldata). The
        //    impl constructor reads getCashModule() from the initialised OP data
        //    provider, so the CashModule hold path is live here. Same proxy salt as the
        //    mainnet deploy ⇒ same address on both chains.
        //    topUpFactory: executeSell is unused on OP (selling happens on the trading
        //    chain). initialize requires non-zero, so we pass a CODE-LESS sentinel — any
        //    executeSell attempt reverts at the isTokenSupported staticcall, keeping the
        //    sell path disabled on this chain.
        address acrossImpl = _deploy(
            "AcrossSwapModuleImplV2Dev", type(AcrossSwapModule).creationCode, abi.encode(address(dataProvider))
        );
        AcrossSwapModule acrossModule = AcrossSwapModule(_deploy(
            "AcrossSwapModuleV2Dev",
            type(UUPSProxy).creationCode,
            abi.encode(acrossImpl, abi.encodeWithSelector(
                AcrossSwapModule.initialize.selector,
                address(roleRegistry),
                SPOKE_POOL,
                MULTICALL_HANDLER,
                address(0xdEaD)
            ))
        ));

        // 3. Whitelist the module + allow it to place withdrawal holds.
        //    (Deployer must hold DATA_PROVIDER_ADMIN_ROLE and CASH_MODULE_CONTROLLER_ROLE
        //    on the dev stack.)
        address[] memory modules = new address[](1);
        modules[0] = address(acrossModule);
        bool[] memory enable = new bool[](1);
        enable[0] = true;
        dataProvider.configureDefaultModules(modules, enable);
        cashModule.configureModulesCanRequestWithdraw(modules, enable);

        // 4. Roles.
        roleRegistry.grantRole(acrossModule.ACROSS_SWAP_MODULE_ADMIN_ROLE(), deployer);
        roleRegistry.grantRole(acrossModule.ACROSS_SWAP_MODULE_KEEPER_ROLE(), keeper);

        // 5. Upgrade the DataProvider proxy to the bridge-aware impl — the deployed OP dev
        //    impl predates setOwnershipBridgeSender/getOwnershipBridgeSender. UUPS upgrade,
        //    gated on the roleRegistry owner (the dev key). No initializer re-run needed:
        //    the new impl only adds functions + one fresh storage field.
        address newDataProviderImpl = _deploy(
            "EtherFiDataProviderImplBridgedDev", type(EtherFiDataProvider).creationCode, ""
        );
        dataProvider.upgradeToAndCall(newDataProviderImpl, "");

        // 6. Point safes at the bridge sender and roll the beacon to the bridge-wired
        //    EtherFiSafe impl so owner mutations on existing dev safes start publishing.
        dataProvider.setOwnershipBridgeSender(address(sender));
        address newSafeImpl = _deploy(
            "EtherFiSafeImplBridgedDev", type(EtherFiSafe).creationCode, abi.encode(address(dataProvider))
        );
        safeFactory.upgradeBeaconImplementation(newSafeImpl);

        vm.stopBroadcast();

        string memory out = "trading-account-optimism";
        vm.serializeAddress(out, "OwnershipBridgeSender", address(sender));
        vm.serializeAddress(out, "AcrossSwapModule", address(acrossModule));
        string memory json = vm.serializeAddress(out, "EtherFiSafeImpl", newSafeImpl);
        vm.writeJson(json, string.concat(
            vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/trading-account.json"
        ));

        console.log("OwnershipBridgeSender:", address(sender));
        console.log("AcrossSwapModule:     ", address(acrossModule));
        console.log("EtherFiSafeImpl:      ", newSafeImpl);
    }

    /// @dev CREATE3-deploys `creationCode ++ constructorArgs` under a string salt.
    function _deploy(string memory saltName, bytes memory creationCode, bytes memory constructorArgs)
        internal
        returns (address)
    {
        return DEPLOYER.deploy(getSalt(saltName), abi.encodePacked(creationCode, constructorArgs));
    }
}
