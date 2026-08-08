// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { StockOFTBridgeAdapter } from "../../src/top-up/bridge/StockOFTBridgeAdapter.sol";
import { StockTopupConfig } from "./StockTopupConfig.sol";

/**
 * @title DeployStockOFTBridgeAdapter
 * @notice Deploys the Ethereum-side `StockOFTBridgeAdapter` through the on-chain
 *         EtherFiDeployer (CREATE3, env-prefixed salt) and records it in
 *         deployments/{ENV}/1/deployments.json under `StockOFTBridgeAdapter`.
 *
 *         The adapter is stateless and unowned — it is only ever delegatecalled by
 *         `TopUpFactory.bridge()` — so this deploy needs no privileged call and no
 *         Gnosis bundle in either env. The privileged half (the token config) lives in
 *         SetSpyxTopupConfigEthereum.s.sol.
 *
 *         Re-running is a no-op: `_create3` returns the existing address when the
 *         deterministic slot already holds code.
 *
 * Env: PRIVATE_KEY (must be a registered EtherFiDeployer deployer), ENV (dev|mainnet)
 *
 * Run:
 *   source .env && ENV=mainnet forge script scripts/stock-topup/DeployStockOFTBridgeAdapter.s.sol \
 *     --rpc-url $MAINNET_RPC --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvvv
 */
contract DeployStockOFTBridgeAdapter is StockTopupConfig {
    function run() public {
        require(block.chainid == 1, "This script must be run on Ethereum mainnet (chain ID 1)");

        // Fail before broadcasting if the constants don't describe a real wrap-and-send chain.
        _assertAssetWiring();

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        require(DEPLOYER.isDeployer(vm.addr(deployerPk)), "broadcaster is not an EtherFiDeployer deployer");

        address predicted = _adapterAddress();

        vm.startBroadcast(deployerPk);
        address adapter = _create3(_adapterSalt(), type(StockOFTBridgeAdapter).creationCode, "");
        vm.stopBroadcast();

        require(adapter == predicted, "deployed address does not match the predicted CREATE3 address");
        require(adapter.code.length > 0, "adapter has no code");

        vm.writeJson(string.concat('"', vm.toString(adapter), '"'), _ethereumDeploymentPath(), string.concat(".addresses.", ADAPTER_DEPLOYMENT_KEY));

        console.log("ENV:", getEnv());
        console.log("StockOFTBridgeAdapter:", adapter);
        console.log("Recorded in:", _ethereumDeploymentPath());
    }
}
