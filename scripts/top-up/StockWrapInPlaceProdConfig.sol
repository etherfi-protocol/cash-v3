// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";

import { IOFT } from "../../src/interfaces/IOFT.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { StockTopupConfig } from "../stock-topup/StockTopupConfig.sol";

/**
 * @title StockWrapInPlaceProdConfig
 * @author ether.fi
 * @notice Shared configuration for the Ethereum **prod** wrap-in-place rollout: the two
 *         implementations the 3CP upgrades to, and the topup route the WRAPPERS ride once the raw
 *         stocks stop having one of their own.
 *
 *         The change this configures, in one sentence: SPYx / QQQx / TBLLx stop being topup assets
 *         that wrap on the way out (`StockOFTBridgeAdapter` inside `bridge()`), and become raw
 *         tokens that are wrapped **at the TopUp** (`wrapStocks` → `TopUp.wrap`), after which the
 *         WRAPPER — wSPYx / wQQQx / wTBLLx, already an OFT of its own — carries the value onward on
 *         the ordinary sweep-and-bridge rail.
 *
 * @dev THE TWO RAILS ARE MUTUALLY EXCLUSIVE, which is why retiring and registering must ship
 *      together: `wrapStocks` reverts `OnlyUnsupportedTokens` for any token that still has a topup
 *      configuration, and `_validateSweepTokens` reverts `OnlySupportedTokens` for one that does
 *      not. A raw stock between the two calls belongs to neither.
 *
 * @dev WHY THE WRAPPER NEEDS A ROUTE AND CANNOT INHERIT THE RAW ONE. The raw route's adapter is
 *      `StockOFTBridgeAdapter`, which derives `wrapper = IOFT(oftAdapter).token()` and requires
 *      `IERC4626(wrapper).asset() == token` — pointing it at the wrapper itself is unconfigurable
 *      by construction. What the wrapper needs is the plain `EtherFiOFTBridgeAdapter`: the wrapper
 *      IS the OFT token, so nothing has to be deposited on the way out. That is exactly the route
 *      wTBLLx already runs from the 3CP-640 listing (and its dev twin,
 *      `scripts/ConfigureDevTbllxTopUpEth.s.sol`), so this config reproduces those fields rather
 *      than inventing new ones — `maxSlippageInBps = 50` and `additionalData = (oftAdapter, eid)`.
 *
 *      The empty-options caveat that forces `lzReceiveGas` on the RAW route does not apply here:
 *      `EtherFiOFTBridgeAdapter` sends `hex"0003"` and relies on the OFT's ENFORCED options, which
 *      the Backed adapters carry on mainnet (set by the listing bundles). That is not taken on
 *      trust — the 3CP's simulation ends on a live `getBridgeFee` per wrapper, which is the only
 *      thing that can prove the route is quotable at the live executor config.
 *
 * @dev Implementations are deployed with plain `new` (no CREATE3), like every other TopUp impl in
 *      this repo: they are stateless and referenced only by the proxy/beacon slots. The flip side
 *      is nonce-dependent addresses that cannot be known before the broadcast, so they are pinned
 *      here AFTER the fact. **If either is redeployed, update the constant below** — the 3CP
 *      generator and the bytecode verifier both read these, and everything that matters about them
 *      is re-derived from the chain rather than trusted: code presence, the `TopUpV2` immutables
 *      (read back off the deployed code AND cross-checked against what the live beacon runs), and
 *      a full runtime-bytecode compare against this repo. There is deliberately no manifest file —
 *      a hand-maintained copy of two addresses is a second source of truth that can only rot.
 *
 *      These SUPERSEDE `StockWrapProdConfig`'s pair (the redirect-wrapping generation, 3CP-649).
 *      Kept as separate constants rather than an edit to that file so the bundle that has already
 *      been signed keeps naming the code it was reviewed against.
 */
abstract contract StockWrapInPlaceProdConfig is StockTopupConfig {
    using stdJson for string;

    // ---- Deployed implementations (Ethereum mainnet) ----
    //
    // These constants ARE the record: the addresses live here, everything about them is re-derived
    // from the chain by the verifier and the 3CP generator, and Etherscan holds the verified source.
    // Nothing reads a side-file, so there is no second source of truth to drift.

    /// @notice `TopUpFactory` implementation carrying `removeTokenConfig` and `wrapStocks`, on top
    ///         of the `wrapperFor` / `setRedirectWrappers` generation already live from 3CP-649.
    ///         Deployed 2026-08-20, block 25796563,
    ///         tx 0xc16776d5506d958812ba06609f472b7c99e1961cb55f3510cd93291601777596.
    address internal constant WRAP_IN_PLACE_FACTORY_IMPL = 0xF4d1e811A1F5D2E1F8faaD0E0C04D7B3a3f73b3C;

    /// @notice `TopUpV2` implementation carrying `TopUp.wrap` — the call `wrapStocks` makes on each
    ///         TopUp. Built with (WETH, RECOVERY_DISPATCHER), both read back off the deployed code.
    ///         Deployed 2026-08-20, block 25796563,
    ///         tx 0x055616aae67ddc0bbe661591cd76b8ebd4d8b9e7c16317e18b41264513af1dd5.
    address internal constant WRAP_IN_PLACE_TOPUP_IMPL = 0xb71dB550d089d494053e9967401c04AB34B568CC;

    // ---- `TopUpV2` constructor arguments (Ethereum mainnet) ----

    /// @notice WETH — `TopUp`'s immutable, used to wrap native top-ups.
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice `AssetRecoveryDispatcher` — `TopUpV2`'s immutable `DISPATCHER`, the only caller
    ///         allowed to `executeRecovery`. Same value 3CP-649 put on the beacon; the scripts
    ///         cross-check it against the LIVE beacon impl so this rollout cannot silently drop
    ///         the recovery dispatcher.
    address internal constant RECOVERY_DISPATCHER = 0x418e0af7c750Ba5cbffC5C2a8398591755926A29;

    // ---- The wrappers' onward topup route ----

    /// @notice `maxSlippageInBps` for the wrapper routes. Matches the live wTBLLx route from
    ///         3CP-640 and every other OFT route on this factory. Dust absorption for the OFT's
    ///         shared-decimals truncation, not price slippage; must be nonzero or the route cannot
    ///         be quoted, and `TopUpFactory` caps it at `MAX_ALLOWED_SLIPPAGE`.
    uint96 internal constant WRAPPER_MAX_SLIPPAGE_BPS = 50;

    /// @notice Key the plain OFT adapter is recorded under in deployments/{ENV}/1/deployments.json.
    string internal constant OFT_ADAPTER_DEPLOYMENT_KEY = "EtherFiOFTBridgeAdapter";

    /// @dev `additionalData` the plain OFT adapter decodes: (oftAdapter, destEid). No lzReceive gas
    ///      field — that adapter sends `hex"0003"` and leans on the OFT's enforced options.
    function _wrapperAdditionalData(address oftAdapter) internal pure returns (bytes memory) {
        return abi.encode(oftAdapter, OP_EID);
    }

    /// @dev The (wrapper, chain 10) config written to the TopUpFactory for one asset.
    function _wrapperTokenConfig(address bridgeAdapter, address recipientOnOptimism, address oftAdapter) internal pure returns (TopUpFactory.TokenConfig memory) {
        return TopUpFactory.TokenConfig({
            bridgeAdapter: bridgeAdapter,
            recipientOnDestChain: recipientOnOptimism,
            maxSlippageInBps: WRAPPER_MAX_SLIPPAGE_BPS,
            additionalData: _wrapperAdditionalData(oftAdapter)
        });
    }

    /// @dev The plain OFT adapter recorded for the current ENV on Ethereum.
    function _oftBridgeAdapter() internal view returns (address) {
        string memory deployments = readTopUpSourceDeployment();
        require(vm.keyExistsJson(deployments, string.concat(".addresses.", OFT_ADAPTER_DEPLOYMENT_KEY)), "EtherFiOFTBridgeAdapter missing from deployments.json");
        return deployments.readAddress(string.concat(".addresses.", OFT_ADAPTER_DEPLOYMENT_KEY));
    }

    /**
     * @dev Asserts the wrapper half of every asset entry is a coherent OFT route, off-line: the
     *      configured OFT adapter locks the WRAPPER (not the raw stock) and its OP peer is the
     *      iTOKEN the topup is meant to arrive as. `_assertAssetWiring()` in `StockTopupConfig`
     *      already covers both plus the ERC-4626 pairing; this adds the one thing that is specific
     *      to sending the wrapper directly — that the token being configured is the OFT's own
     *      token, which is what makes the plain adapter (no deposit) the right one.
     */
    function _assertWrapperRouteWiring() internal view {
        StockTopupAsset[] memory assets = _assets();
        for (uint256 i = 0; i < assets.length; ++i) {
            require(IOFT(assets[i].oftAdapter).token() == assets[i].wrapper, string.concat(assets[i].symbol, ": OFT adapter does not lock the wrapper being configured"));
        }
    }
}
