// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { AddSummerLendCollateral } from "./AddSummerLendCollateral.s.sol";

/**
 * @title RefreshSummerLendOracles
 * @notice Redeploys the entire Summer Lend price feed set (same composition as
 *         AddSummerLendCollateral: shared staleness-checked Chainlink legs, Pyth per-pair feeds,
 *         Veda accountant feeds, Midas composed feeds) and repoints every listed reserve on the
 *         Aave v4 TEST instance at the fresh feeds via `updateReservePriceSource`.
 *
 *         Expects all reserves to already be listed (AddSummerLendCollateral has run) and the
 *         `updateReservePriceSource` selector to already be mapped to SPOKE_ADMIN_ROLE (that
 *         script maps it). Reverts if any asset is not a listed reserve.
 *
 *         The new feed addresses are recorded into `.details.<symbol>.oracle` in
 *         deployments/<env>/<chain>/aave-v4-test.json; a symbol missing from `details` fails the
 *         dry run before anything is broadcast.
 *
 * Usage (simulate by dropping --broadcast; the broadcast wallet must hold SPOKE_ADMIN_ROLE):
 *   source .env && ENV=dev FOUNDRY_PROFILE=aave-deploy forge script \
 *     scripts/aave-v4/RefreshSummerLendOracles.s.sol:RefreshSummerLendOracles \
 *     --rpc-url $OPTIMISM_RPC --broadcast -vvvv
 */
contract RefreshSummerLendOracles is AddSummerLendCollateral {
    function run() public override {
        require(block.chainid == 10, "Must run on Optimism (10)");
        require(isEqualString(vm.envOr("FOUNDRY_PROFILE", string("default")), "aave-deploy"), "Run with FOUNDRY_PROFILE=aave-deploy");

        _loadInstance();

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // One staleness-checked ChainlinkPriceFeed per Chainlink oracle, shared as direct sources
        // and as underlying legs
        address ethUsd = _chainlink(ETH_USD, address(0), CHAINLINK_MAX_STALENESS, false, "ETH / USD");
        address btcUsd = _chainlink(BTC_USD, address(0), CHAINLINK_MAX_STALENESS, false, "BTC / USD");
        address usdcUsd = _chainlink(USDC_USD, address(0), CHAINLINK_MAX_STALENESS, true, "USDC / USD");
        address usdtUsd = _chainlink(USDT_USD, address(0), CHAINLINK_MAX_STALENESS, true, "USDT / USD");
        address frxUsdUsd = _chainlink(FRXUSD_USD, address(0), CHAINLINK_MAX_STALENESS, false, "frxUSD / USD");
        address eurUsd = _chainlink(EUR_USD, address(0), CHAINLINK_MAX_STALENESS, false, "EUR / USD");
        address opUsd = _chainlink(OP_USD, address(0), CHAINLINK_MAX_STALENESS, false, "OP / USD");

        // Pyth-priced assets (ETHFI/USD is reused as sETHFI's underlying below)
        address ethfiUsd = _pyth(ETHFI_USD_PYTH, address(0), "ETHFI / USD");
        _update(ETHFI, ethfiUsd);
        _update(WHYPE, _pyth(WHYPE_USD_PYTH, address(0), "wHYPE / USD"));
        _update(BEHYPE, _pyth(BEHYPE_USD_PYTH, address(0), "beHYPE / USD"));
        _update(EURC, _pyth(EURC_USD_PYTH, address(0), "EURC / USD"));

        // Veda receipt tokens (accountant rate x underlying IAaveV4PriceFeed)
        _update(SETHFI, _veda(SETHFI_TELLER, ethfiUsd, "sETHFI / USD")); // rate is sETHFI/ETHFI
        _update(LIQUID_ETH, _veda(LIQUID_ETH_TELLER, ethUsd, "liquidETH / USD"));
        _update(LIQUID_BTC, _veda(LIQUID_BTC_TELLER, btcUsd, "liquidBTC / USD"));
        _update(LIQUID_USD, _veda(LIQUID_USD_TELLER, usdcUsd, "liquidUSD / USD"));
        _update(EBTC, _veda(EBTC_TELLER, btcUsd, "eBTC / USD"));
        _update(EUSD, _veda(EUSD_TELLER, usdcUsd, "eUSD / USD"));

        // Midas receipt tokens (proxy rate x composed USD leg)
        _update(LIQUID_RESERVE, _chainlink(LIQUID_RESERVE_USD_PROXY, usdcUsd, MIDAS_RATE_MAX_STALENESS, false, "liquidRESERVE / USD"));
        _update(WEEUR, _chainlink(WEEUR_EUR_PROXY, eurUsd, MIDAS_RATE_MAX_STALENESS, false, "weEUR / USD"));
        _update(LIQUID_RWA, _chainlink(LIQUID_RWA_USD_PROXY, usdcUsd, MIDAS_RATE_MAX_STALENESS, false, "liquidRWA / USD"));

        // Reserves sitting directly on the shared staleness-checked Chainlink feeds
        _update(USDT, usdtUsd);
        _update(WETH, ethUsd);
        _update(OP, opUsd);
        _update(FRXUSD, frxUsdUsd);

        // Deploy-time reserves (their ids come from the deployment json, not a token scan)
        address weethUsd = _chainlink(WEETH_ETH_ORACLE, ethUsd, CHAINLINK_MAX_STALENESS, false, "weETH / USD");
        _update(weethReserveId, weethUsd);
        _update(usdcReserveId, usdcUsd);

        vm.stopBroadcast();

        console.log("Done. Refreshed price sources for", spoke.getReserveCount(), "reserves:", jsonPath);
    }

    /// @dev Repoints `token`'s reserve at `feed` and records it under `.details.<symbol>.oracle`
    function _update(address token, address feed) internal {
        _update(_reserveIdOf(token), feed);
    }

    function _update(uint256 reserveId, address feed) internal {
        spoke.updateReservePriceSource(reserveId, feed);
        string memory symbol = IERC20Metadata(spoke.getReserve(reserveId).underlying).symbol();
        vm.writeJson(vm.toString(feed), jsonPath, string.concat(".details.", symbol, ".oracle"));
        console.log("updated price source:", symbol, feed);
    }
}
