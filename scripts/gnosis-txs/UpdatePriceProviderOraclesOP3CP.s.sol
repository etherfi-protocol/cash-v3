// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { OpOracleFeedUpdate } from "../oracle-updates/OpOracleFeedUpdate.sol";

/**
 * @notice Generates the OP 3CP JSON to repoint the prod PriceProviderV2 (used by the DebtManager,
 *         CashLens and every other cash price consumer) off Pyth onto official Chainlink
 *         aggregator proxies for wHYPE / beHYPE / ETHFI / EURC, and frxUSD onto its new Chainlink
 *         feed. Single tx from the OperatingSafe (holds PRICE_PROVIDER_ADMIN_ROLE):
 *
 *           PriceProviderV2.setTokenConfig([wHYPE, beHYPE, ETHFI, EURC, frxUSD], configs)
 *
 *         See OpOracleFeedUpdate for the feed table and the beHYPE baseAsset composition.
 *         The bundle is fork-simulated and the post-state asserted (configs stored, every price
 *         within 2% of its pre-update value, frxUSD snapping to $1) before the JSON is trusted.
 *
 * Usage:
 *   forge script scripts/gnosis-txs/UpdatePriceProviderOraclesOP3CP.s.sol --rpc-url $OPTIMISM_RPC
 */
contract UpdatePriceProviderOraclesOP3CP is GnosisHelpers, Utils, Test, OpOracleFeedUpdate {
    address constant OPERATING_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    function run() public {
        require(block.chainid == 10, "must be Optimism");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        string memory deployments = readDeploymentFile();
        PriceProviderV2 pp = PriceProviderV2(stdJson.readAddress(deployments, ".addresses.PriceProvider"));
        require(address(pp) != address(0), "PriceProvider not found in deployments.json");

        address[] memory tokens = _updateTokens();
        PriceProviderV2.Config[] memory configs = _updateConfigs();

        // Pre-state: prices under the old configs, proving both the old and (via the same tokens
        // after simulation) the new pipelines work, and giving the reviewer the deltas.
        uint256[5] memory pre;
        for (uint256 i = 0; i < tokens.length; i++) {
            pre[i] = pp.price(tokens[i]);
        }

        string memory txs = _getGnosisHeader("10", addressToHex(OPERATING_SAFE));
        bytes memory callData = abi.encodeWithSelector(PriceProviderV2.setTokenConfig.selector, tokens, configs);
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(pp)), iToHex(callData), "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/UpdatePriceProviderOracles3CP-op-10.json";
        vm.writeFile(path, txs);
        console.log("Written: %s", path);

        executeGnosisTransactionBundle(path);
        _assertPostState(pp, pre);

        console.log("Simulation passed. Prices (6 decimals, old -> new):");
        string[5] memory names = ["wHYPE", "beHYPE", "ETHFI", "EURC", "frxUSD"];
        for (uint256 i = 0; i < tokens.length; i++) {
            console.log("  %s: %s -> %s", names[i], pre[i], pp.price(tokens[i]));
        }
    }
}
