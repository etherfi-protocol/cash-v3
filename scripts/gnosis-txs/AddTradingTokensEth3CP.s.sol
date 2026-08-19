// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { TradingLens } from "../../src/trading-safe/TradingLens.sol";
import { TradingAccountCreate3, TradingAccountProdConfig as C } from "../trading-account/TradingAccountProdConfig.sol";
import { Utils } from "../utils/Utils.sol";
import { TradingAccountGnosisHelpers } from "./TradingAccountGnosisHelpers.sol";

/**
 * @notice Generates the Ethereum 3CP JSON that reconciles the prod `TradingLens` allowlist with
 *         `TradingAccountProdConfig.supportedTokens()` minus the top-up assets. From the
 *         OperatingSafe (holds MULTISIG_ADMIN_ROLE), one tx per token that is out of sync:
 *
 *           TradingLens.addSupportedToken(token)     — config token missing from the lens
 *           TradingLens.removeSupportedToken(token)  — top-up asset still on the lens
 *
 *         Split out from `ConfigureTradingAccountEthereum` so growing the token list doesn't require
 *         re-running that bundle's one-shot proxy upgrades and role grants. Both directions are
 *         filtered against live lens state up front: `addSupportedToken` reverts
 *         `TokenAlreadySupported` and `removeSupportedToken` reverts `TokenNotSupported` rather than
 *         no-opping, and either would take the whole Safe transaction down with it. The bundle is
 *         fork-simulated and the resulting allowlist asserted before the JSON is trusted.
 *
 * Usage:
 *   source .env && forge script scripts/gnosis-txs/AddTradingTokensEth3CP.s.sol --rpc-url $MAINNET_RPC
 */
contract AddTradingTokensEth3CP is TradingAccountGnosisHelpers, Utils, TradingAccountCreate3 {
    /**
     * @dev Top-up assets. These are still in `supportedTokens()` but must not sit on the mainnet
     *      trading lens — an asset is either a top-up asset or a trading asset, never both. wSPYx and
     *      PAXG never reached the lens; wQQQx did, seeded by 3CP-611 before it was listed for top-up,
     *      so it is removed here. Their OP iTOKENs sit on the user's own safe and Enso routes them on
     *      Optimism in both directions, so no mainnet TradingSafe ever holds them (cash-be #7340).
     *      They are absent from the dev lens for the same reason. Filtered here rather than deleted
     *      from the shared config, which is being cleaned up separately; once that lands this filter
     *      simply stops matching.
     */
    address private constant WSPYX = 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540;
    address private constant PAXG = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;
    address private constant WQQQX = 0x4C1AE29c159838fC1b224636E28E086EB69101f7;

    function run() external {
        require(block.chainid == 1, "must run on Ethereum");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        address tradingLens = _predict(C.SALT_TRADING_LENS_PROXY);
        require(tradingLens.code.length > 0, "TradingLens not deployed");

        address[] memory pending = _pendingTokens(tradingLens);
        address[] memory stale = _staleTokens(tradingLens);
        uint256 total = pending.length + stale.length;
        require(total > 0, "lens already in sync");

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(C.OPERATING_SAFE));
        uint256 emitted;
        for (uint256 i = 0; i < pending.length; ++i) {
            bytes memory data = abi.encodeWithSelector(TradingLens.addSupportedToken.selector, pending[i]);
            txs = string.concat(txs, _getGnosisTransaction(addressToHex(tradingLens), iToHex(data), "0", ++emitted == total));
        }
        for (uint256 i = 0; i < stale.length; ++i) {
            bytes memory data = abi.encodeWithSelector(TradingLens.removeSupportedToken.selector, stale[i]);
            txs = string.concat(txs, _getGnosisTransaction(addressToHex(tradingLens), iToHex(data), "0", ++emitted == total));
        }

        vm.createDir("./output", true);
        string memory path = "./output/AddTradingTokens3CP-eth-1.json";
        vm.writeFile(path, txs);
        console.log("Written: %s", path);

        executeGnosisTransactionBundle(path);

        address[] memory tokens = C.supportedTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (_isTopUpAsset(tokens[i])) {
                require(!TradingLens(tradingLens).isSupportedToken(tokens[i]), "top-up asset listed");
                continue;
            }
            require(TradingLens(tradingLens).isSupportedToken(tokens[i]), "supported token missing");
        }

        console.log("Simulation passed. Tokens added: %s", pending.length);
        console.log("Tokens removed: %s", stale.length);
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

    /// @dev Top-up assets the lens still lists, so they can be removed in the same bundle.
    function _staleTokens(address tradingLens) private view returns (address[] memory stale) {
        address[] memory tokens = C.supportedTokens();
        uint256 count;
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (_isStale(tradingLens, tokens[i])) ++count;
        }

        stale = new address[](count);
        uint256 j;
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (_isStale(tradingLens, tokens[i])) stale[j++] = tokens[i];
        }
    }

    function _isPending(address tradingLens, address token) private view returns (bool) {
        return !_isTopUpAsset(token) && !TradingLens(tradingLens).isSupportedToken(token);
    }

    function _isStale(address tradingLens, address token) private view returns (bool) {
        return _isTopUpAsset(token) && TradingLens(tradingLens).isSupportedToken(token);
    }

    function _isTopUpAsset(address token) private pure returns (bool) {
        return token == WSPYX || token == PAXG || token == WQQQX;
    }
}
