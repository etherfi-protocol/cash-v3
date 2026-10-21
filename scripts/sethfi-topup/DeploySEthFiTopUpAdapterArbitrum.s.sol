// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { EtherFiLiquidBridgeAdapter } from "../../src/top-up/bridge/EtherFiLiquidBridgeAdapter.sol";
import { SEthFiTopUpConfig } from "./SEthFiTopUpConfig.sol";

/**
 * @title DeploySEthFiTopUpAdapterArbitrum
 * @notice CREATE3-deploys the EtherFiLiquidBridgeAdapter on Arbitrum through the EtherFiDeployer.
 *         The adapter is stateless and unowned; deploying it changes no live state. The
 *         TopUpFactory starts using it only once the 3CP from SEthFiTopUp3CP.s.sol executes.
 *         Idempotent: returns the existing address when it already holds code.
 * @dev Prod only. Record the address under `EtherFiLiquidBridgeAdapter` in
 *      deployments/mainnet/42161/deployments.json after the broadcast.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/sethfi-topup/DeploySEthFiTopUpAdapterArbitrum.s.sol \
 *     --rpc-url $ARBITRUM_RPC --ledger --sender $PROD_DEPLOYER --broadcast --verify
 */
contract DeploySEthFiTopUpAdapterArbitrum is SEthFiTopUpConfig {
    function run() public {
        require(isEqualString(getEnv(), "mainnet"), "prod only: ENV must be mainnet");
        require(block.chainid == ARBITRUM, "run on Arbitrum");
        require(_predictAddress(ARB_ADAPTER_SALT) == ARB_LIQUID_ADAPTER, "adapter salt does not resolve to the pinned address");

        vm.startBroadcast();
        require(DEPLOYER.isDeployer(msg.sender), "broadcaster is not an EtherFiDeployer deployer");
        address adapter = _create3(ARB_ADAPTER_SALT, type(EtherFiLiquidBridgeAdapter).creationCode, "");
        vm.stopBroadcast();

        require(adapter == ARB_LIQUID_ADAPTER, "adapter did not land at the pinned address");
        console.log("EtherFiLiquidBridgeAdapter:", adapter);
    }
}
