// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { IOFT } from "../../src/interfaces/IOFT.sol";
import { IOAppPeers } from "../utils/IOAppPeers.sol";
import { StockSharedConfig } from "../utils/StockSharedConfig.sol";

/**
 * @title StockWithdrawConfig
 * @author ether.fi
 * @notice Shared configuration for the stock-withdraw deploy + verification scripts on both
 *         chains: CREATE3 salts (env-prefixed so dev and prod land at distinct deterministic
 *         addresses), the wrapped-stock asset set, LayerZero chain constants, the prod Safe
 *         and the compose gas limit. Everything cross-chain-address-dependent (the OP module
 *         predicting the mainnet unwrapper and vice versa) derives from these salts, so they
 *         MUST only ever change together.
 */
abstract contract StockWithdrawConfig is StockSharedConfig {
    // ---- CREATE3 salts (env-prefixed) ----

    string internal constant DEV_SALT_MODULE_IMPL = "Dev.StockWithdraw.StockWithdrawModuleImpl";
    string internal constant DEV_SALT_MODULE_PROXY = "Dev.StockWithdraw.StockWithdrawModuleProxy";
    string internal constant DEV_SALT_UNWRAPPER_IMPL = "Dev.StockWithdraw.StockUnwrapperImpl";
    string internal constant DEV_SALT_UNWRAPPER_PROXY = "Dev.StockWithdraw.StockUnwrapperProxy";

    // Prod runs on the `.V2` salts: the launch asset set (iwSPYx + iwQQQx + iwTBLLx) is baked in
    // at `initialize`, so the pair that carries it has to be a fresh deterministic address.
    string internal constant PROD_SALT_MODULE_IMPL = "Prod.StockWithdraw.StockWithdrawModuleImpl.V2";
    string internal constant PROD_SALT_MODULE_PROXY = "Prod.StockWithdraw.StockWithdrawModuleProxy.V2";
    string internal constant PROD_SALT_UNWRAPPER_IMPL = "Prod.StockWithdraw.StockUnwrapperImpl.V2";
    string internal constant PROD_SALT_UNWRAPPER_PROXY = "Prod.StockWithdraw.StockUnwrapperProxy.V2";

    // ---- Pinned prod addresses ----
    //
    // CREATE3 addresses are a pure function of the salt strings above, so pinning them turns a
    // typo in a salt into a loud pre-broadcast failure (`_assertProdAddresses`) instead of a
    // deploy at an address nothing else expects. Same guard StockLendAssets uses for its feeds.

    /// @notice `Prod.StockWithdraw.StockWithdrawModuleProxy.V2` (Optimism).
    address internal constant EXPECTED_PROD_MODULE_PROXY = 0xB9D4cdD267CB8f5F4123471A5B3dac8845EeAcA3;
    /// @notice `Prod.StockWithdraw.StockWithdrawModuleImpl.V2` (Optimism).
    address internal constant EXPECTED_PROD_MODULE_IMPL = 0xC9A3fCFB6a99286bDC337CB38011D2Dc8234EE4c;
    /// @notice `Prod.StockWithdraw.StockUnwrapperProxy.V2` (Ethereum).
    address internal constant EXPECTED_PROD_UNWRAPPER_PROXY = 0x4Fc4a684e6bd57f8149581C2bf84F80d973cD448;
    /// @notice `Prod.StockWithdraw.StockUnwrapperImpl.V2` (Ethereum).
    address internal constant EXPECTED_PROD_UNWRAPPER_IMPL = 0x19657A9aA109fbB9625623D1b50E5f1248f04f96;

    // ---- Chain / protocol constants ----

    /// @notice LayerZero V2 endpoint on Ethereum mainnet.
    address internal constant LZ_ENDPOINT_ETHEREUM = 0x1a44076050125825900e736c501f859c50fE728c;
    // `SAFE`, `OP_EID` (source chain of every withdrawal) and `ETHEREUM_EID` (destination) come
    // from StockSharedConfig, which the top-up config also inherits.

    /// @notice Executor gas limit for the destination lzReceive (OFTAdapter credit) call.
    ///         Carried in the module's own send options: the executor rejects options with
    ///         no lzReceive gas, and the third-party ShadowOFTs cannot be assumed to have
    ///         enforced options set for SEND_AND_CALL.
    /// @dev The executor passes this as the gas for the whole `endpoint.lzReceive` call, so it
    ///      must cover the endpoint wrapper (`clearPayload` + checks) AND the adapter's
    ///      `lzReceive` (Backed token credit + `sendCompose` store). Measured against the real
    ///      wSPYx adapter on mainnet: ~194k needed; the live recovery tx burned 210k end to
    ///      end. 150k stranded a real withdrawal mid-flight (LZ guid 0xff7dbce6...).
    uint128 internal constant LZ_RECEIVE_GAS_LIMIT = 300_000;
    /// @notice Executor gas limit for the destination lzCompose call.
    /// @dev Same rule: covers the endpoint wrapper plus `StockUnwrapper.lzCompose` (the
    ///      ERC-4626 redeem to the recipient). Measured ~145k on mainnet at the real message.
    ///      NOTE: measuring this on a fork in the SAME tx as the lzReceive leg reports only
    ///      ~75k — the compose runs in its own tx in production, so every account and slot the
    ///      redeem touches is COLD. Always measure the legs in separate transactions.
    uint128 internal constant COMPOSE_GAS_LIMIT = 500_000;

    /// @notice Provider (exit) fee in basis points taken from the wrapped-stock amount at
    ///         execute time (0 = disabled at launch; module admin can set up to 1000).
    uint16 internal constant PROVIDER_FEE_BPS = 0;
    /// @notice Recipient of the provider fee.
    address internal constant FEE_RECEIVER = SAFE;

    // ---- Wrapped-stock asset set (shared between envs today) ----
    //
    // Each asset is a PAIR that must stay in lockstep: the OP ShadowOFT (iTOKEN) the module
    // bridges, and the mainnet OFTAdapter the unwrapper accepts messages from. The adapter is
    // the ShadowOFT's LayerZero peer for ETHEREUM_EID, and the unwrapper's adapter allowlist is
    // load-bearing (`_from` is the only endpoint-authenticated field), so a wrong or missing
    // adapter here is a security bug, not just a broken route.
    //
    // All three assets are Backed `WrappedBackedTokenProxy` ERC-4626 wrappers, and their
    // adapters share identical runtime code — so wQQQx and wTBLLx ride the exact rail already
    // proven in prod by wSPYx.

    /// @notice OP ShadowOFT for wSPYx (iwSPYx).
    address internal constant WSPYX_SHADOW_OFT = 0xc1e636Aae7d6B46229FC2C362d562610519e8D7c;
    /// @notice Mainnet OFTAdapter for wSPYx — `token()` is wSPYx 0xE7E553Cd…, peer of iwSPYx.
    address internal constant WSPYX_ADAPTER = 0xB3b3412E3D367D26B6f37ddf74eECb7de8827318;

    /// @notice OP ShadowOFT for wQQQx (iwQQQx). Same address book as the QQQx lend listing —
    ///         `StockLendAssets.wqqqx().iToken`.
    address internal constant WQQQX_SHADOW_OFT = 0x3c99d3a81b27583B2E26dbd387C10411f2763516;
    /// @notice Mainnet OFTAdapter for wQQQx — `token()` is wQQQx 0x4C1AE29c…, and its
    ///         `peers(OP_EID)` is iwQQQx (verified bidirectionally on-chain).
    address internal constant WQQQX_ADAPTER = 0xD33685E92f079E05F7e25a5F14e68e44eD53bBC5;

    /// @notice OP ShadowOFT for wTBLLx (iwTBLLx). Same address book as the TBLLx collateral
    ///         rollout — `StockLendAssets.wtbllx().iToken`, listed by 3CP-641/642/643.
    address internal constant WTBLLX_SHADOW_OFT = 0x5F8b2D2b97aD4d63188f44965778F6004D5bc387;
    /// @notice Mainnet OFTAdapter for wTBLLx, deployed by the 3CP-640 Ethereum listing bundle.
    /// @dev Verified on-chain 2026-08-14: `token()` is wTBLLx 0x461b25b9… whose `asset()` is
    ///      TBLLx 0x4cbf89ED…; `peers(OP_EID)` is iwTBLLx and `iwTBLLx.peers(ETHEREUM_EID)` is
    ///      this adapter (bidirectional). Locked float 92.649049729892439115 wTBLLx against
    ///      92.649049 iwTBLLx minted, i.e. the rail is live and in use, not just wired.
    address internal constant WTBLLX_ADAPTER = 0x8C03Bba46607F0e1bd51c6860293040f0477A1D0;

    // ---- Env-derived selectors (`_isDev` lives in StockSharedConfig) ----

    function _moduleImplSalt() internal view returns (string memory) {
        return _isDev() ? DEV_SALT_MODULE_IMPL : PROD_SALT_MODULE_IMPL;
    }

    function _moduleProxySalt() internal view returns (string memory) {
        return _isDev() ? DEV_SALT_MODULE_PROXY : PROD_SALT_MODULE_PROXY;
    }

    function _unwrapperImplSalt() internal view returns (string memory) {
        return _isDev() ? DEV_SALT_UNWRAPPER_IMPL : PROD_SALT_UNWRAPPER_IMPL;
    }

    function _unwrapperProxySalt() internal view returns (string memory) {
        return _isDev() ? DEV_SALT_UNWRAPPER_PROXY : PROD_SALT_UNWRAPPER_PROXY;
    }

    /// @dev Admin-role recipient: the broadcaster on dev, the prod Safe on mainnet.
    function _adminFor(address devAdmin) internal view returns (address) {
        return _isDev() ? devAdmin : SAFE;
    }

    // ---- Asset arrays (shared shape between deploy init and verification) ----

    /// @dev The iTOKENs the OP module registers at initialize. Index-aligned with `_adapters()`
    ///      — entry i here and entry i there are the two ends of the same asset's rail.
    function _iTokens() internal pure returns (address[] memory iTokens, bool[] memory supported) {
        iTokens = new address[](3);
        iTokens[0] = WSPYX_SHADOW_OFT;
        iTokens[1] = WQQQX_SHADOW_OFT;
        iTokens[2] = WTBLLX_SHADOW_OFT;
        supported = new bool[](3);
        supported[0] = true;
        supported[1] = true;
        supported[2] = true;
    }

    /// @dev The mainnet OFTAdapters the unwrapper registers at initialize. Index-aligned with
    ///      `_iTokens()`.
    function _adapters() internal pure returns (address[] memory adapters, bool[] memory registered) {
        adapters = new address[](3);
        adapters[0] = WSPYX_ADAPTER;
        adapters[1] = WQQQX_ADAPTER;
        adapters[2] = WTBLLX_ADAPTER;
        registered = new bool[](3);
        registered[0] = true;
        registered[1] = true;
        registered[2] = true;
    }

    // ---- Pre-broadcast guards ----

    /**
     * @dev Asserts the prod CREATE3 addresses the current salts resolve to are the pinned ones.
     *      A salt typo otherwise deploys a perfectly good pair at an address the 3CP bundles,
     *      the deployments file and the cross-chain init data all disagree with — and because
     *      each side bakes in the OTHER side's predicted address, that mistake is only
     *      recoverable through the admin role this whole rollout is designed to avoid needing.
     */
    function _assertProdAddresses() internal view {
        require(_predictAddress(PROD_SALT_MODULE_IMPL) == EXPECTED_PROD_MODULE_IMPL, "prod module impl salt does not resolve to the pinned address");
        require(_predictAddress(PROD_SALT_MODULE_PROXY) == EXPECTED_PROD_MODULE_PROXY, "prod module proxy salt does not resolve to the pinned address");
        require(_predictAddress(PROD_SALT_UNWRAPPER_IMPL) == EXPECTED_PROD_UNWRAPPER_IMPL, "prod unwrapper impl salt does not resolve to the pinned address");
        require(_predictAddress(PROD_SALT_UNWRAPPER_PROXY) == EXPECTED_PROD_UNWRAPPER_PROXY, "prod unwrapper proxy salt does not resolve to the pinned address");
    }

    /**
     * @dev Asserts every configured asset is one consistent rail, off-line, before anything is
     *      broadcast or bundled: the OP ShadowOFT satisfies the invariant `configureTokens`
     *      enforces (`IOFT(iToken).token() == iToken`, else `InvalidOFT` reverts the whole
     *      `initialize`), the mainnet adapter locks a real ERC-4626, and the two are each
     *      other's LayerZero peers — the adapter allowlist in the unwrapper is what
     *      authenticates a compose, so a wrong pairing here is a security bug and not merely a
     *      broken route.
     * @param onOptimism True when running on OP (only the iToken half is readable), false on
     *                   Ethereum (only the adapter half is readable).
     */
    function _assertAssetRails(bool onOptimism) internal view {
        (address[] memory iTokens,) = _iTokens();
        (address[] memory adapters,) = _adapters();
        require(iTokens.length == adapters.length, "asset arrays are not index-aligned");

        for (uint256 i = 0; i < iTokens.length; i++) {
            require(iTokens[i] != address(0) && adapters[i] != address(0), "zero address in the asset set");
            for (uint256 j = i + 1; j < iTokens.length; j++) {
                require(iTokens[i] != iTokens[j], "duplicate iToken in the asset set");
                require(adapters[i] != adapters[j], "duplicate adapter in the asset set");
            }

            if (onOptimism) {
                require(IOFT(iTokens[i]).token() == iTokens[i], "iToken is not its own OFT - configureTokens would revert InvalidOFT");
                require(_peer(iTokens[i], ETHEREUM_EID) == adapters[i], "iToken's Ethereum peer is not the configured adapter");
            } else {
                address wrapped = IOFT(adapters[i]).token();
                require(wrapped != address(0), "adapter exposes no token");
                require(IERC4626(wrapped).asset() != address(0), "adapter's token is not an ERC-4626 wrapper - lzCompose redeem would revert");
                require(_peer(adapters[i], OP_EID) == iTokens[i], "adapter's OP peer is not the configured iToken");
            }
        }
    }

    /// @dev `peers(eid)` as an address. Both ShadowOFTs and OFTAdapters are OApps, so this is
    ///      the same call on either side of the rail.
    function _peer(address oApp, uint32 eid) internal view returns (address) {
        return address(uint160(uint256(IOAppPeers(oApp).peers(eid))));
    }
}
