// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { BackedCCIPWrapperBridgeAdapter } from "../../src/top-up/bridge/BackedCCIPWrapperBridgeAdapter.sol";
import { XStocksOPDeployer } from "./XStocksOPDeployer.sol";
import { XStocksOPProd as C } from "./XStocksOPProdConfig.sol";

/**
 * @title DeployBackedCCIPWrapperAdapterEth
 * @notice Deploys the TopUpFactory bridge adapter that redeems a Backed wrapper and sends the raw xStock to
 *         Optimism over Backed's CCIP bridge, through the EtherFiDeployer, and records it in
 *         deployments/mainnet/1/deployments.json. Pointing the wrappers at it is the 8h timelock's job.
 * @dev Idempotent; the adapter is stateless and takes no constructor arguments.
 *
 * Usage:
 *   source .env && forge script scripts/xstocks-op/DeployBackedCCIPWrapperAdapterEth.s.sol --rpc-url $MAINNET_RPC --account dev-admin --broadcast --verify -vvv
 */
contract DeployBackedCCIPWrapperAdapterEth is XStocksOPDeployer {
    using stdJson for string;

    function run() public {
        require(block.chainid == 1, "Ethereum only");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        vm.startBroadcast();
        address adapter = _deployWrapperAdapter(false);
        vm.stopBroadcast();

        address topUpDest = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(C.OP_CHAIN_ID), "/deployments.json")).readAddress(".addresses.TopUpDest");
        (address feeToken, uint256 fee) = BackedCCIPWrapperBridgeAdapter(adapter).getBridgeFee(C.stocks()[0].wrapper, 1e18, topUpDest, C.OP_CHAIN_ID, abi.encode(C.BACKED_BRIDGE, C.OPTIMISM_SELECTOR));
        require(feeToken == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE && fee > 0, "adapter cannot quote the bridge");

        console.log("BackedCCIPWrapperBridgeAdapter:", adapter);
        console.log("Quoted fee for 1 wSPYx to Optimism (wei):", fee);
        string memory path = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/1/deployments.json");
        vm.writeJson(string.concat('"', vm.toString(adapter), '"'), path, string.concat(".addresses.", C.KEY_CCIP_WRAPPER_ADAPTER));
    }
}
