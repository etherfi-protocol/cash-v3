// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @notice Generates the OP 3CP JSON that widens PriceProviderV2 maxStaleness on the three
 *         24/5 xStock USD legs (SPYx / QQQx / TBLLx) from 78 hours to 5 days. Those keys
 *         are the base assets for iwSPYx / iwQQQx / iwTBLLx cash collateral. The iTOKEN
 *         rows are left alone (non-Chainlink OracleSink reads, maxStaleness already 0).
 *
 *         Single tx from the OperatingSafe (PRICE_PROVIDER_ADMIN_ROLE):
 *
 *           PriceProviderV2.setTokenConfig([SPYx, QQQx, TBLLx], configs)
 *
 *         Every field except maxStaleness is copied from the live on-chain config. The
 *         bundle is fork-simulated and the post-state asserted before the JSON is trusted.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/gnosis-txs/UpdateXStockOracleStalenessOP3CP.s.sol \
 *     --rpc-url $OPTIMISM_RPC -vvvv
 */
contract UpdateXStockOracleStalenessOP3CP is GnosisHelpers, Utils {
    address constant OPERATING_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    // PriceProviderV2 address keys — mainnet raw xStocks, used only as config keys on OP
    address constant SPYX = 0x90A2a4c76b5D8c0bc892A69EA28Aa775a8f2dD48;
    address constant QQQX = 0xa753A7395cAe905Cd615Da0B82A53E0560f250af;
    address constant TBLLX = 0x4cbf89ED7Bb30b8a860fa86d3c96E9c72931299b;

    // DebtManager collateral tokens composed on the legs above
    address constant IWSPYX = 0xc1e636Aae7d6B46229FC2C362d562610519e8D7c;
    address constant IWQQQX = 0x3c99d3a81b27583B2E26dbd387C10411f2763516;
    address constant IWTBLLX = 0x5F8b2D2b97aD4d63188f44965778F6004D5bc387;

    uint24 constant OLD_MAX_STALENESS = 78 hours;
    uint24 constant NEW_MAX_STALENESS = 5 days;

    function run() public {
        require(block.chainid == 10, "must be Optimism");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        string memory deployments = readDeploymentFile();
        PriceProviderV2 pp = PriceProviderV2(stdJson.readAddress(deployments, ".addresses.PriceProvider"));
        IDebtManager dm = IDebtManager(stdJson.readAddress(deployments, ".addresses.DebtManager"));
        require(address(pp) != address(0), "PriceProvider not found in deployments.json");

        address[] memory tokens = _baseTokens();
        PriceProviderV2.Config[] memory beforeCfgs = new PriceProviderV2.Config[](3);
        PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](3);

        for (uint256 i = 0; i < tokens.length; i++) {
            PriceProviderV2.Config memory cfg = pp.tokenConfig(tokens[i]);
            require(cfg.oracle != address(0), "base config missing");
            require(cfg.isChainlinkType, "expected chainlink-type base");
            require(cfg.maxStaleness == OLD_MAX_STALENESS, "unexpected current staleness");
            require(cfg.baseAsset == address(0), "base must be USD-quoted");
            beforeCfgs[i] = cfg;

            cfg.maxStaleness = NEW_MAX_STALENESS;
            configs[i] = cfg;
        }

        require(dm.isCollateralToken(IWSPYX) && dm.isCollateralToken(IWQQQX) && dm.isCollateralToken(IWTBLLX), "xStock not collateral");

        string memory txs = _getGnosisHeader("10", addressToHex(OPERATING_SAFE));
        bytes memory callData = abi.encodeWithSelector(PriceProviderV2.setTokenConfig.selector, tokens, configs);
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(pp)), iToHex(callData), "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/UpdateXStockOracleStaleness3CP-op-10.json";
        vm.writeFile(path, txs);
        console.log("Written: %s", path);

        executeGnosisTransactionBundle(path);
        _assertPostState(pp, dm, tokens, beforeCfgs);

        console.log("Simulation passed. Prices (6 decimals):");
        console.log("  SPYx / iwSPYx:", pp.price(SPYX), pp.price(IWSPYX));
        console.log("  QQQx / iwQQQx:", pp.price(QQQX), pp.price(IWQQQX));
        console.log("  TBLLx / iwTBLLx:", pp.price(TBLLX), pp.price(IWTBLLX));
    }

    function _baseTokens() internal pure returns (address[] memory tokens) {
        tokens = new address[](3);
        tokens[0] = SPYX;
        tokens[1] = QQQX;
        tokens[2] = TBLLX;
    }

    function _assertPostState(
        PriceProviderV2 pp,
        IDebtManager dm,
        address[] memory tokens,
        PriceProviderV2.Config[] memory beforeCfgs
    ) internal view {
        for (uint256 i = 0; i < tokens.length; i++) {
            PriceProviderV2.Config memory afterCfg = pp.tokenConfig(tokens[i]);
            require(afterCfg.maxStaleness == NEW_MAX_STALENESS, "staleness not updated");
            require(afterCfg.oracle == beforeCfgs[i].oracle, "oracle changed");
            require(
                keccak256(afterCfg.priceFunctionCalldata) == keccak256(beforeCfgs[i].priceFunctionCalldata),
                "calldata changed"
            );
            require(afterCfg.isChainlinkType == beforeCfgs[i].isChainlinkType, "type changed");
            require(afterCfg.oraclePriceDecimals == beforeCfgs[i].oraclePriceDecimals, "decimals changed");
            require(uint8(afterCfg.dataType) == uint8(beforeCfgs[i].dataType), "dataType changed");
            require(afterCfg.isStableToken == beforeCfgs[i].isStableToken, "stable flag changed");
            require(afterCfg.baseAsset == beforeCfgs[i].baseAsset, "baseAsset changed");
            require(pp.price(tokens[i]) > 0, "zero base price after update");
        }

        require(pp.price(IWSPYX) > 0, "zero iwSPYx price");
        require(pp.price(IWQQQX) > 0, "zero iwQQQx price");
        require(pp.price(IWTBLLX) > 0, "zero iwTBLLx price");

        require(dm.isCollateralToken(IWSPYX) && dm.isCollateralToken(IWQQQX) && dm.isCollateralToken(IWTBLLX), "collateral unset");
    }
}
