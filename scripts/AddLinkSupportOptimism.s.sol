// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { ICashModule } from "../src/interfaces/ICashModule.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";
import { PriceProviderV2 } from "../src/oracle/PriceProviderV2.sol";
import { Utils } from "./utils/Utils.sol";

/**
 * @title AddLinkSupportOptimism
 * @author ether.fi
 * @notice Makes bridged LINK (iLINK) usable as a Cash asset on Optimism dev so a user can
 *         HOLD, SPEND and BORROW against it. Three dev-owner calls:
 *           1. PriceProviderV2.setTokenConfig  - price iLINK from the cross-chain OracleSink.
 *           2. DebtManager.supportCollateralToken - enable borrowing against iLINK (collateral only).
 *           3. CashModule.configureWithdrawAssets - whitelist iLINK for hold/spend.
 * @dev The OracleSink returns a 6-decimal USD price and is keyed by the MAINNET LINK address (the
 *      relay ships mainnet token addresses), so the oracle calldata is price(LINK_MAINNET) even
 *      though the Cash token key is iLINK. The broadcaster must hold PRICE_PROVIDER_ADMIN_ROLE,
 *      DEBT_MANAGER_ADMIN_ROLE and CASH_MODULE_CONTROLLER_ROLE (held by the dev owner from setup).
 *      Idempotent. Run on Optimism:
 *
 *        ENV=dev forge script scripts/AddLinkSupportOptimism.s.sol \
 *          --rpc-url $OPTIMISM_RPC --account dev-owner --sender <dev-owner-address> --broadcast
 */
contract AddLinkSupportOptimism is Utils {
    /// @notice Native LINK on Ethereum mainnet. Used ONLY as the OracleSink price key.
    address constant LINK_MAINNET = 0x514910771AF9Ca656af840dff83E8264EcF986CA;

    /// @notice iLINK shadow OFT on Optimism dev (the token Cash users hold). The Cash token key.
    address constant ILINK_OPTIMISM = 0x0C9446D6A4Fb3a9eA0a8Bc85A4Cb6646e424d36f;

    /// @notice OracleSink on Optimism dev (relayed LINK USD price, 6 decimals). Deployed in the
    ///         cash-mainnet-asset-listing repo, so pinned here as a dev constant.
    address constant ORACLE_SINK = 0x83Ba7f354B705C34935437526Cf318c77d9093Aa;

    // DECISION (oracle freshness): max age of a relayed LINK price the PriceProvider will accept.
    // Measures relay delivery on this chain (keeper poke cadence), not the Chainlink heartbeat.
    uint24 constant PRICE_MAX_STALENESS = 2 days;

    // DECISION (risk params): LINK collateral terms, 18-decimal ratios. Dev defaults; confirm with
    // risk before production. ltv < liquidationThreshold.
    uint80 constant LTV = 50e18; // 50%
    uint80 constant LIQUIDATION_THRESHOLD = 80e18; // 80%
    uint96 constant LIQUIDATION_BONUS = 1e18; // 1%

    function run() public {
        require(block.chainid == 10, "run on Optimism (chainId 10)");
        // The hardcoded constants are dev iLINK/OracleSink addresses, and the env-read contracts
        // below must resolve to the dev deployment. getEnv() defaults to "mainnet", and chainId
        // alone cannot tell dev from prod (both live on chain 10), so fail loudly unless ENV=dev.
        require(isEqualString(getEnv(), "dev"), "dev only");

        string memory deployments = readDeploymentFile();
        PriceProviderV2 priceProvider = PriceProviderV2(stdJson.readAddress(deployments, ".addresses.PriceProvider"));
        IDebtManager debtManager = IDebtManager(stdJson.readAddress(deployments, ".addresses.DebtManager"));
        ICashModule cashModule = ICashModule(stdJson.readAddress(deployments, ".addresses.CashModule"));

        // 1. Price iLINK from the cross-chain OracleSink (price(LINK_MAINNET) -> 6-decimal USD).
        address[] memory tokens = new address[](1);
        tokens[0] = ILINK_OPTIMISM;
        PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](1);
        // baseAsset address(0): the OracleSink returns USD directly (6 decimals), so no base-asset conversion.
        configs[0] = PriceProviderV2.Config({ oracle: ORACLE_SINK, priceFunctionCalldata: abi.encodeWithSignature("price(address)", LINK_MAINNET), isChainlinkType: false, oraclePriceDecimals: 6, maxStaleness: PRICE_MAX_STALENESS, dataType: PriceProviderV2.ReturnType.Uint256, isStableToken: false, baseAsset: address(0) });

        // 2. Enable borrowing against iLINK (collateral only; not a borrow token).
        IDebtManager.CollateralTokenConfig memory collateralConfig = IDebtManager.CollateralTokenConfig({ ltv: LTV, liquidationThreshold: LIQUIDATION_THRESHOLD, liquidationBonus: LIQUIDATION_BONUS });

        // 3. Whitelist iLINK so it can be held + spent.
        address[] memory withdrawAssets = new address[](1);
        withdrawAssets[0] = ILINK_OPTIMISM;
        bool[] memory whitelist = new bool[](1);
        whitelist[0] = true;

        // Signer comes from the CLI (--account keystore, --ledger, etc.), never an env var or arg.
        vm.startBroadcast();
        priceProvider.setTokenConfig(tokens, configs);
        if (!debtManager.isCollateralToken(ILINK_OPTIMISM)) debtManager.supportCollateralToken(ILINK_OPTIMISM, collateralConfig);
        cashModule.configureWithdrawAssets(withdrawAssets, whitelist);
        vm.stopBroadcast();

        console.log("Configured iLINK as a Cash asset on Optimism dev (chainId", block.chainid, ")");
        console.log("  iLINK:        ", ILINK_OPTIMISM);
        console.log("  PriceProvider:", address(priceProvider));
        console.log("  DebtManager:  ", address(debtManager));
        console.log("  CashModule:   ", address(cashModule));

        // Best-effort read-back. Reverts if the relay has not delivered a fresh price yet (a
        // keeper/poke issue, not a config error), so do not fail the run on it.
        try priceProvider.price(ILINK_OPTIMISM) returns (uint256 p) {
            console.log("  price(iLINK) USD-6:", p);
        } catch {
            console.log("  price(iLINK): reverted (relay price stale/undelivered - poke the keeper)");
        }
    }
}
