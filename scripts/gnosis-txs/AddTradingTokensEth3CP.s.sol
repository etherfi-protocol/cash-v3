// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { TradingLens } from "../../src/trading-safe/TradingLens.sol";
import { TradingAccountCreate3, TradingAccountProdConfig as C } from "../trading-account/TradingAccountProdConfig.sol";
import { Utils } from "../utils/Utils.sol";
import { TradingAccountGnosisHelpers } from "./TradingAccountGnosisHelpers.sol";

/**
 * @notice Generates the Ethereum 3CP JSON that brings the prod `TradingLens` allowlist up to
 *         `TradingAccountProdConfig.supportedTokens()` — today the wrapped xStocks already live on
 *         the dev lens. One tx per missing token from the OperatingSafe (holds
 *         TRADING_LENS_ADMIN_ROLE):
 *
 *           TradingLens.addSupportedToken(token)
 *
 *         Split out from `ConfigureTradingAccountEthereum` so growing the token list doesn't require
 *         re-running that bundle's one-shot proxy upgrades and role grants. Already-supported tokens
 *         are filtered out up front because `addSupportedToken` reverts `TokenAlreadySupported`
 *         rather than no-opping, which would take the whole Safe transaction down with it. wSPYx and
 *         PAXG are skipped as OP-only assets (see below). The bundle is fork-simulated and the
 *         resulting allowlist asserted before the JSON is trusted.
 *
 * Usage:
 *   source .env && forge script scripts/gnosis-txs/AddTradingTokensEth3CP.s.sol --rpc-url $MAINNET_RPC
 */
contract AddTradingTokensEth3CP is TradingAccountGnosisHelpers, Utils, TradingAccountCreate3 {
    /**
     * @dev wSPYx and PAXG are still in `supportedTokens()` but must not reach the mainnet lens: their
     *      OP iTOKENs sit on the user's own safe and Enso routes them on Optimism in both directions,
     *      so no mainnet TradingSafe ever holds them (cash-be #7340). They are absent from the dev
     *      lens for the same reason. Skipped here rather than deleted from the shared config, which
     *      is being cleaned up separately; once that lands this filter simply stops matching.
     */
    address private constant WSPYX = 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540;
    address private constant PAXG = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;

    function run() external {
        require(block.chainid == 1, "must run on Ethereum");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        address tradingLens = _predict(C.SALT_TRADING_LENS_PROXY);
        require(tradingLens.code.length > 0, "TradingLens not deployed");

        address[] memory pending = _pendingTokens(tradingLens);
        require(pending.length > 0, "no tokens to add");

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(C.OPERATING_SAFE));
        for (uint256 i = 0; i < pending.length; ++i) {
            bytes memory data = abi.encodeWithSelector(TradingLens.addSupportedToken.selector, pending[i]);
            bool isLast = i == pending.length - 1;
            txs = string.concat(txs, _getGnosisTransaction(addressToHex(tradingLens), iToHex(data), "0", isLast));
        }

        vm.createDir("./output", true);
        string memory path = "./output/AddTradingTokens3CP-eth-1.json";
        vm.writeFile(path, txs);
        console.log("Written: %s", path);

        executeGnosisTransactionBundle(path);

        address[] memory tokens = C.supportedTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (_isOpOnly(tokens[i])) {
                require(!TradingLens(tradingLens).isSupportedToken(tokens[i]), "OP-only token listed");
                continue;
            }
            require(TradingLens(tradingLens).isSupportedToken(tokens[i]), "supported token missing");
        }

        console.log("Simulation passed. Tokens added: %s", pending.length);
        console.log("Lens allowlist: %s", TradingLens(tradingLens).getSupportedTokens().length);
    }

    /// @dev Two passes because the pending count isn't known until the lens has been read.
    function _pendingTokens(address tradingLens) private view returns (address[] memory pending) {
        address[] memory tokens = C.supportedTokens();
        uint256 count;
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (_isPending(tradingLens, tokens[i])) ++count;
        }

        pending = new address[](count);
        uint256 j;
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (_isPending(tradingLens, tokens[i])) pending[j++] = tokens[i];
        }
    }

    function _isPending(address tradingLens, address token) private view returns (bool) {
        return !_isOpOnly(token) && !TradingLens(tradingLens).isSupportedToken(token);
    }

    function _isOpOnly(address token) private pure returns (bool) {
        return token == WSPYX || token == PAXG;
    }
}
