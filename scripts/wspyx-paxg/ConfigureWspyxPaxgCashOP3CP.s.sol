// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { WspyxPaxgFeedDeployer } from "./DeployWspyxPaxgProdFeeds.s.sol";
import { ILendGatewayLike, IOracleSinkAdminLike, ISpokeLike, WspyxPaxgProd as C } from "./WspyxPaxgProdConfig.sol";

/**
 * @title ConfigureWspyxPaxgCashOP3CP
 * @notice Generates the OPERATING SAFE (0xA6cf…AAC4) Optimism bundle for the wSPYx + PAXG
 *         collateral rollout — the cash side of the listing plus the PAXG oracle repoint:
 *
 *           1. PriceProviderV2.setTokenConfig(iPAXG)      — off the OracleSink relay onto the
 *              native Chainlink PAXG/USD aggregator (1-day staleness, USD-quoted, direct)
 *           2. OracleSink.setMaxStaleness(PAXG, 0)        — fail-closed: the sink serves no PAXG
 *           3. OracleSink.clearPrice(PAXG)                — and the stored price is deleted, so an
 *              in-flight relay message cannot resurrect a readable entry
 *           4. DebtManager.supportCollateralToken(iwSPYx) — 73% LTV / 78% LT / 7.5% bonus
 *           5. DebtManager.supportCollateralToken(iPAXG)  — 75% LTV / 80% LT / 6% bonus
 *           6-7. LendGateway.setReserveId(iwSPYx, iPAXG)  — mirror the new Summer Lend reserves
 *                into the gateway registry
 *
 *         EXECUTION ORDER: after the Lend Owner Safe bundle (ListWspyxPaxgSummerLend3CP), whose
 *         reserve ids txs 6-7 register, and before the Ethereum bundle (RemovePaxgWspyxEthereum3CP),
 *         which stops the PAXG relay this bundle makes redundant. If the reserves are not yet
 *         listed on the fork, the simulation replays the Lend Owner Safe bundle first, so both
 *         JSONs can be generated and rehearsed in one sitting.
 *
 *         NOTE: tx 4 reads the live iwSPYx price (sink rate x SPY/USD); SPY/USD is a 24/5 feed, so
 *         simulate and execute while it is fresh (within 3 days of the last market close).
 *
 * Usage (after ListWspyxPaxgSummerLend3CP has been generated):
 *   forge script scripts/wspyx-paxg/ConfigureWspyxPaxgCashOP3CP.s.sol --rpc-url $OPTIMISM_RPC
 */
contract ConfigureWspyxPaxgCashOP3CP is GnosisHelpers, Test, WspyxPaxgFeedDeployer {
    string constant OUTPUT_PATH = "./output/ConfigureWspyxPaxgCashOP3CP-10.json";
    string constant LEND_BUNDLE_PATH = "./output/ListWspyxPaxgSummerLend3CP-10.json";

    function run() public {
        require(block.chainid == 10, "must be Optimism");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        string memory deployments = readDeploymentFile();
        PriceProviderV2 pp = PriceProviderV2(stdJson.readAddress(deployments, ".addresses.PriceProvider"));
        IDebtManager debtManager = IDebtManager(stdJson.readAddress(deployments, ".addresses.DebtManager"));
        ILendGatewayLike gateway = ILendGatewayLike(stdJson.readAddress(vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/cash-lend.json")), ".lendGateway"));

        require(!debtManager.isCollateralToken(C.IWSPYX), "iwSPYx already a DebtManager collateral");
        require(!debtManager.isCollateralToken(C.IPAXG), "iPAXG already a DebtManager collateral");

        // The Summer Lend reserve ids txs 6-7 register: live if the Lend Owner Safe bundle has
        // executed, otherwise replay it on the fork and take the ids it assigns
        (uint256 iwspyxReserveId, uint256 paxgReserveId) = _reserveIds();

        // Pre-state: iPAXG priced by the relay path, iwSPYx by the sink rate x SPY/USD — both must
        // survive the repoint (iPAXG within tolerance of the new source, iwSPYx byte-identical)
        uint256 paxgPriceBefore = pp.price(C.IPAXG);
        uint256 iwspyxPriceBefore = pp.price(C.IWSPYX);

        _writeBundle(pp, debtManager, gateway, iwspyxReserveId, paxgReserveId);
        console.log("Written: %s", OUTPUT_PATH);

        executeGnosisTransactionBundle(OUTPUT_PATH);
        _assertPostState(pp, debtManager, gateway, iwspyxReserveId, paxgReserveId, paxgPriceBefore, iwspyxPriceBefore);

        console.log("Simulation passed. Prices (6 decimals):");
        console.log("  iPAXG:  %s (sink) -> %s (Chainlink OP)", paxgPriceBefore, pp.price(C.IPAXG));
        console.log("  iwSPYx: %s (unchanged)", pp.price(C.IWSPYX));
        console.log("  gateway reserve ids: iwSPYx %s, iPAXG %s", iwspyxReserveId, paxgReserveId);
    }

    function _writeBundle(PriceProviderV2 pp, IDebtManager debtManager, ILendGatewayLike gateway, uint256 iwspyxReserveId, uint256 paxgReserveId) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = C.IPAXG;
        PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](1);
        configs[0] = PriceProviderV2.Config({
            oracle: C.PAXG_USD_AGGREGATOR,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: uint24(C.PAXG_USD_MAX_STALENESS),
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(C.OPERATING_SAFE));

        txs = _append(txs, address(pp), abi.encodeWithSelector(PriceProviderV2.setTokenConfig.selector, tokens, configs), false);
        txs = _append(txs, C.ORACLE_SINK, abi.encodeCall(IOracleSinkAdminLike.setMaxStaleness, (C.PAXG_MAINNET, 0)), false);
        txs = _append(txs, C.ORACLE_SINK, abi.encodeCall(IOracleSinkAdminLike.clearPrice, (C.PAXG_MAINNET)), false);

        txs = _append(txs, address(debtManager), abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, C.IWSPYX, IDebtManager.CollateralTokenConfig({ ltv: C.DM_IWSPYX_LTV, liquidationThreshold: C.DM_IWSPYX_LIQ_THRESHOLD, liquidationBonus: C.DM_IWSPYX_LIQ_BONUS })), false);
        txs = _append(txs, address(debtManager), abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, C.IPAXG, IDebtManager.CollateralTokenConfig({ ltv: C.DM_IPAXG_LTV, liquidationThreshold: C.DM_IPAXG_LIQ_THRESHOLD, liquidationBonus: C.DM_IPAXG_LIQ_BONUS })), false);

        txs = _append(txs, address(gateway), abi.encodeCall(ILendGatewayLike.setReserveId, (C.IWSPYX, iwspyxReserveId)), false);
        txs = _append(txs, address(gateway), abi.encodeCall(ILendGatewayLike.setReserveId, (C.IPAXG, paxgReserveId)), true);

        vm.createDir("./output", true);
        vm.writeFile(OUTPUT_PATH, txs);
    }

    function _assertPostState(PriceProviderV2 pp, IDebtManager debtManager, ILendGatewayLike gateway, uint256 iwspyxReserveId, uint256 paxgReserveId, uint256 paxgPriceBefore, uint256 iwspyxPriceBefore) internal view {
        // iPAXG on the native Chainlink source, within 2% of the relayed price it replaces
        PriceProviderV2.Config memory config = pp.tokenConfig(C.IPAXG);
        assertEq(config.oracle, C.PAXG_USD_AGGREGATOR, "iPAXG oracle");
        assertTrue(config.isChainlinkType, "iPAXG isChainlinkType");
        assertEq(uint256(config.maxStaleness), C.PAXG_USD_MAX_STALENESS, "iPAXG staleness");
        assertEq(config.baseAsset, address(0), "iPAXG baseAsset");
        assertApproxEqRel(pp.price(C.IPAXG), paxgPriceBefore, 0.02e18, "iPAXG price moved > 2%");
        assertEq(pp.price(C.IWSPYX), iwspyxPriceBefore, "iwSPYx price changed");

        // The sink is fail-closed for PAXG: zero window and no stored price
        assertEq(IOracleSinkAdminLike(C.ORACLE_SINK).maxStaleness(C.PAXG_MAINNET), 0, "sink window not zeroed");
        (bool ok,) = C.ORACLE_SINK.staticcall(abi.encodeCall(IOracleSinkAdminLike.latestRoundData, (C.PAXG_MAINNET)));
        assertFalse(ok, "sink still serves a PAXG price");
        // wSPYx keeps relaying — the iwSPYx feed depends on it
        (ok,) = C.ORACLE_SINK.staticcall(abi.encodeCall(IOracleSinkAdminLike.latestRoundData, (C.WSPYX_MAINNET)));
        assertTrue(ok, "wSPYx sink entry must stay live");

        _assertCollateral(debtManager, C.IWSPYX, C.DM_IWSPYX_LTV, C.DM_IWSPYX_LIQ_THRESHOLD, C.DM_IWSPYX_LIQ_BONUS, "iwSPYx");
        _assertCollateral(debtManager, C.IPAXG, C.DM_IPAXG_LTV, C.DM_IPAXG_LIQ_THRESHOLD, C.DM_IPAXG_LIQ_BONUS, "iPAXG");

        assertEq(gateway.reserveIdOf(C.IWSPYX), iwspyxReserveId, "gateway iwSPYx reserve id");
        assertEq(gateway.reserveIdOf(C.IPAXG), paxgReserveId, "gateway iPAXG reserve id");
    }

    function _assertCollateral(IDebtManager debtManager, address token, uint80 ltv, uint80 liquidationThreshold, uint96 liquidationBonus, string memory label) internal view {
        assertTrue(debtManager.isCollateralToken(token), string.concat(label, ": not a collateral token"));
        IDebtManager.CollateralTokenConfig memory config = debtManager.collateralTokenConfig(token);
        assertEq(uint256(config.ltv), ltv, string.concat(label, ": ltv"));
        assertEq(uint256(config.liquidationThreshold), liquidationThreshold, string.concat(label, ": liquidationThreshold"));
        assertEq(uint256(config.liquidationBonus), liquidationBonus, string.concat(label, ": liquidationBonus"));
    }

    /// @dev The Summer Lend reserve ids for the two iTOKENs; replays the Lend Owner Safe bundle on
    ///      the fork when they are not yet listed live
    function _reserveIds() internal returns (uint256 iwspyxReserveId, uint256 paxgReserveId) {
        ISpokeLike spoke = ISpokeLike(C.CASH_SPOKE);
        iwspyxReserveId = _reserveIdOf(spoke, C.IWSPYX);
        paxgReserveId = _reserveIdOf(spoke, C.IPAXG);
        if (iwspyxReserveId != type(uint256).max && paxgReserveId != type(uint256).max) return (iwspyxReserveId, paxgReserveId);

        require(vm.exists(LEND_BUNDLE_PATH), "reserves not listed; generate ListWspyxPaxgSummerLend3CP first");
        console.log("Reserves not yet listed live; replaying the Lend Owner Safe bundle on the fork");
        // The bundle's addReserve calls read the feeds, so rehearsal-deploy any not yet broadcast
        _deployFeeds(true);
        executeGnosisTransactionBundle(LEND_BUNDLE_PATH);

        iwspyxReserveId = _reserveIdOf(spoke, C.IWSPYX);
        paxgReserveId = _reserveIdOf(spoke, C.IPAXG);
        require(iwspyxReserveId != type(uint256).max && paxgReserveId != type(uint256).max, "lend bundle did not list the reserves");
    }

    function _reserveIdOf(ISpokeLike spoke, address token) internal view returns (uint256) {
        uint256 count = spoke.getReserveCount();
        for (uint256 i; i < count; ++i) {
            if (spoke.getReserve(i).underlying == token) return i;
        }
        return type(uint256).max;
    }

    function _append(string memory txs, address to, bytes memory data, bool isLast) internal pure returns (string memory) {
        return string.concat(txs, _getGnosisTransaction(addressToHex(to), iToHex(data), "0", isLast));
    }
}
