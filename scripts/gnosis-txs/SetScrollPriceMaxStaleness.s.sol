// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { PriceProvider } from "../../src/oracle/PriceProvider.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/// @title SetScrollPriceMaxStaleness
/// @notice Generates a Gnosis Safe batch transaction that re-sets every Scroll asset's
///         PriceProvider config with maxStaleness = 180 days, preserving all other fields.
/// @dev maxStaleness is a uint24 (max 16,777,215s ~= 194.18 days), so a literal 1 year
///      cannot be stored. 180 days (15,552,000s) is the agreed target and fits comfortably.
///
///      "All assets" is taken as the union of DebtManager.getCollateralTokens() and
///      getBorrowTokens(), read live from the fork. Each token's existing config is read
///      from the PriceProvider and re-set with only maxStaleness changed; every other field
///      (oracle, calldata, decimals, flags) is preserved verbatim.
///
/// Usage:
///   ENV=mainnet forge script scripts/gnosis-txs/SetScrollPriceMaxStaleness.s.sol --rpc-url scroll -vvv
contract SetScrollPriceMaxStaleness is Utils, GnosisHelpers, Test {
    address constant cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    uint24 constant NEW_MAX_STALENESS = 180 days; // 15,552,000s, within uint24 max

    // V1 PriceProvider stores the USD base-oracle configs in the same tokenConfig mapping,
    // keyed by these selector addresses. Tokens with isBaseTokenEth/isBaseTokenBtc price
    // *through* these, so their staleness must be bumped too or those tokens still revert
    // OraclePriceTooOld. Unconfigured selectors are skipped by the config filter.
    address constant ETH_USD_ORACLE_SELECTOR  = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address constant WETH_USD_ORACLE_SELECTOR = 0x4200000000000000000000000000000000000006;
    address constant WBTC_USD_ORACLE_SELECTOR = 0x68f180fcCe6836688e9084f035309E29Bf0A2095;

    PriceProvider priceProvider;
    IDebtManager debtManager;

    function run() public {
        require(block.chainid == 534352, "Must run on Scroll (chain ID 534352)");

        string memory deployments = readDeploymentFile();
        priceProvider = PriceProvider(payable(stdJson.readAddress(deployments, ".addresses.PriceProvider")));
        debtManager = IDebtManager(stdJson.readAddress(deployments, ".addresses.DebtManager"));
        string memory chainId = vm.toString(block.chainid);

        console.log("PriceProvider:", address(priceProvider));
        console.log("DebtManager:", address(debtManager));
        console.log("Safe:", cashControllerSafe);

        // Candidate set: union of collateral + borrow tokens, deduped.
        address[] memory candidates = _collectAssets();

        // Keep only tokens that actually have a PriceProvider config. A token can be a
        // DebtManager collateral/borrow token without a config here (e.g. WETH on Scroll);
        // re-setting a zero config would corrupt state, so we skip and report those.
        address[] memory tokens = new address[](candidates.length);
        PriceProvider.Config[] memory configs = new PriceProvider.Config[](candidates.length);
        uint256 count = 0;
        for (uint256 i = 0; i < candidates.length; i++) {
            PriceProvider.Config memory cfg = priceProvider.tokenConfig(candidates[i]);
            if (cfg.oracle == address(0)) {
                console.log("  SKIP (no config)", vm.toString(candidates[i]));
                continue;
            }
            cfg.maxStaleness = NEW_MAX_STALENESS;
            tokens[count] = candidates[i];
            configs[count] = cfg;
            count++;
            console.log("  staging", vm.toString(candidates[i]));
        }

        // Trim to the configured set.
        assembly {
            mstore(tokens, count)
            mstore(configs, count)
        }
        require(count > 0, "No configured assets found");

        // ── setTokenConfig(tokens, configs) on the PriceProvider ──
        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));
        string memory data = iToHex(abi.encodeWithSelector(PriceProvider.setTokenConfig.selector, tokens, configs));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(priceProvider)), data, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/SetScrollPriceMaxStaleness.json";
        vm.writeFile(path, txs);
        console.log("Bundle written to:", path);

        // Simulate against the fork (pranks the Safe).
        executeGnosisTransactionBundle(path);
        console.log("Simulation OK");

        // Verify staleness updated and prices still resolve.
        _verify(tokens);
    }

    /// @dev Base-oracle selector keys + union of collateral and borrow tokens, deduped.
    function _collectAssets() internal view returns (address[] memory) {
        address[] memory collateral = debtManager.getCollateralTokens();
        address[] memory borrow = debtManager.getBorrowTokens();

        address[] memory tmp = new address[](collateral.length + borrow.length + 3);
        uint256 n = 0;

        // Base USD oracle keys first, so the ETH/BTC conversion path gets the new staleness.
        tmp[n++] = ETH_USD_ORACLE_SELECTOR;
        tmp[n++] = WETH_USD_ORACLE_SELECTOR;
        tmp[n++] = WBTC_USD_ORACLE_SELECTOR;

        for (uint256 i = 0; i < collateral.length; i++) {
            if (!_contains(tmp, n, collateral[i])) tmp[n++] = collateral[i];
        }
        for (uint256 i = 0; i < borrow.length; i++) {
            if (!_contains(tmp, n, borrow[i])) tmp[n++] = borrow[i];
        }

        address[] memory out = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = tmp[i];
        }
        return out;
    }

    function _contains(address[] memory arr, uint256 len, address target) internal pure returns (bool) {
        for (uint256 i = 0; i < len; i++) {
            if (arr[i] == target) return true;
        }
        return false;
    }

    function _verify(address[] memory tokens) internal view {
        for (uint256 i = 0; i < tokens.length; i++) {
            // Hard invariant: the staleness we set must be stored.
            PriceProvider.Config memory cfg = priceProvider.tokenConfig(tokens[i]);
            require(cfg.maxStaleness == NEW_MAX_STALENESS, string.concat("Staleness not set for ", vm.toString(tokens[i])));

            // Soft check: price() may still revert for pre-existing reasons unrelated to
            // staleness (e.g. a BTC-based token whose WBTC/USD base oracle is unconfigured).
            // Report rather than fail the bundle generation.
            try priceProvider.price(tokens[i]) returns (uint256 p) {
                console.log("  [OK]", vm.toString(tokens[i]), p);
            } catch {
                console.log("  [PRICE STILL REVERTS]", vm.toString(tokens[i]));
            }
        }
        console.log("Verified maxStaleness =", uint256(NEW_MAX_STALENESS), "for all configured assets");
    }
}
