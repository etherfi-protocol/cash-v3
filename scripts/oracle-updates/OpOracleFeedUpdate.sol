// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";

/**
 * @title OpOracleFeedUpdate
 * @notice Shared token/feed table for repointing the OP PriceProviderV2 off Pyth (and the old
 *         frxUSD feed) onto official Chainlink aggregator proxies. Used by both the prod 3CP
 *         generator and the dev broadcast script so the two environments cannot drift.
 *
 *         | Token   | Old oracle (type)      | New Chainlink proxy | Feed                       |
 *         |---------|------------------------|---------------------|----------------------------|
 *         | wHYPE   | 0x370F16a9… (pyth)     | 0x961f6a07…         | HYPE / USD, 8 dec          |
 *         | beHYPE  | 0x666a9807… (pyth)     | 0x8792DD89…         | beHYPE / HYPE rate, 18 dec |
 *         | ETHFI   | 0x8A089Ae0… (pyth)     | 0x9A3C9759…         | ETHFI / USD, 18 dec        |
 *         | EURC    | 0x2B132ce0… (pyth)     | 0xDb2A51a5…         | EURC / USD, 8 dec          |
 *         | frxUSD  | 0x8BF42811… (chainlink)| 0x14a2Aa41…         | FRXUSD / USD, 8 dec        |
 *
 *         beHYPE's feed returns the beHYPE/HYPE exchange rate (~1.02e18), NOT a USD price, so its
 *         config sets `baseAsset = wHYPE` and PriceProviderV2 composes rate x HYPE/USD. wHYPE is
 *         ordered BEFORE beHYPE in the array since setTokenConfig validates the base asset's
 *         oracle when beHYPE's entry is written.
 */
abstract contract OpOracleFeedUpdate {
    // tokens (Optimism)
    address internal constant WHYPE   = 0xd83E3d560bA6F05094d9D8B3EB8aaEA571D1864E;
    address internal constant BEHYPE  = 0xA519AfBc91986c0e7501d7e34968FEE51CD901aC;
    address internal constant ETHFI   = 0xe0080d2F853ecDdbd81A643dC10DA075Df26fD3f;
    address internal constant EURC    = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;
    address internal constant FRAXUSD = 0x80Eede496655FB9047dd39d9f418d5483ED600df;

    // new Chainlink aggregator proxies (Optimism)
    address internal constant HYPE_USD_FEED    = 0x961f6a07bFc62F618a4fA737eDe08F23aD6Da67F;
    address internal constant BEHYPE_HYPE_FEED = 0x8792DD897CFB1F6e81dd6C7c4491f97ed79eaD24;
    address internal constant ETHFI_USD_FEED   = 0x9A3C975993354354080d815e313eEEdEb907fF34;
    address internal constant EURC_USD_FEED    = 0xDb2A51a5DD73865F1b0d1c33F99a96E0e7ae742c;
    address internal constant FRXUSD_USD_FEED  = 0x14a2Aa4189Aed564bFB04071c99f308C7ffd5283;

    // same staleness bound every live chainlink-type config on this PriceProvider uses
    uint24 internal constant MAX_STALENESS = 2 days;

    function _updateTokens() internal pure returns (address[] memory tokens) {
        tokens = new address[](5);
        tokens[0] = WHYPE; // must precede BEHYPE (its baseAsset)
        tokens[1] = BEHYPE;
        tokens[2] = ETHFI;
        tokens[3] = EURC;
        tokens[4] = FRAXUSD;
    }

    function _updateConfigs() internal pure returns (PriceProviderV2.Config[] memory configs) {
        configs = new PriceProviderV2.Config[](5);
        configs[0] = _chainlinkConfig(HYPE_USD_FEED, 8, false, address(0));
        configs[1] = _chainlinkConfig(BEHYPE_HYPE_FEED, 18, false, WHYPE);
        configs[2] = _chainlinkConfig(ETHFI_USD_FEED, 18, false, address(0));
        configs[3] = _chainlinkConfig(EURC_USD_FEED, 8, false, address(0));
        // frxUSD keeps its live isStableToken=true (snaps to $1 within 1%)
        configs[4] = _chainlinkConfig(FRXUSD_USD_FEED, 8, true, address(0));
    }

    function _chainlinkConfig(address oracle, uint8 decimals, bool isStable, address baseAsset)
        private
        pure
        returns (PriceProviderV2.Config memory)
    {
        return PriceProviderV2.Config({
            oracle: oracle,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: decimals,
            maxStaleness: MAX_STALENESS,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: isStable,
            baseAsset: baseAsset
        });
    }

    /// @dev Post-update assertions shared by the prod simulation and the dev broadcast. Reverts
    ///      on any mismatch. `pre` are the prices read before the update, in the token order of
    ///      `_updateTokens()`; a >2% move on a feed-provider switch means a wrong feed, not noise.
    function _assertPostState(PriceProviderV2 pp, uint256[5] memory pre) internal view {
        address[] memory tokens = _updateTokens();
        PriceProviderV2.Config[] memory configs = _updateConfigs();

        for (uint256 i = 0; i < tokens.length; i++) {
            require(pp.tokenConfig(tokens[i]).oracle == configs[i].oracle, "oracle not updated");

            uint256 post = pp.price(tokens[i]);
            require(post > 0, "zero price after update");
            uint256 hi = pre[i] > post ? pre[i] : post;
            uint256 lo = pre[i] > post ? post : pre[i];
            require((hi - lo) * 100 / hi < 2, "price moved >2% - wrong feed?");
        }

        require(pp.tokenConfig(BEHYPE).baseAsset == WHYPE, "beHYPE baseAsset != wHYPE");
        require(pp.isBaseAsset(WHYPE), "wHYPE not flagged as base asset");
        require(pp.price(FRAXUSD) == 10 ** pp.decimals(), "frxUSD not snapping to $1");
    }
}
