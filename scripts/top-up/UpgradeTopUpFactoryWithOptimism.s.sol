// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { StargateAdapter } from "../../src/top-up/bridge/StargateAdapter.sol";
import { OptimismBridgeAdapter } from "../../src/top-up/bridge/OptimismBridgeAdapter.sol";
import { HopBridgeAdapter } from "../../src/top-up/bridge/HopBridgeAdapter.sol";
import { EtherFiLiquidBridgeAdapter } from "../../src/top-up/bridge/EtherFiLiquidBridgeAdapter.sol";
import { EtherFiOFTBridgeAdapter } from "../../src/top-up/bridge/EtherFiOFTBridgeAdapter.sol";
import { CCTPAdapter } from "../../src/top-up/bridge/CCTPAdapter.sol";
import { TopUpSourceSetConfig } from "./TopUpSourceSetConfig.s.sol";

/// @title UpgradeTopUpFactoryWithOptimism
/// @notice Upgrades the TopUpFactory to the multi-chain version, deploys new bridge adapters
///         (Optimism native, Stargate, CCTP, Liquid, Hop), and configures all token bridges from fixtures.
///
/// Usage:
///   ENV=dev PRIVATE_KEY=0x... forge script scripts/top-up/UpgradeTopUpFactoryWithOptimism.s.sol --rpc-url <ETH_RPC> --broadcast
contract UpgradeTopUpFactoryWithOptimism is TopUpSourceSetConfig {

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function run() public override {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        string memory deployments = readTopUpSourceDeployment();
        address topUpFactoryProxy = stdJson.readAddress(deployments, ".addresses.TopUpSourceFactory");

        vm.startBroadcast(deployerPrivateKey);

        // ── 1. Upgrade TopUpFactory to new impl (multi-chain support) ──
        console.log("1. Upgrading TopUpFactory...");
        address newImpl = address(new TopUpFactory());
        UUPSUpgradeable(topUpFactoryProxy).upgradeToAndCall(newImpl, "");
        topUpFactory = TopUpFactory(payable(topUpFactoryProxy));

        // ── 2. Deploy bridge adapters ──
        console.log("2. Deploying bridge adapters...");

        address stargateDeployed = address(new StargateAdapter(WETH));
        console.log("  StargateAdapter:", stargateDeployed);

        address opDeployed = address(new OptimismBridgeAdapter());
        console.log("  OptimismBridgeAdapter:", opDeployed);

        address hopDeployed = address(new HopBridgeAdapter());
        console.log("  HopBridgeAdapter:", hopDeployed);

        address liquidDeployed = address(new EtherFiLiquidBridgeAdapter());
        console.log("  EtherFiLiquidBridgeAdapter:", liquidDeployed);

        address cctpDeployed = address(new CCTPAdapter());
        console.log("  CCTPAdapter:", cctpDeployed);

        address oftBridgeAdapterDeployed = address(new EtherFiOFTBridgeAdapter());
        console.log("  EtherFiOFTBridgeAdapter:", oftBridgeAdapterDeployed);
    }
}
