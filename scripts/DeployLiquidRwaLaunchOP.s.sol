// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { UUPSProxy } from "../src/UUPSProxy.sol";
import { LiquidUSDLiquifierOPModule } from "../src/modules/etherfi/LiquidUSDLiquifierOP.sol";
import { MidasLiquifierModule } from "../src/modules/etherfi/MidasLiquifierModule.sol";
import { EtherFiDeployerHelper } from "./utils/EtherFiDeployerHelper.sol";

/**
 * @title DeployLiquidRwaLaunchOP
 * @notice Deploys the three contracts the Liquid RWA launch 3CP needs on Optimism prod through the
 *         EtherFiDeployer: the MidasLiquifierModule implementation and proxy, and the audited
 *         LiquidUSDLiquifierOPModule implementation for the proxy upgrade. Config (pair, default module,
 *         driver, upgrade) is NOT done here; it is owner or admin gated and goes through LiquidRwaLaunchOP3CP.
 * @dev Idempotent: a salt that already holds code is returned, not redeployed.
 *
 * Usage:
 *   source .env && forge script scripts/DeployLiquidRwaLaunchOP.s.sol --rpc-url $OPTIMISM_RPC --account dev-admin --broadcast --verify -vvv
 */
contract DeployLiquidRwaLaunchOP is EtherFiDeployerHelper {
    using stdJson for string;

    string constant MIDAS_IMPL = "MidasLiquifierModuleImplV2";
    string constant MIDAS_PROXY = "MidasLiquifierModuleProxyV2";
    string constant LIQUID_USD_IMPL = "LiquidUSDLiquifierOPModuleImplV3";

    function run() public {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");
        string memory deployments = readDeploymentFile();
        address debtManager = deployments.readAddress(".addresses.DebtManager");
        address dataProvider = deployments.readAddress(".addresses.EtherFiDataProvider");
        address roleRegistry = deployments.readAddress(".addresses.RoleRegistry");

        vm.startBroadcast();
        address midasImpl = _create3(MIDAS_IMPL, type(MidasLiquifierModule).creationCode, abi.encode(debtManager, dataProvider));
        bytes memory init = abi.encodeCall(MidasLiquifierModule.initialize, (roleRegistry));
        address midasProxy = _create3(MIDAS_PROXY, type(UUPSProxy).creationCode, abi.encode(midasImpl, init));
        address liquidUsdImpl = _create3(LIQUID_USD_IMPL, type(LiquidUSDLiquifierOPModule).creationCode, abi.encode(debtManager, dataProvider));
        vm.stopBroadcast();

        require(address(MidasLiquifierModule(midasProxy).roleRegistry()) == roleRegistry, "role registry mismatch");
        require(address(MidasLiquifierModule(midasProxy).debtManager()) == debtManager, "debt manager mismatch");
        require(address(LiquidUSDLiquifierOPModule(liquidUsdImpl).debtManager()) == debtManager, "liquidUSD impl debt manager mismatch");

        console.log("MidasLiquifierModule impl:", midasImpl);
        console.log("MidasLiquifierModule proxy:", midasProxy);
        console.log("LiquidUSDLiquifierOPModule impl:", liquidUsdImpl);

        string memory path = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/deployments.json");
        vm.writeJson(string.concat('"', vm.toString(midasProxy), '"'), path, ".addresses.MidasLiquifierModule");
        vm.writeJson(string.concat('"', vm.toString(midasImpl), '"'), path, ".addresses.MidasLiquifierModuleImpl");
        vm.writeJson(string.concat('"', vm.toString(liquidUsdImpl), '"'), path, ".addresses.LiquidUSDLiquifierModuleImpl");
    }
}
