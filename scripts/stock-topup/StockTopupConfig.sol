// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { IOFT } from "../../src/interfaces/IOFT.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { IOAppPeers } from "../utils/IOAppPeers.sol";
import { StockSharedConfig } from "../utils/StockSharedConfig.sol";

/**
 * @title StockTopupConfig
 * @author ether.fi
 * @notice Shared configuration for the Ethereum-side stock topup rail: a raw Backed stock
 *         (SPYx / QQQx / TBLLx) deposited into a TopUp is wrapped into its ERC-4626 wrapper
 *         (wSPYx / wQQQx / wTBLLx) and OFT-sent to the TopUpDest on Optimism, where it lands as
 *         the matching iTOKEN ShadowOFT.
 *
 *         Holds the CREATE3 salt for `StockOFTBridgeAdapter` (env-prefixed so dev and prod land
 *         at distinct deterministic addresses), the asset set, and the bridge parameters baked
 *         into the TopUpFactory token config.
 *
 * @dev The wrapper is NEVER passed to the adapter: it derives it as `IOFT(oftAdapter).token()`
 *      and requires `IERC4626(wrapper).asset() == token`. `_assertAssetWiring()` asserts that
 *      same chain off-line, plus the LayerZero peering, so a wrong constant fails before
 *      anything is broadcast or bundled.
 *
 * @dev One adapter serves every asset. It is stateless and unowned — `TopUpFactory.bridge()`
 *      only ever delegatecalls it — and the per-asset OFT adapter travels in the token config's
 *      `additionalData`, so adding an asset is a `setTokenConfig` call and never a redeploy.
 */
abstract contract StockTopupConfig is StockSharedConfig {
    using stdJson for string;

    // ---- CREATE3 salts (env-prefixed) ----

    string internal constant DEV_SALT_ADAPTER = "Dev.StockTopup.StockOFTBridgeAdapter";
    string internal constant PROD_SALT_ADAPTER = "Prod.StockTopup.StockOFTBridgeAdapter";

    /// @notice Key the adapter address is recorded under in deployments/{ENV}/1/deployments.json.
    string internal constant ADAPTER_DEPLOYMENT_KEY = "StockOFTBridgeAdapter";

    /**
     * @notice One raw-stock topup route: everything needed to wrap on Ethereum and OFT-send to
     *         Optimism.
     * @param stock The raw Backed stock a user tops up with (rebasing, shares-based).
     * @param wrapper The ERC-4626 wrapper the stock is deposited into before the send.
     * @param oftAdapter Backed's LayerZero OFTAdapter that locks the wrapper on Ethereum.
     * @param iToken The OP-side ShadowOFT the send mints (already listed on the cash side).
     * @param symbol The raw stock's symbol, for logs and bundle documentation.
     */
    struct StockTopupAsset {
        address stock;
        address wrapper;
        address oftAdapter;
        address iToken;
        string symbol;
    }

    // ---- Asset set (Ethereum mainnet; identical between dev and prod) ----

    /// @notice Raw SPYx. Wrapper wSPYx, adapter verified as its OFT lock on-chain.
    address internal constant SPYX = 0x90A2a4c76b5D8c0bc892A69EA28Aa775a8f2dD48;
    address internal constant WSPYX = 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540;
    address internal constant WSPYX_OFT_ADAPTER = 0xB3b3412E3D367D26B6f37ddf74eECb7de8827318;
    address internal constant IWSPYX_OPTIMISM = 0xc1e636Aae7d6B46229FC2C362d562610519e8D7c;

    /// @notice Raw QQQx. Same address book as the iwQQQx collateral listing.
    address internal constant QQQX = 0xa753A7395cAe905Cd615Da0B82A53E0560f250af;
    address internal constant WQQQX = 0x4C1AE29c159838fC1b224636E28E086EB69101f7;
    address internal constant WQQQX_OFT_ADAPTER = 0xD33685E92f079E05F7e25a5F14e68e44eD53bBC5;
    address internal constant IWQQQX_OPTIMISM = 0x3c99d3a81b27583B2E26dbd387C10411f2763516;

    /// @notice Raw TBLLx. Adapter deployed by the 3CP-640 Ethereum listing bundle.
    address internal constant TBLLX = 0x4cbf89ED7Bb30b8a860fa86d3c96E9c72931299b;
    address internal constant WTBLLX = 0x461b25b99606Fe169D6F0dD6816650eF6536403E;
    address internal constant WTBLLX_OFT_ADAPTER = 0x8C03Bba46607F0e1bd51c6860293040f0477A1D0;
    address internal constant IWTBLLX_OPTIMISM = 0x5F8b2D2b97aD4d63188f44965778F6004D5bc387;

    // ---- Chain / bridge constants ----
    //
    // `OP_EID` (destination of every stock topup), `OP_CHAIN_ID` (the `destChainId` key of the
    // TopUpFactory token config) and `SAFE` come from StockSharedConfig.

    /// @notice Executor gas limit for the destination lzReceive (ShadowOFT mint) call.
    /// @dev The Backed OFTs have NO enforced SEND options, so empty options make the executor
    ///      fee library revert with `Executor_NoOptions` — the send must carry this explicitly.
    ///      Value reused from the withdraw direction (`StockWithdrawConfig.LZ_RECEIVE_GAS_LIMIT`),
    ///      where the mainnet OFTAdapter credit measured ~194k and the live tx burned 210k end
    ///      to end; 300k leaves headroom over the endpoint wrapper + mint on OP.
    uint128 internal constant LZ_RECEIVE_GAS = 300_000;

    /// @notice Slippage floor applied to the WRAPPED SHARES, in basis points.
    /// @dev This is dust absorption, not price slippage: the lock/mint OFT takes no fee, the
    ///      only loss is the OFT's shared-decimals truncation (<= 1e12 wei of an 18-decimal
    ///      wrapper, i.e. ~1e-6 shares). At 0 bps that dust reverts the send — the route cannot
    ///      even be quoted. 100 bps keeps topups down to ~1e-4 shares bridgeable, and stays
    ///      inside `TopUpFactory.MAX_ALLOWED_SLIPPAGE` (200).
    uint96 internal constant MAX_SLIPPAGE_BPS = 100;

    // ---- Asset set ----

    /// @dev Every script iterates this, so adding an asset here propagates to the deploy-time
    ///      wiring assertions, the token-config bundle and the verification pass at once.
    function _assets() internal pure returns (StockTopupAsset[] memory assets) {
        assets = new StockTopupAsset[](3);
        assets[0] = StockTopupAsset({ stock: SPYX, wrapper: WSPYX, oftAdapter: WSPYX_OFT_ADAPTER, iToken: IWSPYX_OPTIMISM, symbol: "SPYx" });
        assets[1] = StockTopupAsset({ stock: QQQX, wrapper: WQQQX, oftAdapter: WQQQX_OFT_ADAPTER, iToken: IWQQQX_OPTIMISM, symbol: "QQQx" });
        assets[2] = StockTopupAsset({ stock: TBLLX, wrapper: WTBLLX, oftAdapter: WTBLLX_OFT_ADAPTER, iToken: IWTBLLX_OPTIMISM, symbol: "TBLLx" });
    }

    // ---- Env-derived selectors (`_isDev` lives in StockSharedConfig) ----

    function _adapterSalt() internal view returns (string memory) {
        return _isDev() ? DEV_SALT_ADAPTER : PROD_SALT_ADAPTER;
    }

    /// @dev Deterministic address of the `StockOFTBridgeAdapter` for the current ENV.
    function _adapterAddress() internal view returns (address) {
        return _predictAddress(_adapterSalt());
    }

    // ---- Token config ----

    /// @dev `additionalData` the adapter decodes: (oftAdapter, destEid, lzReceiveGas).
    function _additionalData(address oftAdapter) internal pure returns (bytes memory) {
        return abi.encode(oftAdapter, OP_EID, LZ_RECEIVE_GAS);
    }

    /// @dev The (stock, chain 10) config written to the TopUpFactory for one asset.
    function _tokenConfig(address bridgeAdapter, address recipientOnOptimism, address oftAdapter) internal pure returns (TopUpFactory.TokenConfig memory) {
        return TopUpFactory.TokenConfig({
            bridgeAdapter: bridgeAdapter,
            recipientOnDestChain: recipientOnOptimism,
            maxSlippageInBps: MAX_SLIPPAGE_BPS,
            additionalData: _additionalData(oftAdapter)
        });
    }

    /// @dev Reads the destination recipient (TopUpDest on Optimism) for the current ENV.
    function _topUpDestOptimism() internal view returns (address) {
        string memory file = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(OP_CHAIN_ID), "/deployments.json");
        return vm.readFile(file).readAddress(".addresses.TopUpDest");
    }

    /// @dev Path of the Ethereum deployment manifest for the current ENV.
    function _ethereumDeploymentPath() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/1/deployments.json");
    }

    /**
     * @dev Asserts on-chain that every asset describes one consistent wrap-and-send chain: the
     *      OFTAdapter locks the wrapper, the wrapper's underlying is the raw stock, and the
     *      adapter's OP peer is the iTOKEN the topup is supposed to arrive as. The first two are
     *      exactly the derivation `StockOFTBridgeAdapter._resolveWrapper` performs at bridge
     *      time, so a mismatch there is a config that would revert `InvalidWrapperAsset` in
     *      production; the third is what makes the funds land on the right OP token.
     */
    function _assertAssetWiring() internal view {
        StockTopupAsset[] memory assets = _assets();
        for (uint256 i = 0; i < assets.length; i++) {
            StockTopupAsset memory a = assets[i];
            require(a.stock != address(0) && a.wrapper != address(0) && a.oftAdapter != address(0) && a.iToken != address(0), string.concat(a.symbol, ": zero address in the asset entry"));
            require(IOFT(a.oftAdapter).token() == a.wrapper, string.concat(a.symbol, ": OFT adapter does not lock the configured wrapper"));
            require(IERC4626(a.wrapper).asset() == a.stock, string.concat(a.symbol, ": wrapper underlying is not the configured raw stock"));
            require(address(uint160(uint256(IOAppPeers(a.oftAdapter).peers(OP_EID)))) == a.iToken, string.concat(a.symbol, ": OFT adapter's OP peer is not the configured iToken"));

            for (uint256 j = i + 1; j < assets.length; j++) {
                require(a.stock != assets[j].stock, "duplicate raw stock in the asset set");
                require(a.oftAdapter != assets[j].oftAdapter, "duplicate OFT adapter in the asset set");
            }
        }
    }
}
