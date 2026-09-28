// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { IAaveOracleLike, ILendGatewayLike, ISpokeLike } from "../wspyx-paxg/WspyxPaxgProdConfig.sol";
import { PaxgyCashProd as C } from "./PaxgyCashProdConfig.sol";

/**
 * @title ConfigurePaxgyCashOP3CP
 * @notice Generates the OPERATING SAFE (0xA6cf…AAC4) Optimism bundle that makes iPAXGy a Cash collateral:
 *
 *           1. PriceProviderV2.setTokenConfig([XAU, iPAXGy]) — XAU / USD base entry, then iPAXGy as
 *              PAXGy / Gold rate x XAU / USD
 *           2. DebtManager.supportCollateralToken(iPAXGy)   — 67% LTV / 75% LT / 10% bonus
 *           3. LendGateway.setReserveId(iPAXGy, 24)         — the Summer Lend reserve listed by 3CP 698
 *
 *         Must run after 698 has executed (the gateway checks the reserve exists).
 *
 * Usage:
 *   forge script scripts/paxgy/ConfigurePaxgyCashOP3CP.s.sol --rpc-url $OPTIMISM_RPC
 */
contract ConfigurePaxgyCashOP3CP is GnosisHelpers, Utils, Test {
    string constant OUTPUT_PATH = "./output/ConfigurePaxgyCashOP3CP-10.json";

    function run() public {
        require(block.chainid == 10, "must be Optimism");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        string memory deployments = readDeploymentFile();
        PriceProviderV2 pp = PriceProviderV2(stdJson.readAddress(deployments, ".addresses.PriceProvider"));
        IDebtManager debtManager = IDebtManager(stdJson.readAddress(deployments, ".addresses.DebtManager"));
        ILendGatewayLike gateway = ILendGatewayLike(stdJson.readAddress(vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/cash-lend.json")), ".lendGateway"));

        _assertPreState(pp, debtManager);
        _writeBundle(pp, debtManager, gateway);
        console.log("Written: %s", OUTPUT_PATH);

        executeGnosisTransactionBundle(OUTPUT_PATH);
        _assertPostState(pp, debtManager, gateway);

        console.log("Simulation passed.");
        console.log("  XAU / USD (6 dec):  %s", pp.price(C.XAU_DENOMINATION));
        console.log("  iPAXGy (6 dec):     %s", pp.price(C.IPAXGY));
        console.log("  Summer Lend (8 dec): %s", IAaveOracleLike(C.AAVE_ORACLE).getReservePrice(C.LEND_RESERVE_ID));
    }

    function _assertPreState(PriceProviderV2 pp, IDebtManager debtManager) internal view {
        require(!debtManager.isCollateralToken(C.IPAXGY), "iPAXGy already a DebtManager collateral");
        require(pp.tokenConfig(C.IPAXGY).oracle == address(0), "iPAXGy already priced by PriceProviderV2");
        require(pp.tokenConfig(C.XAU_DENOMINATION).oracle == address(0), "XAU base entry already set: drop it from the bundle");

        require(ISpokeLike(C.CASH_SPOKE).getReserve(C.LEND_RESERVE_ID).underlying == C.IPAXGY, "Summer Lend reserve 24 is not iPAXGy");
        require(IAaveOracleLike(C.AAVE_ORACLE).getReserveSource(C.LEND_RESERVE_ID) == C.LEND_PAXGY_FEED, "reserve 24 price source");
    }

    function _writeBundle(PriceProviderV2 pp, IDebtManager debtManager, ILendGatewayLike gateway) internal {
        address[] memory tokens = new address[](2);
        PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](2);
        // The base entry must precede iPAXGy: setTokenConfig checks the base oracle is already set
        tokens[0] = C.XAU_DENOMINATION;
        configs[0] = _xauConfig();
        tokens[1] = C.IPAXGY;
        configs[1] = _paxgyConfig();

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(C.OPERATING_SAFE));
        txs = _append(txs, address(pp), abi.encodeWithSelector(PriceProviderV2.setTokenConfig.selector, tokens, configs), false);
        txs = _append(txs, address(debtManager), abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, C.IPAXGY, _dmConfig()), false);
        txs = _append(txs, address(gateway), abi.encodeCall(ILendGatewayLike.setReserveId, (C.IPAXGY, C.LEND_RESERVE_ID)), true);

        vm.createDir("./output", true);
        vm.writeFile(OUTPUT_PATH, txs);
    }

    function _assertPostState(PriceProviderV2 pp, IDebtManager debtManager, ILendGatewayLike gateway) internal view {
        _assertConfig(pp.tokenConfig(C.XAU_DENOMINATION), _xauConfig(), "XAU");
        _assertConfig(pp.tokenConfig(C.IPAXGY), _paxgyConfig(), "iPAXGy");
        assertTrue(pp.isBaseAsset(C.XAU_DENOMINATION), "XAU not flagged as base asset");
        assertGt(pp.price(C.XAU_DENOMINATION), 1000e6, "XAU / USD implausible");

        // Cash and Summer Lend must value iPAXGy alike (6 vs 8 decimals)
        uint256 lendPrice = IAaveOracleLike(C.AAVE_ORACLE).getReservePrice(C.LEND_RESERVE_ID);
        assertApproxEqRel(pp.price(C.IPAXGY) * 100, lendPrice, 0.001e18, "iPAXGy: cash vs Summer Lend price > 0.1% apart");

        assertTrue(debtManager.isCollateralToken(C.IPAXGY), "iPAXGy not a collateral token");
        assertFalse(debtManager.isBorrowToken(C.IPAXGY), "iPAXGy must stay collateral-only");
        IDebtManager.CollateralTokenConfig memory dm = debtManager.collateralTokenConfig(C.IPAXGY);
        assertEq(uint256(dm.ltv), uint256(C.DM_LTV), "ltv");
        assertEq(uint256(dm.liquidationThreshold), uint256(C.DM_LIQ_THRESHOLD), "liquidationThreshold");
        assertEq(uint256(dm.liquidationBonus), uint256(C.DM_LIQ_BONUS), "liquidationBonus");

        assertEq(gateway.reserveIdOf(C.IPAXGY), C.LEND_RESERVE_ID, "gateway reserve id");
    }

    function _assertConfig(PriceProviderV2.Config memory got, PriceProviderV2.Config memory want, string memory label) internal pure {
        assertEq(got.oracle, want.oracle, string.concat(label, ": oracle"));
        assertEq(got.priceFunctionCalldata, want.priceFunctionCalldata, string.concat(label, ": priceFunctionCalldata"));
        assertEq(got.isChainlinkType, want.isChainlinkType, string.concat(label, ": isChainlinkType"));
        assertEq(uint256(got.oraclePriceDecimals), uint256(want.oraclePriceDecimals), string.concat(label, ": oraclePriceDecimals"));
        assertEq(uint256(got.maxStaleness), uint256(want.maxStaleness), string.concat(label, ": maxStaleness"));
        assertEq(uint256(got.dataType), uint256(want.dataType), string.concat(label, ": dataType"));
        assertEq(got.isStableToken, want.isStableToken, string.concat(label, ": isStableToken"));
        assertEq(got.baseAsset, want.baseAsset, string.concat(label, ": baseAsset"));
    }

    function _xauConfig() internal pure returns (PriceProviderV2.Config memory) {
        return PriceProviderV2.Config({
            oracle: C.XAU_USD_AGGREGATOR,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: C.XAU_USD_MAX_STALENESS,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });
    }

    function _paxgyConfig() internal pure returns (PriceProviderV2.Config memory) {
        return PriceProviderV2.Config({
            oracle: C.PAXGY_XAU_RATE_FEED,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: 18,
            maxStaleness: C.PAXGY_XAU_MAX_STALENESS,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: C.XAU_DENOMINATION
        });
    }

    function _dmConfig() internal pure returns (IDebtManager.CollateralTokenConfig memory) {
        return IDebtManager.CollateralTokenConfig({ ltv: C.DM_LTV, liquidationThreshold: C.DM_LIQ_THRESHOLD, liquidationBonus: C.DM_LIQ_BONUS });
    }

    function _append(string memory txs, address to, bytes memory data, bool isLast) internal pure returns (string memory) {
        return string.concat(txs, _getGnosisTransaction(addressToHex(to), iToHex(data), "0", isLast));
    }
}
