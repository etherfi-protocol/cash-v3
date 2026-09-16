// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { LendGateway } from "../src/modules/lend-gateway/LendGateway.sol";
import { SettlementDispatcherV2 } from "../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { Utils } from "./utils/Utils.sol";

/// @notice Makes liquidRWA spendable on dev: gateway spend asset flag plus the Midas redemption vault on all four
///         settlement dispatchers. The broadcaster must be the dev RoleRegistry owner and LEND_GATEWAY_ADMIN.
///
/// Usage:
///   ENV=dev forge script scripts/EnableLiquidRwaSpendDev.s.sol --rpc-url $OPTIMISM_RPC --account dev-admin --broadcast -vvvv
contract EnableLiquidRwaSpendDev is Utils {
    using stdJson for string;

    address constant LIQUID_RWA = 0x17bC8Ffd82b8a36e737Ca1141C025089589B915e;
    address constant LIQUID_RWA_REDEMPTION_VAULT = 0x12Ae90dCe5C2a4Ee5141FBfc408ff1022D051F42;

    function run() public {
        string memory deployments = readDeploymentFile();
        LendGateway gateway = LendGateway(deployments.readAddress(".addresses.LendGateway"));
        address[4] memory dispatchers = [deployments.readAddress(".addresses.SettlementDispatcherRain"), deployments.readAddress(".addresses.SettlementDispatcherReap"), deployments.readAddress(".addresses.SettlementDispatcherPix"), deployments.readAddress(".addresses.SettlementDispatcherCardOrder")];

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        if (!gateway.isSpendAsset(LIQUID_RWA)) gateway.setSpendAsset(LIQUID_RWA, true);
        for (uint256 i = 0; i < dispatchers.length; i++) {
            SettlementDispatcherV2 dispatcher = SettlementDispatcherV2(payable(dispatchers[i]));
            if (dispatcher.getMidasRedemptionVault(LIQUID_RWA) != LIQUID_RWA_REDEMPTION_VAULT) {
                dispatcher.setMidasRedemptionVault(LIQUID_RWA, LIQUID_RWA_REDEMPTION_VAULT);
            }
        }
        vm.stopBroadcast();

        require(gateway.isSpendAsset(LIQUID_RWA), "spend asset not set");
        for (uint256 i = 0; i < dispatchers.length; i++) {
            require(SettlementDispatcherV2(payable(dispatchers[i])).getMidasRedemptionVault(LIQUID_RWA) == LIQUID_RWA_REDEMPTION_VAULT, "redemption vault not set");
            console.log("dispatcher configured:", dispatchers[i]);
        }
        console.log("liquidRWA spendable on gateway:", address(gateway));
    }
}
