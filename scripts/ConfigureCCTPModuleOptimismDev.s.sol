// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { Utils } from "./utils/Utils.sol";
import { CCTPModule } from "../src/modules/cctp/CCTPModule.sol";
import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../src/interfaces/ICashModule.sol";
import { IRoleRegistry } from "../src/interfaces/IRoleRegistry.sol";

/**
 * @notice Post-deploy wiring for CCTPModule on OP dev.
 * @dev Broadcaster must hold DATA_PROVIDER_ADMIN_ROLE + CASH_MODULE_CONTROLLER_ROLE + DEFAULT_ADMIN_ROLE
 *      (grantRole). The dev deployer key holds all three.
 *
 *      Runs the 5 governance steps in order:
 *        1. dataProvider.configureDefaultModules([cctp], [true])       // auto-enable on new safes
 *        2. cashModule.configureModulesCanRequestWithdraw([cctp], [true])
 *        3. roleRegistry.grantRole(CCTP_MODULE_ADMIN_ROLE, admin)
 *        4. cctp.setAllowedRoutes(USDC, [0, 6], [true, true])          // ETH + Base (FE-wired dests)
 *        5. cctp.setproviderFeeRecipient(providerFeeRecipient)         // mandatory: providerFeeBps=50 baked in
 */
contract ConfigureCCTPModuleOptimismDev is Utils {
    // OP dev deploy — see broadcast/DeployCCTPModule.s.sol/10/run-latest.json
    address constant CCTP_MODULE = 0x2C8fA5677160a6Ca98E93a5e1d38275E276c4578;
    address constant USDC        = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    // Allowed destination CCTP domains for dev. Domains per Circle docs:
    //   0=ETH, 1=Avax, 2=OP (source), 3=Arb, 6=Base, 7=Polygon, 10=Unichain, 11=Linea.
    // FE currently supports ETH + Base as destinations; open more as you extend the UI.
    uint32 constant DOMAIN_ETHEREUM = 0;
    uint32 constant DOMAIN_BASE     = 6;

    function run() public {
        address broadcaster = msg.sender;

        string memory deployments = readDeploymentFile();
        address dataProvider = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        address cashModule   = stdJson.readAddress(deployments, ".addresses.CashModule");
        address roleRegistry = stdJson.readAddress(deployments, ".addresses.RoleRegistry");

        // Provider fee recipient — the broadcaster on dev is fine; treasury for prod.
        // Override via env var CCTP_PROVIDER_FEE_RECIPIENT if you want a different one.
        address providerFeeRecipient = vm.envOr("CCTP_PROVIDER_FEE_RECIPIENT", broadcaster);

        // Admin role holder — same story: broadcaster on dev, real admin for prod.
        address cctpAdmin = vm.envOr("CCTP_MODULE_ADMIN", broadcaster);

        console.log("dataProvider    ", dataProvider);
        console.log("cashModule      ", cashModule);
        console.log("roleRegistry    ", roleRegistry);
        console.log("cctpModule      ", CCTP_MODULE);
        console.log("cctpAdmin       ", cctpAdmin);
        console.log("providerFeeRecp ", providerFeeRecipient);

        vm.startBroadcast();

        // 1. Register the module in the data provider (default = auto-enabled on new safes,
        //    matches how StargateModule is wired).
        address[] memory modules = new address[](1);
        modules[0] = CCTP_MODULE;
        bool[] memory yes = new bool[](1);
        yes[0] = true;
        EtherFiDataProvider(dataProvider).configureDefaultModules(modules, yes);
        console.log("[1/5] configureDefaultModules -> ok");

        // 2. Allow CCTPModule to request delayed withdrawals via CashModule.
        ICashModule(cashModule).configureModulesCanRequestWithdraw(modules, yes);
        console.log("[2/5] configureModulesCanRequestWithdraw -> ok");

        // 3. Grant CCTP_MODULE_ADMIN_ROLE so the admin can set allowed domains, asset config, fee recipient.
        bytes32 adminRole = CCTPModule(CCTP_MODULE).CCTP_MODULE_ADMIN_ROLE();
        IRoleRegistry(roleRegistry).grantRole(adminRole, cctpAdmin);
        console.log("[3/5] grantRole(CCTP_MODULE_ADMIN_ROLE) -> ok");

        // 4. Allowlist destination domains. Add more domains as the FE opens more destinations.
        uint32[] memory domains = new uint32[](2);
        domains[0] = DOMAIN_ETHEREUM;
        domains[1] = DOMAIN_BASE;
        bool[] memory allowed = new bool[](2);
        allowed[0] = true;
        allowed[1] = true;
        CCTPModule(CCTP_MODULE).setAllowedRoutes(USDC, domains, allowed);
        console.log("[4/5] setAllowedRoutes(USDC) -> ok");

        // 5. Set provider fee recipient — mandatory because deploy set providerFeeBps = 50 (0.5%).
        //    Without this, requestBridge reverts with providerFeeRecipientNotSet.
        CCTPModule(CCTP_MODULE).setproviderFeeRecipient(providerFeeRecipient);
        console.log("[5/5] setproviderFeeRecipient -> ok");

        vm.stopBroadcast();
    }
}
