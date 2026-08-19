// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { Utils } from "../utils/Utils.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { AcrossSwapModule } from "../../src/across/AcrossSwapModule.sol";
import { EnsoSwapModule } from "../../src/enso/EnsoSwapModule.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";

/**
 * @title DeployTradingAccountOptimism
 * @notice Dev/testnet deploy of the source-chain (OP) trading-account pieces against the
 *         EXISTING OP dev stack (read from deployments.json): AcrossSwapModule (Buy
 *         direction), EnsoSwapModule, module whitelisting, roles, and Across config.
 *
 * Run:
 *   source .env && ENV=dev forge script scripts/trading-account/DeployTradingAccountOptimism.s.sol --rpc-url optimism --broadcast -vvv --verify
 */
contract DeployTradingAccountOptimism is Utils {
    // Our cross-chain CREATE3 deployer — same address on every chain.
    EtherFiDeployer constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);

    // Across V3 on Optimism.
    address constant SPOKE_POOL = 0x6f26Bf09B1C792e3228e5467807a900A503c0281;
    address constant MULTICALL_HANDLER = 0x0F7Ae28dE1C8532170AD4ee566B5801485c13a0E;
    // Across SpokePoolPeriphery — origin-swap (anyToBridgeable) routes for the Sell flow.
    address constant PERIPHERY = 0x10D8b8DaA26d307489803e10477De69C0492B610;

    // Enso Router V2 (same address on Ethereum and Optimism). Pinned target for the
    // EnsoSwapModule's forward-calldata swaps.
    address constant ENSO_ROUTER = 0xF75584eF6673aD213a685a1B58Cc0330B8eA22Cf;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

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

        require(DEPLOYER.isDeployer(deployer), "broadcaster not registered on EtherFiDeployer");

        vm.startBroadcast(pk);

        // 1. AcrossSwapModule — Buy direction, behind a UUPS proxy initialised atomically
        //    in its deployment tx (full Across config in the initialize calldata). The
        //    impl constructor reads getCashModule() from the initialised OP data
        //    provider, so the CashModule hold path is live here. Same proxy salt as the
        //    mainnet deploy ⇒ same address on both chains. The module is Buy-only
        //    (requestSwap stores the deposit args; executeSwap replays after the delay).
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
                MULTICALL_HANDLER
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
        roleRegistry.grantRole(acrossModule.OPERATING_TIMELOCK_ROLE(), deployer);
        // Periphery isn't part of initialize() — set it post-grant so origin-swap (Sell) routes work.
        acrossModule.setPeriphery(PERIPHERY);

        // 4b. EnsoSwapModule — same forward-calldata lifecycle, targeting the pinned Enso Router.
        //     Behind a UUPS proxy initialised atomically in its deployment tx. The impl
        //     constructor reads getCashModule() from the OP data provider, so the CashModule
        //     hold path is live here (same as Across on OP).
        address ensoImpl = _deploy(
            "EnsoSwapModuleImplDev", type(EnsoSwapModule).creationCode, abi.encode(address(dataProvider))
        );
        EnsoSwapModule ensoModule = EnsoSwapModule(_deploy(
            "EnsoSwapModuleDev",
            type(UUPSProxy).creationCode,
            abi.encode(ensoImpl, abi.encodeWithSelector(
                EnsoSwapModule.initialize.selector,
                address(roleRegistry),
                ENSO_ROUTER
            ))
        ));
        modules[0] = address(ensoModule);
        dataProvider.configureDefaultModules(modules, enable);
        cashModule.configureModulesCanRequestWithdraw(modules, enable);
        roleRegistry.grantRole(ensoModule.OPERATING_TIMELOCK_ROLE(), deployer);

        vm.stopBroadcast();

        string memory out = "trading-account-optimism";
        vm.serializeAddress(out, "AcrossSwapModule", address(acrossModule));
        string memory json = vm.serializeAddress(out, "EnsoSwapModule", address(ensoModule));
        vm.writeJson(json, string.concat(
            vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/trading-account.json"
        ));

        console.log("AcrossSwapModule:     ", address(acrossModule));
        console.log("EnsoSwapModule:       ", address(ensoModule));
    }

    /// @dev CREATE3-deploys `creationCode ++ constructorArgs` under a string salt.
    function _deploy(string memory saltName, bytes memory creationCode, bytes memory constructorArgs)
        internal
        returns (address)
    {
        return DEPLOYER.deploy(getSalt(saltName), abi.encodePacked(creationCode, constructorArgs));
    }
}
