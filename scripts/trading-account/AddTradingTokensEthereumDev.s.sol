// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console2 } from "forge-std/console2.sol";

import { TradingLens } from "../../src/trading-safe/TradingLens.sol";
import { Utils } from "../utils/Utils.sol";
import { TradingAccountProdConfig as Prod } from "./TradingAccountProdConfig.sol";

/**
 * @notice Reconciles the Ethereum dev `TradingLens` with `TradingAccountProdConfig.supportedTokens()`
 *         minus the top-up assets, broadcasting directly from the dev admin EOA.
 * @dev The prod counterpart (`gnosis-txs/AddTradingTokensEth3CP`) emits a Safe bundle because
 *      `MULTISIG_ADMIN_ROLE` there belongs to a multisig; on dev the role sits on `DEV_ADMIN`,
 *      so the calls are broadcast one by one.
 *      Tokens already in the right state are skipped because `addSupportedToken` reverts
 *      `TokenAlreadySupported` and `removeSupportedToken` reverts `TokenNotSupported` rather than
 *      no-opping. wSPYx, PAXG and wQQQx are excluded for the same reason as in the prod bundle: they
 *      are top-up assets, and an asset is never both a top-up and a trading asset. With PRIVATE_KEY
 *      unset the run impersonates DEV_ADMIN, matching `DeployTradingAccountEthereumDevV2`.
 */
contract AddTradingTokensEthereumDev is Utils {
    address private constant DEV_ADMIN = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;
    address private constant WSPYX = 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540;
    address private constant PAXG = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;
    address private constant WQQQX = 0x4C1AE29c159838fC1b224636E28E086EB69101f7;

    function run() external {
        require(block.chainid == 1, "must run on Ethereum");

        address lensProxy = vm.parseJsonAddress(vm.readFile(string.concat(vm.projectRoot(), "/deployments/dev/1/trading-account.json")), ".TradingLens");
        require(lensProxy.code.length > 0, "dev TradingLens not deployed");

        TradingLens lens = TradingLens(lensProxy);
        address[] memory tokens = Prod.supportedTokens();

        uint256 added;
        uint256 removed;
        _startBroadcast();
        for (uint256 i = 0; i < tokens.length; ++i) {
            bool listed = lens.isSupportedToken(tokens[i]);
            if (_isTopUpAsset(tokens[i])) {
                if (listed) {
                    lens.removeSupportedToken(tokens[i]);
                    ++removed;
                }
                continue;
            }
            if (listed) continue;
            lens.addSupportedToken(tokens[i]);
            ++added;
        }
        vm.stopBroadcast();

        for (uint256 i = 0; i < tokens.length; ++i) {
            if (_isTopUpAsset(tokens[i])) {
                require(!lens.isSupportedToken(tokens[i]), "top-up asset listed");
                continue;
            }
            require(lens.isSupportedToken(tokens[i]), "supported token missing");
        }

        console2.log("tokens added:", added);
        console2.log("tokens removed:", removed);
        console2.log("lens total:", lens.getSupportedTokens().length);
    }

    function _isTopUpAsset(address token) private pure returns (bool) {
        return token == WSPYX || token == PAXG || token == WQQQX;
    }

    function _startBroadcast() private {
        uint256 privateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (privateKey == 0) {
            vm.startBroadcast(DEV_ADMIN);
        } else {
            require(vm.addr(privateKey) == DEV_ADMIN, "PRIVATE_KEY is not the dev admin");
            vm.startBroadcast(privateKey);
        }
    }
}
